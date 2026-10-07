import SwiftUI
import AppKit

/// Lightweight, dependency-free syntax highlighting for fenced code blocks. It colours
/// keywords, strings, comments, numbers, types, attributes and shell variables for the
/// languages models produce most often, and leaves anything else as plain text.
enum SyntaxHighlighter {
    enum Token { case plain, keyword, string, comment, number, type, attribute, added, removed, meta }

    struct Spec {
        var keywords: Set<String> = []
        var caseInsensitiveKeywords = false
        var lineComments: [String] = []
        var blockComment: (open: String, close: String)? = nil
        var quotes: Set<Character> = ["\"", "'"]
        var multilineQuotes: Set<Character> = []
        var tripleQuotes = false
        var attributePrefixes: Set<Character> = []
        var variablePrefix: Character? = nil
        var capitalizedTypes = false
        var tagNames = false
        var jsonKeys = false
        var yamlKeys = false
        var diff = false
    }

    // MARK: - Public

    static func highlight(_ code: String, language: String) -> AttributedString {
        let lang = normalize(language, code: code)
        let key = lang + "\u{0}" + code
        if let cached = cache[key] { return cached }
        let result: AttributedString
        if let spec = specs[lang] {
            result = render(tokenize(code, spec: spec))
        } else {
            result = AttributedString(code)
        }
        if cache.count > 64 { cache.removeAll() }
        cache[key] = result
        return result
    }

    /// Canonical language name for a fence tag, guessing from the code when the tag is empty.
    static func normalize(_ language: String, code: String) -> String {
        let l = language.trimmingCharacters(in: .whitespaces).lowercased()
        if l.isEmpty { return guess(code) }
        return aliases[l] ?? l
    }

    // MARK: - Languages

    private static var cache: [String: AttributedString] = [:]

    private static let aliases: [String: String] = [
        "py": "python", "python3": "python", "js": "javascript", "jsx": "javascript", "mjs": "javascript", "cjs": "javascript",
        "ts": "typescript", "tsx": "typescript", "jsonc": "json", "json5": "json",
        "sh": "shell", "bash": "shell", "zsh": "shell", "console": "shell", "terminal": "shell", "fish": "shell", "shellsession": "shell",
        "golang": "go", "rs": "rust", "c++": "cpp", "cc": "cpp", "cxx": "cpp", "hpp": "cpp", "h": "c", "objc": "objectivec",
        "objective-c": "objectivec", "m": "objectivec", "mm": "objectivec", "kt": "kotlin", "kts": "kotlin", "rb": "ruby",
        "yml": "yaml", "htm": "html", "xml": "html", "svg": "html", "plist": "html", "scss": "css", "less": "css",
        "docker": "dockerfile", "make": "makefile", "patch": "diff", "ps1": "powershell", "cs": "csharp", "c#": "csharp",
        "md": "markdown", "txt": "text", "plain": "text", "plaintext": "text", "output": "text", "log": "text",
    ]

    private static let cFamilyKeywords: Set<String> = [
        "auto", "break", "case", "char", "const", "continue", "default", "do", "double", "else", "enum", "extern", "float", "for",
        "goto", "if", "inline", "int", "long", "register", "restrict", "return", "short", "signed", "sizeof", "static", "struct",
        "switch", "typedef", "union", "unsigned", "void", "volatile", "while", "bool", "true", "false", "NULL",
    ]

    private static let specs: [String: Spec] = {
        var s: [String: Spec] = [:]
        s["swift"] = Spec(keywords: [
            "associatedtype", "class", "deinit", "enum", "extension", "func", "import", "init", "inout", "internal", "let", "operator",
            "private", "protocol", "public", "static", "struct", "subscript", "typealias", "var", "break", "case", "continue",
            "default", "defer", "do", "else", "fallthrough", "for", "guard", "if", "in", "repeat", "return", "switch", "where",
            "while", "as", "Any", "catch", "false", "is", "nil", "rethrows", "super", "self", "Self", "throw", "throws", "true",
            "try", "async", "await", "actor", "some", "any", "open", "fileprivate", "final", "override", "required", "convenience",
            "lazy", "weak", "unowned", "mutating", "nonmutating", "indirect", "willSet", "didSet", "get", "set", "macro", "consuming", "borrowing",
        ], lineComments: ["//"], blockComment: ("/*", "*/"), tripleQuotes: true, attributePrefixes: ["@", "#"], capitalizedTypes: true)
        s["python"] = Spec(keywords: [
            "False", "None", "True", "and", "as", "assert", "async", "await", "break", "class", "continue", "def", "del", "elif",
            "else", "except", "finally", "for", "from", "global", "if", "import", "in", "is", "lambda", "nonlocal", "not", "or",
            "pass", "raise", "return", "try", "while", "with", "yield", "self", "print", "match", "case",
        ], lineComments: ["#"], tripleQuotes: true, attributePrefixes: ["@"], capitalizedTypes: true)
        let js: Set<String> = [
            "break", "case", "catch", "class", "const", "continue", "debugger", "default", "delete", "do", "else", "export", "extends",
            "finally", "for", "function", "if", "import", "in", "instanceof", "new", "return", "super", "switch", "this", "throw",
            "try", "typeof", "var", "void", "while", "with", "yield", "let", "static", "enum", "await", "async", "of", "true",
            "false", "null", "undefined", "implements", "interface", "package", "private", "protected", "public", "type",
            "declare", "readonly", "namespace", "abstract", "as", "from", "keyof", "satisfies", "get", "set",
        ]
        s["javascript"] = Spec(keywords: js, lineComments: ["//"], blockComment: ("/*", "*/"), multilineQuotes: ["`"], attributePrefixes: ["@"], capitalizedTypes: true)
        s["typescript"] = s["javascript"]
        s["json"] = Spec(keywords: ["true", "false", "null"], lineComments: ["//"], blockComment: ("/*", "*/"), jsonKeys: true)
        s["shell"] = Spec(keywords: [
            "if", "then", "else", "elif", "fi", "for", "while", "until", "do", "done", "case", "esac", "in", "function", "select",
            "time", "return", "exit", "export", "local", "readonly", "unset", "shift", "source", "break", "continue", "true", "false",
            "sudo", "cd", "echo", "set",
        ], lineComments: ["#"], variablePrefix: "$")
        s["go"] = Spec(keywords: [
            "break", "default", "func", "interface", "select", "case", "defer", "go", "map", "struct", "chan", "else", "goto",
            "package", "switch", "const", "fallthrough", "if", "range", "type", "continue", "for", "import", "return", "var",
            "nil", "true", "false", "iota", "string", "int", "int64", "int32", "bool", "byte", "error", "float64", "uint", "any",
        ], lineComments: ["//"], blockComment: ("/*", "*/"), multilineQuotes: ["`"], capitalizedTypes: true)
        s["rust"] = Spec(keywords: [
            "as", "break", "const", "continue", "crate", "else", "enum", "extern", "false", "fn", "for", "if", "impl", "in", "let",
            "loop", "match", "mod", "move", "mut", "pub", "ref", "return", "self", "Self", "static", "struct", "super", "trait",
            "true", "type", "unsafe", "use", "where", "while", "async", "await", "dyn", "u8", "u16", "u32", "u64", "i8", "i16",
            "i32", "i64", "usize", "isize", "f32", "f64", "bool", "str", "char",
        ], lineComments: ["//"], blockComment: ("/*", "*/"), attributePrefixes: ["#"], capitalizedTypes: true)
        s["c"] = Spec(keywords: cFamilyKeywords, lineComments: ["//"], blockComment: ("/*", "*/"), attributePrefixes: ["#"], capitalizedTypes: false)
        s["cpp"] = Spec(keywords: cFamilyKeywords.union([
            "class", "namespace", "template", "typename", "this", "new", "delete", "public", "private", "protected", "virtual",
            "override", "using", "try", "catch", "throw", "nullptr", "constexpr", "static_cast", "dynamic_cast", "reinterpret_cast",
            "const_cast", "friend", "operator", "explicit", "mutable", "noexcept", "final", "auto", "decltype", "std",
        ]), lineComments: ["//"], blockComment: ("/*", "*/"), attributePrefixes: ["#"], capitalizedTypes: true)
        s["objectivec"] = Spec(keywords: cFamilyKeywords.union(["id", "self", "super", "nil", "YES", "NO", "instancetype", "strong", "weak", "nonatomic", "copy", "readonly"]),
                               lineComments: ["//"], blockComment: ("/*", "*/"), attributePrefixes: ["#", "@"], capitalizedTypes: true)
        s["java"] = Spec(keywords: [
            "abstract", "assert", "boolean", "break", "byte", "case", "catch", "char", "class", "const", "continue", "default", "do",
            "double", "else", "enum", "extends", "final", "finally", "float", "for", "goto", "if", "implements", "import",
            "instanceof", "int", "interface", "long", "native", "new", "package", "private", "protected", "public", "return",
            "short", "static", "strictfp", "super", "switch", "synchronized", "this", "throw", "throws", "transient", "try", "void",
            "volatile", "while", "true", "false", "null", "var", "record", "sealed", "permits", "yield",
        ], lineComments: ["//"], blockComment: ("/*", "*/"), attributePrefixes: ["@"], capitalizedTypes: true)
        s["kotlin"] = Spec(keywords: s["java"]!.keywords.union([
            "val", "fun", "when", "is", "in", "object", "companion", "data", "override", "open", "internal", "lateinit", "by",
            "get", "set", "suspend", "inline", "reified", "typealias", "as", "init", "constructor", "it",
        ]), lineComments: ["//"], blockComment: ("/*", "*/"), tripleQuotes: true, attributePrefixes: ["@"], capitalizedTypes: true)
        s["csharp"] = Spec(keywords: s["java"]!.keywords.union(["using", "namespace", "string", "bool", "readonly", "virtual", "override", "async", "await", "foreach", "in", "is", "as", "get", "set", "where", "select", "from"]),
                           lineComments: ["//"], blockComment: ("/*", "*/"), attributePrefixes: ["#"], capitalizedTypes: true)
        s["ruby"] = Spec(keywords: [
            "alias", "and", "begin", "break", "case", "class", "def", "defined?", "do", "else", "elsif", "end", "ensure", "false",
            "for", "if", "in", "module", "next", "nil", "not", "or", "redo", "rescue", "retry", "return", "self", "super", "then",
            "true", "undef", "unless", "until", "when", "while", "yield", "require", "require_relative", "attr_accessor",
            "attr_reader", "attr_writer", "puts", "private", "public", "protected", "include", "extend", "raise", "lambda", "proc",
        ], lineComments: ["#"], attributePrefixes: ["@"], capitalizedTypes: true)
        s["php"] = Spec(keywords: js.union(["echo", "fn", "use", "namespace", "require", "include", "require_once", "include_once", "elseif", "foreach", "endforeach", "endif", "match", "array", "isset", "unset", "empty"]),
                        lineComments: ["//", "#"], blockComment: ("/*", "*/"), attributePrefixes: ["#"], variablePrefix: "$", capitalizedTypes: true)
        s["sql"] = Spec(keywords: [
            "select", "from", "where", "insert", "into", "values", "update", "set", "delete", "create", "table", "drop", "alter",
            "index", "join", "inner", "left", "right", "outer", "full", "cross", "on", "group", "by", "order", "having", "limit",
            "offset", "as", "and", "or", "not", "null", "is", "in", "like", "between", "distinct", "union", "all", "exists",
            "case", "when", "then", "else", "end", "primary", "key", "foreign", "references", "default", "unique", "count",
            "sum", "avg", "min", "max", "asc", "desc", "with", "view", "begin", "commit", "rollback", "transaction", "if",
            "integer", "int", "text", "varchar", "boolean", "date", "timestamp", "true", "false", "returning", "explain",
        ], caseInsensitiveKeywords: true, lineComments: ["--"], blockComment: ("/*", "*/"))
        s["yaml"] = Spec(keywords: ["true", "false", "null", "yes", "no", "on", "off"], lineComments: ["#"], yamlKeys: true)
        s["toml"] = Spec(keywords: ["true", "false"], lineComments: ["#"], tripleQuotes: true, yamlKeys: false)
        s["ini"] = s["toml"]
        s["css"] = Spec(keywords: ["important", "px", "em", "rem", "vh", "vw", "auto", "none", "inherit", "initial", "flex", "grid", "block", "inline"],
                        lineComments: [], blockComment: ("/*", "*/"), attributePrefixes: ["@"])
        s["html"] = Spec(keywords: [], blockComment: ("<!--", "-->"), tagNames: true)
        s["dockerfile"] = Spec(keywords: ["FROM", "RUN", "CMD", "COPY", "ADD", "WORKDIR", "ENV", "EXPOSE", "ENTRYPOINT", "ARG", "LABEL", "USER", "VOLUME", "AS", "SHELL", "HEALTHCHECK", "STOPSIGNAL", "ONBUILD"],
                               caseInsensitiveKeywords: true, lineComments: ["#"], variablePrefix: "$")
        s["makefile"] = Spec(keywords: ["ifeq", "ifneq", "ifdef", "ifndef", "else", "endif", "include", "define", "endef", "export", "PHONY"],
                             lineComments: ["#"], variablePrefix: "$")
        s["powershell"] = Spec(keywords: ["if", "else", "elseif", "foreach", "for", "while", "do", "function", "param", "return", "try", "catch", "finally", "switch", "in", "begin", "process", "end", "true", "false", "null"],
                               caseInsensitiveKeywords: true, lineComments: ["#"], blockComment: ("<#", "#>"), variablePrefix: "$")
        s["diff"] = Spec(diff: true)
        return s
    }()

    /// Best-effort language detection for fences without a tag.
    static func guess(_ code: String) -> String {
        let head = String(code.prefix(600))
        let lines = head.components(separatedBy: "\n")
        if head.hasPrefix("#!") { return head.contains("python") ? "python" : "shell" }
        if head.hasPrefix("diff --git") || lines.contains(where: { $0.hasPrefix("@@ ") }) { return "diff" }
        let t = head.trimmingCharacters(in: .whitespacesAndNewlines)
        if (t.hasPrefix("{") || t.hasPrefix("[")), t.contains("\":") || t.contains("\" :") { return "json" }
        let dollarLines = lines.filter { $0.hasPrefix("$ ") }.count
        if dollarLines > 0, dollarLines * 2 >= lines.filter({ !$0.isEmpty }).count { return "shell" }
        if head.contains("func ") && (head.contains("let ") || head.contains("var ")) && !head.contains("package ") { return "swift" }
        if head.contains("package main") || head.contains("func main()") || head.contains(":= ") { return "go" }
        if head.contains("fn main") || head.contains("let mut ") || head.contains("println!") { return "rust" }
        if head.contains("#include") { return "c" }
        if head.contains("def ") || head.contains("import ") && head.contains(":\n") || head.contains("print(") { return "python" }
        if head.contains("function ") || head.contains("const ") || head.contains("=> ") || head.contains("console.") { return "javascript" }
        if head.contains("<html") || head.contains("<div") || head.contains("<?xml") { return "html" }
        if head.range(of: "\\bselect\\b[\\s\\S]*\\bfrom\\b", options: [.regularExpression, .caseInsensitive]) != nil { return "sql" }
        let commandish = lines.filter { !$0.isEmpty }.allSatisfy { line in
            ["git ", "npm ", "brew ", "cd ", "ls", "swift ", "xcodebuild", "pip ", "python", "make", "cargo ", "docker ", "curl ", "mkdir ", "rm ", "cp ", "mv ", "export ", "echo "].contains { line.hasPrefix($0) }
        }
        if commandish, !lines.isEmpty { return "shell" }
        return "text"
    }

    // MARK: - Tokenizer

    static func tokenize(_ code: String, spec: Spec) -> [(Token, String)] {
        let chars = Array(code)
        let n = chars.count
        var segs: [(Token, String)] = []
        var i = 0
        var lineStart = true

        func emit(_ t: Token, _ s: String) {
            guard !s.isEmpty else { return }
            if let last = segs.last, last.0 == t { segs[segs.count - 1].1 += s } else { segs.append((t, s)) }
        }
        func starts(_ s: String, at idx: Int) -> Bool {
            var j = idx
            for ch in s { if j >= n || chars[j] != ch { return false }; j += 1 }
            return true
        }
        func isIdent(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" }
        func text(_ a: Int, _ b: Int) -> String { String(chars[a..<b]) }

        while i < n {
            let c = chars[i]

            if lineStart && spec.diff {
                // Whole-line colouring: consume the line and its newline so the scanner
                // always advances, even on empty lines.
                var j = i
                while j < n, chars[j] != "\n" { j += 1 }
                let line = text(i, j)
                let tok: Token
                if line.hasPrefix("+++") || line.hasPrefix("---") || line.hasPrefix("diff ") || line.hasPrefix("index ") { tok = .comment }
                else if line.hasPrefix("+") { tok = .added }
                else if line.hasPrefix("-") { tok = .removed }
                else if line.hasPrefix("@@") { tok = .meta }
                else { tok = .plain }
                emit(tok, line)
                if j < n { emit(.plain, "\n"); j += 1 }
                i = j
                continue
            }

            if lineStart && spec.yamlKeys {
                var j = i
                while j < n, chars[j] == " " || chars[j] == "\t" { j += 1 }
                if j + 1 < n, chars[j] == "-", chars[j + 1] == " " { j += 2 }
                let keyStart = j
                while j < n, isIdent(chars[j]) || chars[j] == "." || chars[j] == "-" || chars[j] == "/" { j += 1 }
                var k = j
                while k < n, chars[k] == " " { k += 1 }
                if j > keyStart, k < n, chars[k] == ":", k + 1 >= n || chars[k + 1] == " " || chars[k + 1] == "\n" {
                    emit(.plain, text(i, keyStart))
                    emit(.attribute, text(keyStart, j))
                    i = j
                    lineStart = false
                    continue
                }
            }
            lineStart = false

            if let bc = spec.blockComment, starts(bc.open, at: i) {
                var j = i + bc.open.count
                while j < n, !starts(bc.close, at: j) { j += 1 }
                j = min(n, j + bc.close.count)
                emit(.comment, text(i, j))
                i = j
                continue
            }

            if let lc = spec.lineComments.first(where: { starts($0, at: i) }) {
                // A `#` directly followed by a letter in C-family files is a directive, handled below.
                if !(lc == "#" && spec.attributePrefixes.contains("#")) {
                    var j = i + lc.count
                    while j < n, chars[j] != "\n" { j += 1 }
                    emit(.comment, text(i, j))
                    i = j
                    continue
                }
            }

            if spec.tripleQuotes, starts("\"\"\"", at: i) || starts("'''", at: i) {
                let q = String(repeating: String(c), count: 3)
                var j = i + 3
                while j < n, !starts(q, at: j) { j += 1 }
                j = min(n, j + 3)
                emit(.string, text(i, j))
                i = j
                continue
            }

            if spec.quotes.contains(c) || spec.multilineQuotes.contains(c) {
                let multiline = spec.multilineQuotes.contains(c)
                var j = i + 1
                while j < n {
                    if chars[j] == "\\" { j += 2; continue }
                    if chars[j] == c { j += 1; break }
                    if chars[j] == "\n" && !multiline { break }
                    j += 1
                }
                j = min(j, n)
                var tok = Token.string
                if spec.jsonKeys {
                    var k = j
                    while k < n, chars[k] == " " { k += 1 }
                    if k < n, chars[k] == ":" { tok = .attribute }
                }
                emit(tok, text(i, j))
                i = j
                continue
            }

            if spec.tagNames, c == "<", i + 1 < n, chars[i + 1].isLetter || chars[i + 1] == "/" || chars[i + 1] == "?" || chars[i + 1] == "!" {
                var j = i + 1
                if chars[j] == "/" || chars[j] == "?" || chars[j] == "!" { j += 1 }
                while j < n, isIdent(chars[j]) || chars[j] == ":" || chars[j] == "-" { j += 1 }
                emit(.keyword, text(i, j))
                i = j
                continue
            }
            if spec.tagNames, c == ">" || (c == "/" && i + 1 < n && chars[i + 1] == ">") {
                let j = c == ">" ? i + 1 : i + 2
                emit(.keyword, text(i, j))
                i = j
                continue
            }

            if spec.attributePrefixes.contains(c), i + 1 < n, chars[i + 1].isLetter || chars[i + 1] == "_" || chars[i + 1] == "[" {
                var j = i + 1
                if chars[j] == "[" {
                    while j < n, chars[j] != "]", chars[j] != "\n" { j += 1 }
                    j = min(n, j + 1)
                } else {
                    while j < n, isIdent(chars[j]) { j += 1 }
                }
                emit(.attribute, text(i, j))
                i = j
                continue
            }

            if let v = spec.variablePrefix, c == v, i + 1 < n {
                var j = i + 1
                if chars[j] == "{" {
                    while j < n, chars[j] != "}", chars[j] != "\n" { j += 1 }
                    j = min(n, j + 1)
                } else if chars[j] == "(" {
                    emit(.plain, String(c)); i += 1; continue
                } else if isIdent(chars[j]) || chars[j] == "@" || chars[j] == "?" || chars[j] == "!" || chars[j] == "#" {
                    j += 1
                    while j < n, isIdent(chars[j]) { j += 1 }
                } else {
                    emit(.plain, String(c)); i += 1; continue
                }
                emit(.attribute, text(i, j))
                i = j
                continue
            }

            if c.isNumber && (i == 0 || !isIdent(chars[i - 1])) {
                var j = i + 1
                while j < n, chars[j].isHexDigit || chars[j] == "_" || chars[j] == "." || chars[j] == "x" || chars[j] == "o" || chars[j] == "b" { j += 1 }
                emit(.number, text(i, j))
                i = j
                continue
            }

            if c.isLetter || c == "_" {
                var j = i + 1
                while j < n, isIdent(chars[j]) || (chars[j] == "?" && spec.keywords.contains("defined?")) { j += 1 }
                let word = text(i, j)
                let isKeyword = spec.caseInsensitiveKeywords ? spec.keywords.contains(word.lowercased()) : spec.keywords.contains(word)
                if isKeyword {
                    emit(.keyword, word)
                } else if spec.capitalizedTypes, let f = word.first, f.isUppercase, word.count > 1, !word.allSatisfy({ $0.isUppercase || $0.isNumber || $0 == "_" }) {
                    emit(.type, word)
                } else {
                    emit(.plain, word)
                }
                i = j
                continue
            }

            emit(.plain, String(c))
            if c == "\n" { lineStart = true }
            i += 1
        }
        return segs
    }

    // MARK: - Rendering

    static func render(_ segments: [(Token, String)]) -> AttributedString {
        var out = AttributedString()
        for (tok, s) in segments {
            var a = AttributedString(s)
            if tok != .plain { a.foregroundColor = color(tok) }
            out.append(a)
        }
        return out
    }

    static func color(_ token: Token) -> Color {
        switch token {
        case .plain: return .primary
        case .keyword: return keywordColor
        case .string: return stringColor
        case .comment: return commentColor
        case .number: return numberColor
        case .type: return typeColor
        case .attribute: return attributeColor
        case .added: return addedColor
        case .removed: return removedColor
        case .meta: return metaColor
        }
    }

    private static let keywordColor = dynamic(light: (173, 61, 164), dark: (252, 95, 163))
    private static let stringColor = dynamic(light: (209, 47, 27), dark: (252, 106, 93))
    private static let commentColor = dynamic(light: (93, 108, 121), dark: (108, 121, 134))
    private static let numberColor = dynamic(light: (28, 0, 207), dark: (208, 191, 105))
    private static let typeColor = dynamic(light: (62, 128, 135), dark: (93, 216, 255))
    private static let attributeColor = dynamic(light: (120, 73, 42), dark: (253, 143, 63))
    private static let addedColor = dynamic(light: (28, 128, 60), dark: (120, 220, 140))
    private static let removedColor = dynamic(light: (190, 40, 40), dark: (255, 120, 120))
    private static let metaColor = dynamic(light: (0, 90, 180), dark: (110, 170, 255))

    private static func dynamic(light: (CGFloat, CGFloat, CGFloat), dark: (CGFloat, CGFloat, CGFloat)) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let c = isDark ? dark : light
            return NSColor(srgbRed: c.0 / 255, green: c.1 / 255, blue: c.2 / 255, alpha: 1)
        })
    }
}
