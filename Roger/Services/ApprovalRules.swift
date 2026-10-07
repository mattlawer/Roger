import Foundation
import Observation

/// What a remembered approval covers, always within one folder (and its subfolders).
enum ApprovalScope: Codable, Hashable {
    /// Commands the classifier considers read-only (ls, cat, grep, git status…).
    case readOnlyCommands
    /// Commands with the same signature, e.g. "swift build" or "git status".
    case commandsLike(String)
    case allCommands
    case fileEdits
    /// Web searches and page fetches; not tied to a folder.
    case webRequests

    var title: String {
        switch self {
        case .readOnlyCommands: return "Read-only commands"
        case .commandsLike(let s): return "Commands like “\(s)”"
        case .allCommands: return "Any command"
        case .fileEdits: return "File writes and edits"
        case .webRequests: return "Web searches and page fetches"
        }
    }

    var isFolderScoped: Bool { if case .webRequests = self { return false } else { return true } }
}

struct ApprovalRule: Codable, Identifiable, Hashable {
    var id = UUID()
    var directory: String
    var scope: ApprovalScope
    var createdAt = Date()

    var shortDirectory: String { scope.isFolderScoped ? ApprovalRules.shortPath(directory) : "everywhere" }
    var title: String { scope.isFolderScoped ? "\(scope.title) in \(shortDirectory)" : scope.title }

    func covers(directory dir: String) -> Bool {
        if !scope.isFolderScoped { return true }
        return dir == directory || dir.hasPrefix(directory.hasSuffix("/") ? directory : directory + "/")
    }
}

/// Persisted "always allow" decisions, stored next to the conversations.
@Observable
final class ApprovalRules {
    private(set) var rules: [ApprovalRule] = []
    private let url: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        url = base.appendingPathComponent("Roger/approvals.json")
        if let data = try? Data(contentsOf: url) {
            let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
            rules = (try? d.decode([ApprovalRule].self, from: data)) ?? []
        }
    }

    @discardableResult
    func add(_ scope: ApprovalScope, directory: String) -> ApprovalRule {
        if let existing = rules.first(where: { $0.scope == scope && $0.directory == directory }) { return existing }
        let rule = ApprovalRule(directory: directory, scope: scope)
        rules.append(rule)
        save()
        return rule
    }

    func remove(_ id: UUID) {
        rules.removeAll { $0.id == id }
        save()
    }

    func removeAll() {
        rules = []
        save()
    }

    /// The first rule that lets this call run without asking, if any.
    func rule(allowing call: ToolCall, cwd: String) -> ApprovalRule? {
        let standardCwd = URL(fileURLWithPath: cwd).standardizedFileURL.path
        switch call.name {
        case ToolRegistry.runCommand:
            let command = call.string("command") ?? ""
            let readOnly = CommandClassifier.isReadOnly(command)
            let signature = CommandClassifier.signature(command)
            return rules.first { rule in
                guard rule.covers(directory: standardCwd) else { return false }
                switch rule.scope {
                case .allCommands: return true
                case .readOnlyCommands: return readOnly
                case .commandsLike(let s): return signature == s
                case .fileEdits, .webRequests: return false
                }
            }
        case ToolRegistry.writeFile, ToolRegistry.editFile:
            let target = ToolExecutor.resolve(call.string("path"), cwd: cwd).path
            return rules.first { rule in
                if case .fileEdits = rule.scope { return rule.covers(directory: target) }
                return false
            }
        case ToolRegistry.webSearch, ToolRegistry.fetchURL:
            return rules.first { if case .webRequests = $0.scope { return true } else { return false } }
        default:
            return nil
        }
    }

    private func save() {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? e.encode(rules) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    static func shortPath(_ p: String) -> String {
        let home = NSHomeDirectory()
        if p == home { return "~" }
        if p.hasPrefix(home + "/") { return "~" + p.dropFirst(home.count) }
        return p
    }
}

/// Conservative classification of shell commands. Anything it does not recognise is
/// treated as not read-only; the user can still remember "commands like X" explicitly.
enum CommandClassifier {
    private static let readOnlyCommands: Set<String> = [
        "ls", "cat", "head", "tail", "less", "more", "wc", "grep", "egrep", "fgrep", "rg", "ag", "ack", "file", "stat", "du", "df",
        "pwd", "echo", "printf", "which", "whereis", "type", "whoami", "id", "env", "printenv", "date", "cal", "uname", "sw_vers",
        "hostname", "arch", "tree", "basename", "dirname", "realpath", "readlink", "sort", "uniq", "cut", "tr", "column", "nl",
        "od", "xxd", "hexdump", "strings", "diff", "cmp", "comm", "md5", "md5sum", "shasum", "sha256sum", "cksum", "jq", "yq",
        "ps", "lsof", "uptime", "true", "false", "test", "[", "cd", "export", "man", "help", "nproc", "locale", "otool", "nm",
        "plutil", "mdls", "wc", "bat", "exa", "eza", "fd", "tldr", "stat", "dig", "nslookup", "host",
    ]
    private static let readOnlyGitSubcommands: Set<String> = [
        "status", "log", "diff", "show", "ls-files", "ls-tree", "blame", "rev-parse", "describe", "shortlog", "cat-file", "grep",
        "name-rev", "count-objects", "--version", "help", "check-ignore", "diff-tree", "rev-list", "for-each-ref", "show-ref",
    ]
    /// Tools whose second word is part of the command's identity ("git status", "swift build").
    private static let multiWordTools: Set<String> = [
        "git", "npm", "npx", "yarn", "pnpm", "swift", "cargo", "xcodebuild", "docker", "brew", "pip", "pip3", "python", "python3",
        "go", "make", "bundle", "gem", "kubectl", "rails", "rake", "mix", "dotnet", "gradle", "./gradlew", "mvn", "poetry", "uv",
        "conda", "pod", "fastlane", "xcrun", "node", "ruby", "deno", "bun", "composer", "php", "terraform", "aws", "gcloud", "gh",
    ]

    /// Splits a command line into simple commands at `|`, `&&`, `||`, `;`, `&` and newlines,
    /// each tokenised with basic quote handling. Returns nil when the line uses syntax the
    /// classifier does not reason about (redirections, substitutions, backticks, subshells).
    static func segments(_ command: String) -> [[String]]? {
        var cleaned = command
        for harmless in ["2>&1", "2>/dev/null", "2> /dev/null", ">/dev/null", "> /dev/null", "&>/dev/null"] {
            cleaned = cleaned.replacingOccurrences(of: harmless, with: " ")
        }
        var segments: [[String]] = []
        var tokens: [String] = []
        var current = ""
        var quote: Character? = nil
        var inToken = false
        let chars = Array(cleaned)
        var i = 0
        func endToken() { if inToken { tokens.append(current); current = ""; inToken = false } }
        func endSegment() { endToken(); if !tokens.isEmpty { segments.append(tokens); tokens = [] } }
        while i < chars.count {
            let c = chars[i]
            if let q = quote {
                if c == q { quote = nil } else if c == "\\" && q == "\"" && i + 1 < chars.count { current.append(chars[i + 1]); i += 1 } else { current.append(c) }
                i += 1; continue
            }
            switch c {
            case "\"", "'":
                quote = c; inToken = true
            case "\\":
                if i + 1 < chars.count { current.append(chars[i + 1]); inToken = true; i += 1 }
            case " ", "\t":
                endToken()
            case "\n", ";":
                endSegment()
            case "|", "&":
                endSegment()
                if i + 1 < chars.count, chars[i + 1] == c { i += 1 }
            case ">", "<", "`", "(", ")", "{", "}":
                return nil
            case "$":
                if i + 1 < chars.count, chars[i + 1] == "(" { return nil }
                current.append(c); inToken = true
            default:
                current.append(c); inToken = true
            }
            i += 1
        }
        if quote != nil { return nil }
        endSegment()
        return segments.isEmpty ? nil : segments
    }

    /// Drops leading `NAME=value` assignments.
    private static func stripAssignments(_ tokens: [String]) -> [String] {
        var t = tokens
        while let first = t.first, first.range(of: "^[A-Za-z_][A-Za-z0-9_]*=", options: .regularExpression) != nil { t.removeFirst() }
        return t
    }

    static func isReadOnly(_ command: String) -> Bool {
        guard let segs = segments(command) else { return false }
        return segs.allSatisfy(isReadOnlySegment)
    }

    private static func isReadOnlySegment(_ raw: [String]) -> Bool {
        let tokens = stripAssignments(raw)
        guard let cmd = tokens.first else { return true }
        let args = Array(tokens.dropFirst())
        if args.contains("--help") || args == ["--version"] || args == ["-version"] || args == ["version"] { return !["sudo", "xargs", "eval", "exec", "sh", "bash", "zsh"].contains(cmd) }
        switch cmd {
        case "git":
            guard let sub = args.first else { return true }
            if readOnlyGitSubcommands.contains(sub) { return true }
            switch sub {
            case "branch": return args.dropFirst().allSatisfy { $0.hasPrefix("-") && !$0.contains("d") && !$0.contains("D") && !$0.contains("m") && !$0.contains("M") && !$0.hasPrefix("--set") && !$0.hasPrefix("-u") }
            case "remote": return args.count == 1 || args[1] == "-v" || args[1] == "show" || args[1] == "get-url"
            case "stash": return args.count > 1 && (args[1] == "list" || args[1] == "show")
            case "tag": return args.dropFirst().allSatisfy { $0 == "-l" || $0 == "--list" || $0.hasPrefix("-n") }
            case "config": return args.count > 1 && ["--get", "--get-all", "--get-regexp", "--list", "-l"].contains(args[1])
            case "worktree", "submodule": return args.count > 1 && ["list", "status"].contains(args[1])
            case "reflog": return args.count == 1 || args[1] == "show"
            default: return false
            }
        case "find":
            return !args.contains { ["-delete", "-exec", "-execdir", "-ok", "-okdir", "-fprint", "-fprint0", "-fls", "-fprintf"].contains($0) }
        case "sed":
            return !args.contains { $0.hasPrefix("-i") || $0 == "--in-place" }
        case "awk", "gawk", "mawk":
            return !args.contains { $0.contains("system(") }
        case "brew":
            return args.first.map { ["list", "ls", "info", "--prefix", "config", "deps", "--version", "doctor", "search"].contains($0) } ?? false
        case "npm", "pnpm", "yarn":
            return args.first.map { ["ls", "list", "root", "view", "outdated", "--version", "-v"].contains($0) } ?? false
        case "pip", "pip3":
            return args.first.map { ["list", "show", "freeze", "--version", "check"].contains($0) } ?? false
        case "swift":
            return args == ["--version"] || (args.first == "package" && args.count > 1 && ["describe", "dump-package", "show-dependencies"].contains(args[1]))
        case "xcodebuild":
            return args.first.map { ["-version", "-list", "-showsdks", "-showBuildSettings", "-showdestinations"].contains($0) } ?? false
        case "cargo":
            return args.first.map { ["--version", "metadata", "tree"].contains($0) } ?? false
        case "go":
            return args.first.map { ["version", "env", "list"].contains($0) } ?? false
        case "docker":
            return args.first.map { ["ps", "images", "version", "info", "logs", "inspect"].contains($0) } ?? false
        case "kubectl":
            return args.first.map { ["get", "describe", "version", "logs", "explain"].contains($0) } ?? false
        case "defaults":
            return args.first == "read"
        case "codesign":
            return args.contains("-d") || args.contains("--display") || args.contains("--verify")
        case "python", "python3", "node", "ruby", "perl", "java", "rustc", "gcc", "clang", "swiftc", "xcrun":
            return args == ["--version"] || args == ["-v"] || args == ["-V"] || args == ["version"]
        default:
            return readOnlyCommands.contains(cmd)
        }
    }

    /// Identity of a simple (unchained) command: its program and, for multi-word tools, the
    /// subcommand. "swift build --configuration release" → "swift build"; "ls -la" → "ls".
    static func signature(_ command: String) -> String? {
        guard let segs = segments(command), segs.count == 1 else { return nil }
        let tokens = stripAssignments(segs[0])
        guard let cmd = tokens.first else { return nil }
        if multiWordTools.contains(cmd), tokens.count > 1, !tokens[1].hasPrefix("-") { return cmd + " " + tokens[1] }
        return cmd
    }
}
