import Foundation
import CFNetwork
import PDFKit

enum ProxyMode: String, CaseIterable, Codable {
    case direct, http, socks, tor

    var label: String {
        switch self {
        case .direct: return "Direct"
        case .http: return "HTTP/HTTPS proxy"
        case .socks: return "SOCKS5 proxy"
        case .tor: return "Tor"
        }
    }
}

enum SearchEngine: String, CaseIterable, Codable {
    case duckduckgo, searxng

    var label: String {
        switch self {
        case .duckduckgo: return "DuckDuckGo (no account needed)"
        case .searxng: return "SearXNG instance"
        }
    }
}

/// Everything a web request needs to know: how to reach the internet and where to search.
struct WebConfig: Sendable {
    var proxyMode: ProxyMode = .direct
    var proxyHost = ""
    var proxyPort = 0
    var torPort = 9050
    var searchEngine: SearchEngine = .duckduckgo
    var searxngURL = ""

    /// Host and port requests go through, if any.
    var proxyEndpoint: (host: String, port: Int)? {
        switch proxyMode {
        case .direct:
            return nil
        case .http, .socks:
            let h = proxyHost.trimmingCharacters(in: .whitespaces)
            return h.isEmpty || proxyPort <= 0 ? nil : (h, proxyPort)
        case .tor:
            return ("127.0.0.1", torPort > 0 ? torPort : 9050)
        }
    }

    var usesSOCKS: Bool { proxyMode == .socks || proxyMode == .tor }

    var routeDescription: String {
        switch proxyMode {
        case .direct: return "directly"
        case .http: return proxyEndpoint.map { "through the HTTP proxy \($0.host):\($0.port)" } ?? "directly (no proxy host set)"
        case .socks: return proxyEndpoint.map { "through the SOCKS5 proxy \($0.host):\($0.port)" } ?? "directly (no proxy host set)"
        case .tor: return "through Tor (SOCKS5 127.0.0.1:\(proxyEndpoint?.port ?? 9050))"
        }
    }

    var proxyDictionary: [AnyHashable: Any]? {
        guard let ep = proxyEndpoint else { return nil }
        switch proxyMode {
        case .http:
            return [
                kCFNetworkProxiesHTTPEnable as String: 1,
                kCFNetworkProxiesHTTPProxy as String: ep.host,
                kCFNetworkProxiesHTTPPort as String: ep.port,
                kCFNetworkProxiesHTTPSEnable as String: 1,
                kCFNetworkProxiesHTTPSProxy as String: ep.host,
                kCFNetworkProxiesHTTPSPort as String: ep.port,
            ]
        case .socks, .tor:
            // kCFStreamPropertySOCKSProxyHost/Port are the same strings as the
            // kCFNetworkProxiesSOCKSProxy/Port keys, so set each key once.
            var d: [AnyHashable: Any] = [:]
            d[kCFNetworkProxiesSOCKSEnable as String] = 1
            d[kCFNetworkProxiesSOCKSProxy as String] = ep.host
            d[kCFNetworkProxiesSOCKSPort as String] = ep.port
            d[kCFStreamPropertySOCKSVersion as String] = kCFStreamSocketSOCKSVersion5 as String
            return d
        case .direct:
            return nil
        }
    }

    func makeSession(timeout: TimeInterval = 30) -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = timeout
        c.timeoutIntervalForResource = timeout * 2
        c.httpAdditionalHeaders = ["User-Agent": WebTools.userAgent, "Accept-Language": "en-US,en;q=0.8"]
        c.httpCookieAcceptPolicy = .never
        c.httpShouldSetCookies = false
        c.urlCache = nil
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        if let proxy = proxyDictionary { c.connectionProxyDictionary = proxy }
        return URLSession(configuration: c)
    }
}

enum WebError: LocalizedError {
    case invalidURL(String)
    case blockedHost(String)
    case onionNeedsTor
    case http(Int, String)
    case tooLarge(Int)
    case unsupportedType(String)
    case rateLimited(String)
    case searxngMissing
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL(let s): return "Not a valid http(s) URL: \(s)"
        case .blockedHost(let h): return "Roger only fetches public internet addresses, not \(h)."
        case .onionNeedsTor: return ".onion addresses are only reachable through Tor. Choose Tor under Settings → Internet."
        case .http(let code, let url): return "HTTP \(code) from \(url)"
        case .tooLarge(let n): return "The response is too large (\(ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file)))."
        case .unsupportedType(let t): return "Unsupported content type: \(t)"
        case .rateLimited(let engine): return "\(engine) refused the search (rate limited or CAPTCHA). Wait a minute, or switch the search engine in Settings → Internet."
        case .searxngMissing: return "No SearXNG URL is set in Settings → Internet."
        case .transport(let m): return m
        }
    }
}

struct SearchResult: Hashable {
    var title: String
    var url: String
    var snippet: String
}

struct FetchedPage {
    var finalURL: String
    var title: String?
    var text: String
    var contentType: String
}

/// Web search and page fetching for the model, routed through the configured proxy.
enum WebTools {
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"
    static let maxDownload = 5_000_000
    static let defaultFetchChars = 12_000
    static let maxFetchChars = 40_000

    // MARK: - Requests

    private static func get(_ url: URL, config: WebConfig, accept: String? = nil) async throws -> (Data, HTTPURLResponse) {
        var req = URLRequest(url: url)
        if let accept { req.setValue(accept, forHTTPHeaderField: "Accept") }
        let session = config.makeSession()
        defer { session.finishTasksAndInvalidate() }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            var message = error.localizedDescription
            if config.proxyMode == .tor, (error as NSError).domain == NSURLErrorDomain {
                message += " (Is Tor running? See Settings → Internet.)"
            } else if config.proxyMode != .direct, (error as NSError).domain == NSURLErrorDomain {
                message += " (Check the proxy under Settings → Internet.)"
            }
            throw WebError.transport(message)
        }
        guard let http = response as? HTTPURLResponse else { throw WebError.transport("No HTTP response from \(url.host ?? url.absoluteString)") }
        if data.count > maxDownload { throw WebError.tooLarge(data.count) }
        return (data, http)
    }

    /// Fetches check.torproject.org and reports the exit IP and whether it is a Tor exit.
    static func checkConnection(config: WebConfig) async throws -> (ip: String, isTor: Bool) {
        let (data, http) = try await get(URL(string: "https://check.torproject.org/api/ip")!, config: config, accept: "application/json")
        guard http.statusCode == 200, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ip = obj["IP"] as? String else { throw WebError.http(http.statusCode, "check.torproject.org") }
        return (ip, obj["IsTor"] as? Bool ?? false)
    }

    // MARK: - Search

    static func search(_ query: String, maxResults: Int, config: WebConfig) async throws -> (engine: String, results: [SearchResult]) {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let n = max(1, min(20, maxResults))
        switch config.searchEngine {
        case .searxng:
            return ("SearXNG", Array(try await searxng(q, config: config).prefix(n)))
        case .duckduckgo:
            var results = try await duckduckgoHTML(q, config: config)
            if results.isEmpty { results = try await duckduckgoLite(q, config: config) }
            return ("DuckDuckGo", Array(results.prefix(n)))
        }
    }

    static func formatSearch(query: String, engine: String, results: [SearchResult]) -> String {
        if results.isEmpty { return "No results for “\(query)” on \(engine)." }
        var lines = ["\(results.count) results for “\(query)” (\(engine)):", ""]
        for (i, r) in results.enumerated() {
            lines.append("\(i + 1). [\(r.title.isEmpty ? r.url : r.title)](\(r.url))")
            if !r.snippet.isEmpty { lines.append("   \(r.snippet)") }
        }
        lines.append("")
        lines.append("Use fetch_url to read any of these pages in full.")
        return lines.joined(separator: "\n")
    }

    private static func duckduckgoHTML(_ query: String, config: WebConfig) async throws -> [SearchResult] {
        var comps = URLComponents(string: "https://html.duckduckgo.com/html/")!
        comps.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "kl", value: "wt-wt")]
        let (data, http) = try await get(comps.url!, config: config, accept: "text/html")
        let html = String(decoding: data, as: UTF8.self)
        if http.statusCode == 403 || http.statusCode == 429 || html.contains("anomaly-modal") || html.contains("challenge-form") {
            throw WebError.rateLimited("DuckDuckGo")
        }
        guard http.statusCode == 200 else { throw WebError.http(http.statusCode, "html.duckduckgo.com") }
        return parseDuckDuckGo(html, anchorClass: "result__a", snippetClass: "result__snippet")
    }

    private static func duckduckgoLite(_ query: String, config: WebConfig) async throws -> [SearchResult] {
        var comps = URLComponents(string: "https://lite.duckduckgo.com/lite/")!
        comps.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "kl", value: "wt-wt")]
        let (data, http) = try await get(comps.url!, config: config, accept: "text/html")
        let html = String(decoding: data, as: UTF8.self)
        if http.statusCode == 403 || http.statusCode == 429 || html.contains("anomaly-modal") { throw WebError.rateLimited("DuckDuckGo") }
        guard http.statusCode == 200 else { throw WebError.http(http.statusCode, "lite.duckduckgo.com") }
        return parseDuckDuckGo(html, anchorClass: "result-link", snippetClass: "result-snippet")
    }

    /// Walks anchors and snippet cells in document order; works for both DuckDuckGo layouts.
    static func parseDuckDuckGo(_ html: String, anchorClass: String, snippetClass: String) -> [SearchResult] {
        // Anchors anywhere, but only table cells that carry the snippet class: in the lite
        // layout result links sit inside plain <td> cells that must not swallow them.
        let pattern = "<a\\b([^>]*)>([\\s\\S]*?)</a>|<td\\b([^>]*\\b\(NSRegularExpression.escapedPattern(for: snippetClass))\\b[^>]*)>([\\s\\S]*?)</td>"
        guard let rx = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let ns = html as NSString
        var results: [SearchResult] = []
        var seen: Set<String> = []
        for m in rx.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            if m.range(at: 1).location != NSNotFound {
                let attrs = ns.substring(with: m.range(at: 1))
                let inner = ns.substring(with: m.range(at: 2))
                guard let cls = attribute("class", in: attrs) else { continue }
                if cls.contains(anchorClass) {
                    guard let href = attribute("href", in: attrs), let url = resolveDuckDuckGoLink(href), !url.contains("duckduckgo.com/y.js") else { continue }
                    guard seen.insert(url).inserted else { continue }
                    results.append(SearchResult(title: cleanText(inner), url: url, snippet: ""))
                } else if cls.contains(snippetClass), !results.isEmpty, results[results.count - 1].snippet.isEmpty {
                    results[results.count - 1].snippet = cleanText(inner)
                }
            } else if m.range(at: 3).location != NSNotFound {
                let attrs = ns.substring(with: m.range(at: 3))
                if let cls = attribute("class", in: attrs), cls.contains(snippetClass), !results.isEmpty, results[results.count - 1].snippet.isEmpty {
                    results[results.count - 1].snippet = cleanText(ns.substring(with: m.range(at: 4)))
                }
            }
        }
        return results
    }

    private static func attribute(_ name: String, in attrs: String) -> String? {
        let pattern = "\\b\(name)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)')"
        guard let rx = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = rx.firstMatch(in: attrs, range: NSRange(location: 0, length: (attrs as NSString).length)) else { return nil }
        let r = m.range(at: 1).location != NSNotFound ? m.range(at: 1) : m.range(at: 2)
        return decodeEntities((attrs as NSString).substring(with: r))
    }

    /// DuckDuckGo links go through a redirect: //duckduckgo.com/l/?uddg=<encoded url>&rut=…
    static func resolveDuckDuckGoLink(_ href: String) -> String? {
        var h = href
        if h.hasPrefix("//") { h = "https:" + h }
        if h.contains("uddg="), let comps = URLComponents(string: h), let target = comps.queryItems?.first(where: { $0.name == "uddg" })?.value {
            return target
        }
        if h.hasPrefix("http://") || h.hasPrefix("https://") { return h }
        return nil
    }

    private static func searxng(_ query: String, config: WebConfig) async throws -> [SearchResult] {
        var base = config.searxngURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { throw WebError.searxngMissing }
        if !base.contains("://") { base = "https://" + base }
        while base.hasSuffix("/") { base.removeLast() }
        guard var comps = URLComponents(string: base + "/search") else { throw WebError.invalidURL(base) }
        comps.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "format", value: "json")]
        let (data, http) = try await get(comps.url!, config: config, accept: "application/json")
        guard http.statusCode == 200 else { throw WebError.http(http.statusCode, base) }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let items = obj["results"] as? [[String: Any]] else {
            throw WebError.transport("SearXNG did not return JSON. The instance must allow format=json (search.formats in its settings).")
        }
        return items.compactMap { item in
            guard let url = item["url"] as? String else { return nil }
            return SearchResult(title: item["title"] as? String ?? "", url: url, snippet: item["content"] as? String ?? "")
        }
    }

    // MARK: - Fetch

    static func fetch(_ urlString: String, config: WebConfig) async throws -> FetchedPage {
        var s = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.contains("://") { s = "https://" + s }
        guard let url = URL(string: s), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", let host = url.host else {
            throw WebError.invalidURL(urlString)
        }
        if host.hasSuffix(".onion"), !config.usesSOCKS { throw WebError.onionNeedsTor }
        guard isPublicHost(host) else { throw WebError.blockedHost(host) }

        let (data, http) = try await get(url, config: config, accept: "text/html,application/xhtml+xml,application/json,text/plain,application/pdf;q=0.9,*/*;q=0.5")
        let finalURL = http.url?.absoluteString ?? s
        guard (200..<300).contains(http.statusCode) else { throw WebError.http(http.statusCode, finalURL) }
        let type = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        let mime = type.components(separatedBy: ";").first?.trimmingCharacters(in: .whitespaces) ?? ""

        if mime == "application/pdf" || finalURL.lowercased().hasSuffix(".pdf") {
            guard let doc = PDFDocument(data: data) else { throw WebError.unsupportedType("PDF that could not be parsed") }
            let text = (doc.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return FetchedPage(finalURL: finalURL, title: doc.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String, text: collapseWhitespace(text), contentType: "application/pdf")
        }
        let body = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
        if mime.contains("html") || mime.isEmpty || body.range(of: "<html|<body|<div|<p\\b", options: [.regularExpression, .caseInsensitive]) != nil && mime.hasPrefix("text") {
            let (title, text) = htmlToText(body)
            return FetchedPage(finalURL: finalURL, title: title, text: text, contentType: mime.isEmpty ? "text/html" : mime)
        }
        if mime.hasPrefix("text/") || mime.contains("json") || mime.contains("xml") || mime.contains("javascript") || mime.contains("yaml") || mime.contains("csv") {
            return FetchedPage(finalURL: finalURL, title: nil, text: body, contentType: mime)
        }
        throw WebError.unsupportedType(mime)
    }

    static func formatPage(_ page: FetchedPage, start: Int, maxChars: Int) -> String {
        let limit = max(500, min(maxFetchChars, maxChars))
        let text = page.text
        let total = text.count
        let from = max(0, min(start, total))
        let slice = String(text.dropFirst(from).prefix(limit))
        var header = page.finalURL
        if let t = page.title, !t.isEmpty { header = "\(t)\n\(page.finalURL)" }
        var out = header + "\n\n" + slice
        let end = from + slice.count
        if end < total {
            out += "\n\n[Showing characters \(from)–\(end) of \(total). Call fetch_url again with start=\(end) to continue reading.]"
        }
        return out
    }

    // MARK: - HTML

    static func htmlToText(_ html: String) -> (title: String?, text: String) {
        var s = html.count > 3_000_000 ? String(html.prefix(3_000_000)) : html
        let title = firstGroup("<title[^>]*>([\\s\\S]*?)</title>", in: s).map { cleanText($0) }
        for tag in ["script", "style", "noscript", "svg", "head", "iframe", "template", "canvas"] {
            s = replace("<\(tag)\\b[^>]*>[\\s\\S]*?</\(tag)>", in: s, with: "")
        }
        s = replace("<!--[\\s\\S]*?-->", in: s, with: "")
        s = replace("<br\\s*/?>", in: s, with: "\n")
        s = replace("<(h[1-6])\\b[^>]*>", in: s, with: "\n\n")
        s = replace("<li\\b[^>]*>", in: s, with: "\n• ")
        s = replace("</t[dh]>", in: s, with: "\t")
        s = replace("</(p|div|h[1-6]|tr|section|article|header|footer|blockquote|pre|dd|dt|option|table|ul|ol|nav|aside|main|figure|figcaption|form|summary|details)>", in: s, with: "\n")
        s = replace("<[^>]+>", in: s, with: "")
        s = decodeEntities(s)
        return (title?.isEmpty == false ? title : nil, collapseWhitespace(s))
    }

    static func collapseWhitespace(_ s: String) -> String {
        var out: [String] = []
        var blank = 0
        for raw in s.components(separatedBy: "\n") {
            let line = raw.replacingOccurrences(of: "[ \\t\u{00A0}\\r]+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                blank += 1
                if blank == 1 { out.append("") }
            } else {
                blank = 0
                out.append(line)
            }
        }
        return out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func cleanText(_ fragment: String) -> String {
        collapseWhitespace(decodeEntities(replace("<[^>]+>", in: fragment, with: ""))).replacingOccurrences(of: "\n", with: " ")
    }

    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}", "copy": "©", "reg": "®", "trade": "™",
        "mdash": "—", "ndash": "–", "hellip": "…", "laquo": "«", "raquo": "»", "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”",
        "bull": "•", "middot": "·", "deg": "°", "euro": "€", "pound": "£", "yen": "¥", "cent": "¢", "times": "×", "divide": "÷",
        "frac12": "½", "frac14": "¼", "frac34": "¾", "eacute": "é", "egrave": "è", "agrave": "à", "ccedil": "ç", "uuml": "ü", "ouml": "ö", "auml": "ä", "szlig": "ß",
    ]

    static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        guard let rx = try? NSRegularExpression(pattern: "&(#x[0-9a-fA-F]+|#[0-9]+|[a-zA-Z][a-zA-Z0-9]*);") else { return s }
        let ns = s as NSString
        var out = ""
        var last = 0
        for m in rx.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let body = ns.substring(with: m.range(at: 1))
            var replacement: String? = nil
            if body.hasPrefix("#x") || body.hasPrefix("#X") {
                if let v = UInt32(body.dropFirst(2), radix: 16), let u = Unicode.Scalar(v) { replacement = String(Character(u)) }
            } else if body.hasPrefix("#") {
                if let v = UInt32(body.dropFirst(1)), let u = Unicode.Scalar(v) { replacement = String(Character(u)) }
            } else {
                replacement = namedEntities[body.lowercased()]
            }
            out += replacement ?? ns.substring(with: m.range)
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        return out
    }

    private static func replace(_ pattern: String, in s: String, with template: String) -> String {
        s.replacingOccurrences(of: pattern, with: template, options: [.regularExpression, .caseInsensitive])
    }

    private static func firstGroup(_ pattern: String, in s: String) -> String? {
        guard let rx = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = rx.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) else { return nil }
        return (s as NSString).substring(with: m.range(at: 1))
    }

    // MARK: - Safety

    /// Rejects loopback, link-local and private addresses so the model cannot poke at the
    /// local network through fetch_url. Hostnames are checked by name only.
    static func isPublicHost(_ host: String) -> Bool {
        let h = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if h == "localhost" || h.hasSuffix(".localhost") || h.hasSuffix(".local") || h.hasSuffix(".internal") || h.hasSuffix(".lan") || h.hasSuffix(".home") || h.hasSuffix(".arpa") { return false }
        let parts = h.split(separator: ".").compactMap { Int($0) }
        if parts.count == 4, h.allSatisfy({ $0.isNumber || $0 == "." }) {
            let (a, b) = (parts[0], parts[1])
            if a == 10 || a == 127 || a == 0 { return false }
            if a == 172 && (16...31).contains(b) { return false }
            if a == 192 && b == 168 { return false }
            if a == 169 && b == 254 { return false }
            if a == 100 && (64...127).contains(b) { return false }
            return true
        }
        if h.contains(":") {
            if h == "::1" || h == "::" || h.hasPrefix("fc") || h.hasPrefix("fd") || h.hasPrefix("fe80") || h.hasPrefix("::ffff:") { return false }
        }
        return true
    }
}

/// Non-blocking TCP connect with a timeout, used to see whether a proxy or Tor is listening.
enum TCPProbe {
    static func isOpen(host: String, port: Int, timeout: TimeInterval = 1.0) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                var addr = sockaddr_in()
                addr.sin_family = sa_family_t(AF_INET)
                addr.sin_port = in_port_t(UInt16(clamping: port)).bigEndian
                let literal = host == "localhost" ? "127.0.0.1" : host
                if inet_pton(AF_INET, literal, &addr.sin_addr) != 1 {
                    // Not an IPv4 literal: resolve it (IPv4 only, which proxies on a LAN overwhelmingly use).
                    var hints = addrinfo(); hints.ai_family = AF_INET; hints.ai_socktype = SOCK_STREAM
                    var info: UnsafeMutablePointer<addrinfo>?
                    guard getaddrinfo(host, nil, &hints, &info) == 0, let first = info else { continuation.resume(returning: false); return }
                    defer { freeaddrinfo(info) }
                    first.pointee.ai_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { addr.sin_addr = $0.pointee.sin_addr }
                }
                let fd = socket(AF_INET, SOCK_STREAM, 0)
                guard fd >= 0 else { continuation.resume(returning: false); return }
                defer { close(fd) }
                _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
                let r = withUnsafePointer(to: &addr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
                }
                if r == 0 { continuation.resume(returning: true); return }
                guard errno == EINPROGRESS else { continuation.resume(returning: false); return }
                var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                guard poll(&pfd, 1, Int32(timeout * 1000)) > 0 else { continuation.resume(returning: false); return }
                var err: Int32 = 0
                var len = socklen_t(MemoryLayout<Int32>.size)
                getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
                continuation.resume(returning: err == 0)
            }
        }
    }
}
