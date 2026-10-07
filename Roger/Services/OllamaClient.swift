import Foundation

enum OllamaError: LocalizedError {
    case badURL
    case http(Int, String)
    case server(String)
    case unreachable(String)

    var errorDescription: String? {
        switch self {
        case .badURL: return "Invalid Ollama host URL."
        case .http(let code, let msg): return msg.isEmpty ? "Ollama returned HTTP \(code)." : msg
        case .server(let msg): return msg
        case .unreachable(let msg): return "Cannot reach Ollama: \(msg)"
        }
    }

    var isToolsUnsupported: Bool {
        errorDescription?.lowercased().contains("does not support tools") ?? false
    }

    /// Ollama rejected images for a text-only model.
    var isVisionUnsupported: Bool {
        let m = errorDescription?.lowercased() ?? ""
        return m.contains("multimodal") || m.contains("does not support images") || m.contains("vision")
    }
}

/// Thin async client for the Ollama HTTP API.
struct OllamaClient {
    let baseURL: URL

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 600
        config.timeoutIntervalForResource = 60 * 60 * 6
        return URLSession(configuration: config)
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    private func request(_ path: String, method: String = "GET", body: [String: Any]? = nil) throws -> URLRequest {
        guard let url = URL(string: path, relativeTo: baseURL) else { throw OllamaError.badURL }
        var req = URLRequest(url: url)
        req.httpMethod = method
        if let body {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return req
    }

    private func data(for req: URLRequest) async throws -> Data {
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await Self.session.data(for: req)
        } catch {
            throw OllamaError.unreachable(error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            throw OllamaError.http(http.statusCode, Self.errorMessage(from: data))
        }
        return data
    }

    private static func errorMessage(from data: Data) -> String {
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let e = errorText(obj) {
            return e
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Ollama reports errors either as {"error": "text"} or, for OpenAI-style failures, as
    /// {"error": {"code": 400, "message": "text", "type": "..."}}.
    static func errorText(_ obj: [String: Any]) -> String? {
        if let e = obj["error"] as? String { return e }
        if let e = obj["error"] as? [String: Any] {
            if let m = e["message"] as? String { return m }
            if let data = try? JSONSerialization.data(withJSONObject: e), let s = String(data: data, encoding: .utf8) { return s }
        }
        return nil
    }

    // MARK: - Endpoints

    func version() async throws -> String {
        let data = try await data(for: request("api/version"))
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return obj?["version"] as? String ?? "?"
    }

    func listModels() async throws -> [OllamaModelInfo] {
        let data = try await data(for: request("api/tags"))
        return try Self.decoder.decode(OllamaTagsResponse.self, from: data).models
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func runningModels() async throws -> [RunningModel] {
        let data = try await data(for: request("api/ps"))
        return try Self.decoder.decode(OllamaPsResponse.self, from: data).models
    }

    func showModel(_ name: String) async throws -> OllamaShowResponse {
        let data = try await data(for: request("api/show", method: "POST", body: ["model": name]))
        return try Self.decoder.decode(OllamaShowResponse.self, from: data)
    }

    func deleteModel(_ name: String) async throws {
        _ = try await data(for: request("api/delete", method: "DELETE", body: ["model": name]))
    }

    func unloadModel(_ name: String) async throws {
        _ = try await data(for: request("api/generate", method: "POST", body: ["model": name, "keep_alive": 0]))
    }

    func pull(_ name: String) -> AsyncThrowingStream<PullProgress, Error> {
        stream(path: "api/pull", body: ["model": name, "stream": true])
    }

    func chat(model: String, messages: [[String: Any]], tools: [[String: Any]]?, options: [String: Any], think: Bool? = nil) -> AsyncThrowingStream<ChatChunk, Error> {
        var body: [String: Any] = ["model": model, "messages": messages, "stream": true, "options": options]
        if let tools, !tools.isEmpty { body["tools"] = tools }
        if let think { body["think"] = think }
        return stream(path: "api/chat", body: body)
    }

    /// One non-streaming chat completion; returns the reply text. Used for short
    /// housekeeping requests such as naming a chat.
    func chatOnce(model: String, messages: [[String: Any]], options: [String: Any], think: Bool? = nil) async throws -> String {
        var body: [String: Any] = ["model": model, "messages": messages, "stream": false, "options": options]
        if let think { body["think"] = think }
        let data = try await data(for: request("api/chat", method: "POST", body: body))
        let chunk = try Self.decoder.decode(ChatChunk.self, from: data)
        if let e = chunk.error { throw OllamaError.server(e) }
        return chunk.message?.content ?? ""
    }

    // MARK: - Streaming (newline-delimited JSON)

    private func stream<T: Decodable>(path: String, body: [String: Any]) -> AsyncThrowingStream<T, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let req = try request(path, method: "POST", body: body)
                    let (bytes, response): (URLSession.AsyncBytes, URLResponse)
                    do {
                        (bytes, response) = try await Self.session.bytes(for: req)
                    } catch {
                        throw OllamaError.unreachable(error.localizedDescription)
                    }
                    if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
                        var text = ""
                        for try await line in bytes.lines { text += line }
                        throw OllamaError.http(http.statusCode, Self.errorMessage(from: Data(text.utf8)))
                    }
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard let data = line.data(using: .utf8), !line.isEmpty else { continue }
                        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                           let err = Self.errorText(obj) {
                            throw OllamaError.server(err)
                        }
                        let chunk = try Self.decoder.decode(T.self, from: data)
                        continuation.yield(chunk)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
