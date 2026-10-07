import Foundation

/// Tool definitions exposed to the model (Ollama / OpenAI function-calling format).
enum ToolRegistry {
    static let readFile = "read_file"
    static let writeFile = "write_file"
    static let editFile = "edit_file"
    static let listDirectory = "list_directory"
    static let searchFiles = "search_files"
    static let runCommand = "run_command"
    static let webSearch = "web_search"
    static let fetchURL = "fetch_url"

    static func requiresApproval(_ name: String) -> Bool {
        [writeFile, editFile, runCommand].contains(name)
    }

    static func isCommand(_ name: String) -> Bool { name == runCommand }
    static func isWeb(_ name: String) -> Bool { name == webSearch || name == fetchURL }

    /// Tool definitions for a request; internet tools only when the user enabled them.
    static func definitions(internet: Bool) -> [[String: Any]] {
        internet ? definitions + internetDefinitions : definitions
    }

    static let internetDefinitions: [[String: Any]] = [
        fn(webSearch, "Search the web and return the top results with title, URL and snippet. Use it for current events, documentation, prices, versions, or anything you are not sure about, then read a result with fetch_url.",
           ["query": str("The search query."),
            "max_results": str("How many results to return (default 8, max 20).")], ["query"]),
        fn(fetchURL, "Download a web page or PDF and return its readable text. Long pages are cut at max_chars; call again with start to keep reading.",
           ["url": str("The http(s) URL to read."),
            "max_chars": str("Maximum characters to return (default 12000, max 40000)."),
            "start": str("Character offset to continue reading from (default 0).")], ["url"]),
    ]

    private static func str(_ description: String) -> [String: Any] {
        ["type": "string", "description": description]
    }

    private static func fn(_ name: String, _ description: String, _ props: [String: Any], _ required: [String]) -> [String: Any] {
        [
            "type": "function",
            "function": [
                "name": name,
                "description": description,
                "parameters": [
                    "type": "object",
                    "properties": props,
                    "required": required,
                ],
            ],
        ]
    }

    static let definitions: [[String: Any]] = [
        fn(readFile, "Read the contents of a text file. Always read a file before editing it.",
           ["path": str("File path, absolute or relative to the working directory.")], ["path"]),
        fn(writeFile, "Create a new file or completely overwrite an existing one. Parent folders are created automatically.",
           ["path": str("File path, absolute or relative to the working directory."),
            "content": str("The complete new content of the file.")], ["path", "content"]),
        fn(editFile, "Edit a file by replacing one exact text snippet with new text. old_text must match the file exactly (including whitespace) and appear exactly once.",
           ["path": str("File path, absolute or relative to the working directory."),
            "old_text": str("The exact existing text to replace."),
            "new_text": str("The replacement text.")], ["path", "old_text", "new_text"]),
        fn(listDirectory, "List the files and folders inside a directory.",
           ["path": str("Directory path. Defaults to the working directory.")], []),
        fn(searchFiles, "Search recursively inside files for a regular expression and return matching lines with file paths and line numbers.",
           ["pattern": str("Regular expression (grep -E syntax) to search for."),
            "path": str("Directory or file to search in. Defaults to the working directory.")], ["pattern"]),
        fn(runCommand, "Run a shell command (zsh) in the working directory and return its combined stdout/stderr and exit code. The user must approve each command.",
           ["command": str("The shell command to execute.")], ["command"]),
    ]
}

/// Executes tool calls on the local machine.
enum ToolExecutor {
    static let maxOutput = 24_000

    static func resolve(_ path: String?, cwd: String) -> URL {
        let raw = (path ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let p = raw.isEmpty ? "." : raw
        let expanded = (p as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") { return URL(fileURLWithPath: expanded).standardizedFileURL }
        return URL(fileURLWithPath: cwd).appendingPathComponent(expanded).standardizedFileURL
    }

    static func truncate(_ s: String) -> String {
        guard s.count > maxOutput else { return s }
        return String(s.prefix(maxOutput)) + "\n… [output truncated, \(s.count - maxOutput) more characters]"
    }

    /// Runs a tool call. `onOutput` receives the growing output of shell commands while they run.
    /// `web` is nil when internet access is turned off.
    static func execute(_ call: ToolCall, cwd: String, loginShell: Bool = false, web: WebConfig? = nil,
                        onOutput: (@MainActor (String) -> Void)? = nil) async -> (ok: Bool, output: String) {
        switch call.name {
        case ToolRegistry.webSearch, ToolRegistry.fetchURL:
            guard let web else { return (false, "Internet access is turned off. Enable it under Settings → Internet.") }
            return await runWeb(call, config: web)
        case ToolRegistry.readFile:
            return readFile(call.string("path"), cwd: cwd)
        case ToolRegistry.writeFile:
            return writeFile(call.string("path"), content: call.string("content") ?? "", cwd: cwd)
        case ToolRegistry.editFile:
            return editFile(call.string("path"), old: call.string("old_text") ?? "", new: call.string("new_text") ?? "", cwd: cwd)
        case ToolRegistry.listDirectory:
            return listDirectory(call.string("path"), cwd: cwd)
        case ToolRegistry.searchFiles:
            return await searchFiles(call.string("pattern") ?? "", path: call.string("path"), cwd: cwd)
        case ToolRegistry.runCommand:
            let result = await ShellRunner.run(command: call.string("command") ?? "", cwd: cwd, loginShell: loginShell, onOutput: onOutput)
            let output = result.output.isEmpty ? "(no output)" : result.output
            return (result.exitCode == 0, truncate(output) + "\n[exit code \(result.exitCode)]")
        default:
            return (false, "Unknown tool: \(call.name)")
        }
    }

    private static func intArg(_ call: ToolCall, _ key: String) -> Int? {
        if case .number(let n)? = call.arguments[key] { return Int(n) }
        return call.string(key).flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    }

    static func runWeb(_ call: ToolCall, config: WebConfig) async -> (Bool, String) {
        do {
            if call.name == ToolRegistry.webSearch {
                let query = call.string("query") ?? ""
                guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return (false, "Error: query is empty") }
                let (engine, results) = try await WebTools.search(query, maxResults: intArg(call, "max_results") ?? 8, config: config)
                return (true, WebTools.formatSearch(query: query, engine: engine, results: results))
            } else {
                guard let url = call.string("url"), !url.isEmpty else { return (false, "Error: url is empty") }
                let page = try await WebTools.fetch(url, config: config)
                return (true, WebTools.formatPage(page, start: intArg(call, "start") ?? 0, maxChars: intArg(call, "max_chars") ?? WebTools.defaultFetchChars))
            }
        } catch {
            return (false, "Error: \(error.localizedDescription)")
        }
    }

    static func readFile(_ path: String?, cwd: String) -> (Bool, String) {
        let url = resolve(path, cwd: cwd)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            return (false, "Error: file not found: \(url.path)")
        }
        if isDir.boolValue { return listDirectory(path, cwd: cwd) }
        guard let data = FileManager.default.contents(atPath: url.path) else {
            return (false, "Error: cannot read \(url.path)")
        }
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            return (false, "Error: \(url.lastPathComponent) is not a text file (\(data.count) bytes)")
        }
        return (true, truncate(text))
    }

    static func writeFile(_ path: String?, content: String, cwd: String) -> (Bool, String) {
        let url = resolve(path, cwd: cwd)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: url, atomically: true, encoding: .utf8)
            let lines = content.components(separatedBy: "\n").count
            return (true, "Wrote \(lines) lines to \(url.path)")
        } catch {
            return (false, "Error writing \(url.path): \(error.localizedDescription)")
        }
    }

    static func editFile(_ path: String?, old: String, new: String, cwd: String) -> (Bool, String) {
        let url = resolve(path, cwd: cwd)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return (false, "Error: cannot read \(url.path)")
        }
        guard !old.isEmpty else { return (false, "Error: old_text is empty") }
        let occurrences = text.components(separatedBy: old).count - 1
        guard occurrences > 0 else {
            return (false, "Error: old_text was not found in \(url.lastPathComponent). Read the file again and use an exact snippet.")
        }
        guard occurrences == 1 else {
            return (false, "Error: old_text appears \(occurrences) times in \(url.lastPathComponent); include more surrounding context so it is unique.")
        }
        let updated = text.replacingOccurrences(of: old, with: new)
        do {
            try updated.write(to: url, atomically: true, encoding: .utf8)
            return (true, "Edited \(url.path)")
        } catch {
            return (false, "Error writing \(url.path): \(error.localizedDescription)")
        }
    }

    static func listDirectory(_ path: String?, cwd: String) -> (Bool, String) {
        let url = resolve(path, cwd: cwd)
        do {
            let items = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey], options: [.skipsHiddenFiles])
            let lines = items.sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
                .prefix(500)
                .map { item -> String in
                    let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
                    if values?.isDirectory == true { return item.lastPathComponent + "/" }
                    let size = values?.fileSize.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? ""
                    return "\(item.lastPathComponent)  (\(size))"
                }
            let header = "\(url.path) — \(items.count) items" + (items.count > 500 ? " (showing 500)" : "")
            return (true, ([header] + lines).joined(separator: "\n"))
        } catch {
            return (false, "Error: \(error.localizedDescription)")
        }
    }

    static func searchFiles(_ pattern: String, path: String?, cwd: String) async -> (Bool, String) {
        guard !pattern.isEmpty else { return (false, "Error: pattern is empty") }
        let url = resolve(path, cwd: cwd)
        let args = ["-rnIE", "--exclude-dir=.git", "--exclude-dir=node_modules", "--exclude-dir=.build",
                    "--exclude-dir=DerivedData", "--exclude-dir=Pods", "-e", pattern, url.path]
        let result = await ShellRunner.run(executable: "/usr/bin/grep", arguments: args, cwd: cwd, timeout: 60)
        if result.exitCode == 1 && result.output.isEmpty { return (true, "No matches for /\(pattern)/ in \(url.path)") }
        let relative = result.output.replacingOccurrences(of: url.path + "/", with: "")
        return (result.exitCode <= 1, truncate(relative))
    }
}

/// Runs processes with a timeout and combined output.
enum ShellRunner {
    struct Result {
        var output: String
        var exitCode: Int32
    }

    static var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory()
        let extra = ["/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin", "/usr/local/sbin",
                     "\(home)/.local/bin", "\(home)/.cargo/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        let current = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = (extra + current.components(separatedBy: ":")).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }.joined(separator: ":")
        env["TERM"] = "dumb"
        env["NO_COLOR"] = "1"
        return env
    }

    /// Removes ANSI escape sequences, carriage-return redraws and stray control
    /// characters so command output (pip, npm, progress bars…) renders as plain text.
    static func sanitize(_ raw: String) -> String {
        var s = raw
        // CSI sequences: ESC [ ... final-byte  (colors, cursor moves)
        s = s.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]", with: "", options: .regularExpression)
        // OSC sequences: ESC ] ... BEL or ST
        s = s.replacingOccurrences(of: "\u{1B}\\][^\u{07}\u{1B}]*(?:\u{07}|\u{1B}\\\\)", with: "", options: .regularExpression)
        // Other single-char escapes (ESC ( B, ESC =, …)
        s = s.replacingOccurrences(of: "\u{1B}[@-Z\\\\-_()#%]", with: "", options: .regularExpression)
        // Collapse carriage-return progress redraws: a terminal keeps the last write per line.
        s = s.replacingOccurrences(of: "\r\n", with: "\n")
        s = s.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            String(line.split(separator: "\r", omittingEmptySubsequences: false).last ?? "")
        }.joined(separator: "\n")
        // Drop remaining control characters except tab and newline.
        s = String(String.UnicodeScalarView(s.unicodeScalars.filter { $0 == "\n" || $0 == "\t" || $0.value >= 0x20 }))
        return s
    }

    /// Runs a shell command. By default uses a non-login, non-interactive shell so the
    /// user's ~/.zprofile / ~/.zlogin / ~/.zshrc (banners, prompts) do not run and pollute
    /// output. Only ~/.zshenv is sourced. Set loginShell to opt into the full environment.
    static func run(command: String, cwd: String, timeout: TimeInterval = 120, loginShell: Bool = false,
                    onOutput: (@MainActor (String) -> Void)? = nil) async -> Result {
        let args = loginShell ? ["-l", "-c", command] : ["-c", command]
        return await run(executable: "/bin/zsh", arguments: args, cwd: cwd, timeout: timeout, onOutput: onOutput)
    }

    /// Runs a process, streaming its combined output to `onOutput` (throttled, on the main
    /// actor) while it runs. Cancelling the calling task terminates the process.
    static func run(executable: String, arguments: [String], cwd: String, timeout: TimeInterval = 120,
                    onOutput: (@MainActor (String) -> Void)? = nil) async -> Result {
        let box = ProcessBox()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: executable)
                    process.arguments = arguments
                    process.environment = environment
                    var isDir: ObjCBool = false
                    if FileManager.default.fileExists(atPath: cwd, isDirectory: &isDir), isDir.boolValue {
                        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
                    }
                    let pipe = Pipe()
                    process.standardOutput = pipe
                    process.standardError = pipe
                    process.standardInput = FileHandle.nullDevice
                    let collector = OutputCollector(onOutput: onOutput)

                    var timedOut = false
                    let timer = DispatchWorkItem {
                        if process.isRunning {
                            timedOut = true
                            box.terminate()
                        }
                    }
                    do {
                        try process.run()
                    } catch {
                        continuation.resume(returning: Result(output: "Failed to start process: \(error.localizedDescription)", exitCode: -1))
                        return
                    }
                    box.attach(process)
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
                    let handle = pipe.fileHandleForReading
                    while true {
                        let chunk = handle.availableData
                        if chunk.isEmpty { break }
                        collector.append(chunk)
                    }
                    process.waitUntilExit()
                    timer.cancel()
                    let data = collector.finish()
                    var output = sanitize(String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self))
                    if timedOut { output += "\n[command timed out after \(Int(timeout))s and was terminated]" }
                    if box.wasCancelled { output += "\n[command stopped by the user]" }
                    continuation.resume(returning: Result(output: output.trimmingCharacters(in: .newlines), exitCode: process.terminationStatus))
                }
            }
        } onCancel: {
            box.cancel()
        }
    }
}

/// Holds the running process so a task cancellation can terminate it from another thread.
final class ProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private(set) var wasCancelled = false

    func attach(_ p: Process) {
        lock.lock()
        process = p
        let cancelled = wasCancelled
        lock.unlock()
        if cancelled { terminate() }
    }

    func cancel() {
        lock.lock()
        wasCancelled = true
        lock.unlock()
        terminate()
    }

    func terminate() {
        lock.lock()
        let p = process
        lock.unlock()
        guard let p, p.isRunning else { return }
        p.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { if p.isRunning { kill(p.processIdentifier, SIGKILL) } }
    }
}

/// Accumulates process output and delivers sanitised snapshots to the main actor at most
/// about ten times a second.
final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var flushScheduled = false
    private var finished = false
    private let onOutput: (@MainActor (String) -> Void)?

    init(onOutput: (@MainActor (String) -> Void)?) { self.onOutput = onOutput }

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        let schedule = onOutput != nil && !flushScheduled && !finished
        if schedule { flushScheduled = true }
        lock.unlock()
        if schedule {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [self] in flush() }
        }
    }

    private func flush() {
        lock.lock()
        flushScheduled = false
        let snapshot = finished ? nil : data
        lock.unlock()
        guard let snapshot, let onOutput else { return }
        let text = ShellRunner.sanitize(String(decoding: snapshot.prefix(ToolExecutor.maxOutput * 2), as: UTF8.self))
        MainActor.assumeIsolated { onOutput(text) }
    }

    /// Stops further snapshots and returns everything collected.
    func finish() -> Data {
        lock.lock(); defer { lock.unlock() }
        finished = true
        return data
    }
}
