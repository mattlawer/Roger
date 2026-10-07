import Foundation
import AppKit
import Observation

/// Finds, watches and starts a local Tor client so web requests can go through it.
@MainActor
@Observable
final class TorManager {
    enum Status: Equatable {
        case unknown
        case running(port: Int)
        case stopped(binary: String)
        case notInstalled
    }

    var status: Status = .unknown
    var isStarting = false
    var lastError: String?
    /// Reachable control port, when Tor exposes one (Roger opens one on a Tor it starts).
    var controlPort: Int?
    /// Outcome of the last circuit/reload action, for the UI.
    var lastActionResult: String?
    var isSignalling = false
    /// Set when Roger launched the tor process itself, so it can offer to stop it.
    private(set) var startedByRoger = false
    private var cachedBinary: String??

    static let candidateBinaries = [
        "/opt/homebrew/bin/tor", "/usr/local/bin/tor", "/opt/local/bin/tor", "/usr/bin/tor",
        NSHomeDirectory() + "/.local/bin/tor",
    ]

    var isRunning: Bool { if case .running = status { return true } else { return false } }
    var activePort: Int? { if case .running(let p) = status { return p } else { return nil } }

    var binaryPath: String? {
        if case .stopped(let b) = status { return b }
        if case .some(.some(let b)) = cachedBinary { return b }
        return nil
    }

    var installCommand: String { "brew install tor" }

    /// Command the user can paste in a terminal to run Tor themselves.
    var startCommand: String {
        if let b = binaryPath, b.hasPrefix("/opt/homebrew/") || b.hasPrefix("/usr/local/") {
            return "brew services start tor"
        }
        return "\(binaryPath ?? "tor") &"
    }

    var statusText: String {
        switch status {
        case .unknown: return "Checking for Tor…"
        case .running(let port): return port == 9150 ? "Tor Browser is running (SOCKS port 9150)." : "Tor is running (SOCKS port \(port))."
        case .stopped(let binary): return "Tor is installed (\(binary)) but not running."
        case .notInstalled: return "Tor is not installed."
        }
    }

    /// Looks for a listening SOCKS port (the configured one, then Tor Browser's 9150), then
    /// for the tor binary. Also notes whether a control port answers.
    func refresh(preferredPort: Int, controlPort configuredControlPort: Int = 9051) async {
        var ports = [preferredPort > 0 ? preferredPort : 9050]
        for p in [9050, 9150] where !ports.contains(p) { ports.append(p) }
        for port in ports {
            if await TCPProbe.isOpen(host: "127.0.0.1", port: port) {
                status = .running(port: port)
                let cp = configuredControlPort > 0 ? configuredControlPort : 9051
                controlPort = await TCPProbe.isOpen(host: "127.0.0.1", port: cp) ? cp : nil
                return
            }
        }
        controlPort = nil
        startedByRoger = false
        if let binary = await findBinary() {
            status = .stopped(binary: binary)
        } else {
            status = .notInstalled
        }
    }

    private func findBinary() async -> String? {
        if case .some(let cached) = cachedBinary { return cached }
        var found = Self.candidateBinaries.first { FileManager.default.isExecutableFile(atPath: $0) }
        if found == nil {
            let r = await ShellRunner.run(command: "command -v tor", cwd: NSHomeDirectory(), timeout: 10, loginShell: true)
            let path = r.output.trimmingCharacters(in: .whitespacesAndNewlines)
            if r.exitCode == 0, path.hasPrefix("/") { found = path }
        }
        cachedBinary = .some(found)
        return found
    }

    static var dataDirectory: String {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.appendingPathComponent("Roger/tor").path
    }

    /// Launches tor in the background and waits for its SOCKS port to open. A control port
    /// with cookie authentication is opened too (when free) so Roger can request new circuits.
    func start(port: Int, controlPort requestedControlPort: Int = 9051) async {
        guard case .stopped(let binary) = status, !isStarting else { return }
        isStarting = true
        lastError = nil
        let socksPort = port > 0 ? port : 9050
        let dataDir = Self.dataDirectory
        try? FileManager.default.createDirectory(atPath: dataDir, withIntermediateDirectories: true)
        var command = "nohup \"\(binary)\" --SocksPort \(socksPort) --DataDirectory \"\(dataDir)\""
        let cp = requestedControlPort > 0 ? requestedControlPort : 9051
        if await !TCPProbe.isOpen(host: "127.0.0.1", port: cp) {
            command += " --ControlPort \(cp) --CookieAuthentication 1"
        }
        command += " >/dev/null 2>&1 &"
        let r = await ShellRunner.run(command: command, cwd: NSHomeDirectory(), timeout: 10)
        if r.exitCode != 0 {
            lastError = "Could not launch tor: \(r.output)"
            isStarting = false
            return
        }
        for _ in 0..<30 {
            try? await Task.sleep(for: .seconds(1))
            if await TCPProbe.isOpen(host: "127.0.0.1", port: socksPort) {
                status = .running(port: socksPort)
                startedByRoger = true
                controlPort = await TCPProbe.isOpen(host: "127.0.0.1", port: cp) ? cp : nil
                break
            }
        }
        if !isRunning {
            lastError = "Tor did not open port \(socksPort) within 30 seconds. Run `\(binary)` in a terminal to see why."
            await refresh(preferredPort: socksPort, controlPort: cp)
        }
        isStarting = false
    }

    // MARK: - Circuits

    /// Where tor writes its control cookie: Roger's own data directory first, then the
    /// usual Homebrew and user locations.
    static var cookiePaths: [String] {
        [dataDirectory + "/control_auth_cookie",
         "/opt/homebrew/var/lib/tor/control_auth_cookie", "/usr/local/var/lib/tor/control_auth_cookie",
         "/opt/local/var/lib/tor/control_auth_cookie", NSHomeDirectory() + "/.tor/control_auth_cookie",
         "/var/lib/tor/control_auth_cookie"]
    }

    private func readCookie() -> Data? {
        for p in Self.cookiePaths {
            if let d = try? Data(contentsOf: URL(fileURLWithPath: p)), d.count == 32 { return d }
        }
        return nil
    }

    /// Asks Tor for fresh circuits: SIGNAL NEWNYM over the control port when one answers,
    /// otherwise SIGHUP, which reloads the configuration and rotates away from the circuits
    /// in use.
    func newCircuit(controlPassword: String) async {
        guard !isSignalling else { return }
        isSignalling = true
        defer { isSignalling = false }
        if let cp = controlPort {
            do {
                try await TorControl.signal("NEWNYM", port: cp, cookie: readCookie(), password: controlPassword)
                lastActionResult = "New circuit requested (NEWNYM on control port \(cp)). Tor switches to clean circuits within a few seconds and allows this once every 10 s."
                return
            } catch {
                let fallback = await sendHUP()
                lastActionResult = "Control port \(cp): \(error.localizedDescription) Fell back to SIGHUP: \(fallback)"
                return
            }
        }
        lastActionResult = await sendHUP()
    }

    /// Sends SIGHUP to tor: it reloads its configuration and marks the circuits in use as
    /// unusable, so new connections take new paths.
    func reload() async {
        guard !isSignalling else { return }
        isSignalling = true
        defer { isSignalling = false }
        lastActionResult = await sendHUP()
    }

    private func sendHUP() async -> String {
        let r = await ShellRunner.run(command: "pkill -HUP -x tor", cwd: NSHomeDirectory(), timeout: 10)
        switch r.exitCode {
        case 0: return "Sent SIGHUP to tor: configuration reloaded and current circuits retired; new connections take a new path."
        case 1: return "No tor process found to signal."
        default: return "Could not signal tor (\(r.output.isEmpty ? "exit \(r.exitCode)" : r.output)). It may run as another user; try `sudo pkill -HUP -x tor` in a terminal."
        }
    }

    /// Stops a tor process Roger started.
    func stop(port: Int) async {
        guard startedByRoger else { return }
        _ = await ShellRunner.run(command: "pkill -x tor", cwd: NSHomeDirectory(), timeout: 10)
        startedByRoger = false
        lastActionResult = nil
        try? await Task.sleep(for: .milliseconds(500))
        await refresh(preferredPort: port)
    }

    func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// Minimal client for Tor's control protocol, enough to authenticate and send a signal.
enum TorControl {
    struct Failure: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    static func signal(_ name: String, port: Int, cookie: Data?, password: String) async throws {
        var auth = "AUTHENTICATE"
        if let cookie {
            auth += " " + cookie.map { String(format: "%02x", $0) }.joined()
        } else if !password.isEmpty {
            let escaped = password.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            auth += " \"\(escaped)\""
        }
        let replies = try await exchange([auth, "SIGNAL \(name)"], port: port)
        guard replies.count == 2 else { throw Failure(message: "Unexpected reply from the control port.") }
        guard replies[0].hasPrefix("250") else {
            throw Failure(message: "Authentication failed (\(replies[0])). Set the control password in Settings → Internet, or use cookie authentication.")
        }
        guard replies[1].hasPrefix("250") else { throw Failure(message: "Tor rejected SIGNAL \(name): \(replies[1]).") }
    }

    private static func exchange(_ commands: [String], port: Int, timeout: TimeInterval = 5) async throws -> [String] {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do { continuation.resume(returning: try exchangeSync(commands, port: port, timeout: timeout)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    private static func exchangeSync(_ commands: [String], port: Int, timeout: TimeInterval) throws -> [String] {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure(message: "Could not create a socket.") }
        defer { close(fd) }
        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(clamping: port)).bigEndian
        inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr)
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard connected == 0 else { throw Failure(message: "Could not connect to the Tor control port \(port).") }

        var replies: [String] = []
        var pending = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        for command in commands + ["QUIT"] {
            let bytes = Array((command + "\r\n").utf8)
            guard send(fd, bytes, bytes.count, 0) == bytes.count else { throw Failure(message: "Could not write to the control port.") }
            if command == "QUIT" { break }
            var final: String?
            while final == nil {
                let n = recv(fd, &chunk, chunk.count, 0)
                guard n > 0 else {
                    throw Failure(message: replies.isEmpty
                                  ? "The control port closed the connection, which Tor does when authentication is rejected. Check the cookie file or the control password in Settings → Internet."
                                  : "The control port closed the connection.")
                }
                pending.append(contentsOf: chunk[0..<n])
                let text = String(decoding: pending, as: UTF8.self)
                var lines = text.components(separatedBy: "\r\n")
                let incomplete = text.hasSuffix("\r\n") ? "" : lines.removeLast()
                if let end = lines.firstIndex(where: { $0.count >= 4 && $0.prefix(3).allSatisfy(\.isNumber) && $0[$0.index($0.startIndex, offsetBy: 3)] == " " }) {
                    final = lines[end]
                    pending = Data((lines[(end + 1)...].joined(separator: "\r\n") + (incomplete.isEmpty ? "" : "\r\n" + incomplete)).utf8)
                }
            }
            replies.append(final!)
        }
        return replies
    }
}
