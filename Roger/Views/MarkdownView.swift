import SwiftUI
import QuickLook

enum MarkdownBlock: Identifiable, Hashable {
    case paragraph(String)
    case heading(Int, String)
    case code(lang: String, code: String)
    case list(items: [String], ordered: Bool)
    case quote(String)
    case table([String])
    case rule
    /// An image the text refers to. `explicit` is Markdown image syntax; otherwise it is a
    /// bare path the model mentioned, shown only if the file exists.
    case image(alt: String, source: String, explicit: Bool)

    var id: Int { hashValue }
}

enum MarkdownParser {
    static func parse(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        let lines = text.components(separatedBy: "\n")
        var i = 0
        var paragraph: [String] = []
        var listItems: [String] = []
        var listOrdered = false
        var quote: [String] = []
        var table: [String] = []

        func flushParagraph() {
            if !paragraph.isEmpty {
                let (text, images) = extractImages(paragraph.joined(separator: "\n"))
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { blocks.append(.paragraph(text)) }
                blocks.append(contentsOf: images)
                paragraph = []
            }
        }
        func flushList() {
            if !listItems.isEmpty {
                var images: [MarkdownBlock] = []
                let items = listItems.map { item -> String in
                    let (text, found) = extractImages(item)
                    images.append(contentsOf: found)
                    return text
                }
                blocks.append(.list(items: items, ordered: listOrdered))
                blocks.append(contentsOf: images)
                listItems = []
            }
        }
        func flushQuote() {
            if !quote.isEmpty { blocks.append(.quote(quote.joined(separator: "\n"))); quote = [] }
        }
        func flushTable() {
            if !table.isEmpty { blocks.append(.table(table)); table = [] }
        }
        func flushAll() { flushParagraph(); flushList(); flushQuote(); flushTable() }

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flushAll()
                let fence = String(trimmed.prefix(3))
                let lang = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    code.append(lines[i]); i += 1
                }
                blocks.append(.code(lang: lang, code: code.joined(separator: "\n")))
                i += 1
                continue
            }

            if trimmed.isEmpty {
                flushAll(); i += 1; continue
            }

            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flushAll(); blocks.append(.rule); i += 1; continue
            }

            if let heading = parseHeading(trimmed) {
                flushAll(); blocks.append(.heading(heading.0, heading.1)); i += 1; continue
            }

            if trimmed.hasPrefix(">") {
                flushParagraph(); flushList(); flushTable()
                quote.append(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))
                i += 1; continue
            }

            if trimmed.hasPrefix("|") {
                flushParagraph(); flushList(); flushQuote()
                if !trimmed.replacingOccurrences(of: "|", with: "").replacingOccurrences(of: "-", with: "").replacingOccurrences(of: ":", with: "").trimmingCharacters(in: .whitespaces).isEmpty {
                    table.append(trimmed)
                }
                i += 1; continue
            }

            if let item = parseListItem(line) {
                flushParagraph(); flushQuote(); flushTable()
                if !listItems.isEmpty, listOrdered != item.ordered { flushList() }
                listOrdered = item.ordered
                listItems.append(item.text)
                i += 1; continue
            }

            if !listItems.isEmpty, line.hasPrefix("  ") || line.hasPrefix("\t") {
                listItems[listItems.count - 1] += "\n" + trimmed
                i += 1; continue
            }

            flushList(); flushQuote(); flushTable()
            paragraph.append(line)
            i += 1
        }
        flushAll()
        return blocks
    }

    private static let markdownImage = try! NSRegularExpression(pattern: "!\\[([^\\]]*)\\]\\(\\s*<?([^)\\s>]+)>?(?:\\s+\"[^\"]*\")?\\s*\\)")
    private static let bareImagePath = try! NSRegularExpression(
        pattern: "(?<![\\w/.\\-])((?:https?://[^\\s)\"'`<>]+|(?:~/|\\.{1,2}/|/)?(?:[\\w.\\-]+/)*[\\w.\\-]+)\\.(?:png|jpe?g|gif|webp|heic|bmp|tiff?|svg))(?![\\w/\\-])",
        options: [.caseInsensitive])

    /// Pulls image references out of a text run: Markdown images are removed from the text
    /// (their alt text stays) and bare image paths are reported as candidates.
    static func extractImages(_ text: String) -> (String, [MarkdownBlock]) {
        var images: [MarkdownBlock] = []
        var seen: Set<String> = []
        let ns = text as NSString
        var cleaned = ""
        var last = 0
        for m in markdownImage.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            cleaned += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let alt = ns.substring(with: m.range(at: 1))
            let src = ns.substring(with: m.range(at: 2))
            cleaned += alt
            if seen.insert(src).inserted { images.append(.image(alt: alt, source: src, explicit: true)) }
            last = m.range.location + m.range.length
        }
        cleaned += ns.substring(from: last)
        let cns = cleaned as NSString
        for m in bareImagePath.matches(in: cleaned, range: NSRange(location: 0, length: cns.length)) {
            let src = cns.substring(with: m.range(at: 1))
            if seen.insert(src).inserted { images.append(.image(alt: "", source: src, explicit: false)) }
        }
        return (cleaned, images)
    }

    private static func parseHeading(_ s: String) -> (Int, String)? {
        var level = 0
        var idx = s.startIndex
        while idx < s.endIndex, s[idx] == "#", level < 6 { level += 1; idx = s.index(after: idx) }
        guard level > 0, idx < s.endIndex, s[idx] == " " else { return nil }
        return (level, String(s[idx...]).trimmingCharacters(in: .whitespaces))
    }

    private static func parseListItem(_ line: String) -> (text: String, ordered: Bool)? {
        let t = line.trimmingCharacters(in: .whitespaces)
        for marker in ["- ", "* ", "+ ", "• "] where t.hasPrefix(marker) {
            return (String(t.dropFirst(marker.count)), false)
        }
        if t.hasPrefix("- [ ] ") || t.hasPrefix("- [x] ") { return (String(t.dropFirst(2)), false) }
        var digits = 0
        var idx = t.startIndex
        while idx < t.endIndex, t[idx].isNumber, digits < 4 { digits += 1; idx = t.index(after: idx) }
        if digits > 0, idx < t.endIndex, t[idx] == "." || t[idx] == ")" {
            let after = t.index(after: idx)
            if after < t.endIndex, t[after] == " " { return (String(t[after...]).trimmingCharacters(in: .whitespaces), true) }
        }
        return nil
    }
}

struct MarkdownView: View {
    let text: String
    var onRunCommand: ((String) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(MarkdownParser.parse(text)) { block in
                render(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func render(_ block: MarkdownBlock) -> some View {
        switch block {
        case .paragraph(let s):
            Text(inline(s)).textSelection(.enabled).lineSpacing(3)
        case .heading(let level, let s):
            Text(inline(s))
                .font(level == 1 ? .title2.bold() : level == 2 ? .title3.bold() : .headline)
                .padding(.top, 4)
                .textSelection(.enabled)
        case .code(let lang, let code):
            CodeBlockView(language: lang, code: code, onRun: onRunCommand)
        case .list(let items, let ordered):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(ordered ? "\(idx + 1)." : "•")
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 16, alignment: .trailing)
                        Text(inline(item)).textSelection(.enabled)
                    }
                }
            }
        case .quote(let s):
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 2).fill(Color.accentColor.opacity(0.6)).frame(width: 3)
                Text(inline(s)).foregroundStyle(.secondary).textSelection(.enabled)
            }
        case .table(let rows):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(rows.joined(separator: "\n"))
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
            }
        case .rule:
            Divider()
        case .image(let alt, let source, let explicit):
            ImageBlockView(alt: alt, source: source, explicit: explicit)
        }
    }

    private func inline(_ s: String) -> AttributedString {
        if let a = try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return a
        }
        return AttributedString(s)
    }
}

struct CodeBlockView: View {
    let language: String
    let code: String
    var onRun: ((String) -> Void)? = nil

    @Environment(AppModel.self) private var model
    @State private var copied = false
    @State private var running = false
    @State private var output: String?
    @State private var exitCode: Int32 = 0

    private static let shellLanguages: Set<String> = ["bash", "sh", "zsh", "shell", "console", "terminal", "fish"]
    private var isShell: Bool { Self.shellLanguages.contains(language.lowercased()) }
    private var resolvedLanguage: String { SyntaxHighlighter.normalize(language, code: code) }
    private var languageLabel: String {
        if !language.isEmpty { return language }
        let guessed = resolvedLanguage
        return guessed == "text" ? "code" : guessed
    }

    private var command: String {
        code.components(separatedBy: "\n")
            .map { $0.hasPrefix("$ ") ? String($0.dropFirst(2)) : $0 }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text(languageLabel)
                    .font(.caption).foregroundStyle(.secondary)
                    .help(language.isEmpty && resolvedLanguage != "text" ? "Language guessed from the code" : "")
                Spacer()
                if isShell && !command.isEmpty {
                    Button {
                        run()
                    } label: {
                        Label(running ? "Running…" : "Run", systemImage: running ? "hourglass" : "play.fill")
                    }
                    .disabled(running)
                    .help("Run this command in the working directory")
                }
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
            }
            .buttonStyle(.borderless)
            .font(.caption)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(0.06))

            ScrollView(.horizontal, showsIndicators: false) {
                Text(SyntaxHighlighter.highlight(code, language: language))
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(12)
            }

            if let output {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        if running {
                            ProgressView().controlSize(.mini)
                            Text("Running…").font(.caption).foregroundStyle(.secondary)
                        } else {
                            Label(exitCode == 0 ? "Output" : "Output (exit code \(exitCode))", systemImage: exitCode == 0 ? "terminal" : "exclamationmark.triangle")
                                .font(.caption).foregroundStyle(exitCode == 0 ? Color.secondary : Color.orange)
                        }
                        Spacer()
                        if let onRun, !running {
                            Button("Send output to Roger") {
                                onRun("I ran `\(command)` and got:\n```\n\(output)\n```")
                            }
                            .font(.caption)
                        }
                        if !running {
                            Button("Dismiss") { self.output = nil }.font(.caption)
                        }
                    }
                    .buttonStyle(.borderless)
                    LiveOutputView(text: output, isLive: running, maxHeight: 240)
                }
                .padding(12)
            }
        }
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
    }

    private func run() {
        guard let cwd = model.selected?.workingDirectory else { return }
        running = true
        output = ""
        exitCode = 0
        let cmd = command
        Task {
            let result = await ShellRunner.run(command: cmd, cwd: cwd, loginShell: model.settings.useLoginShell) { partial in
                output = partial
            }
            output = ToolExecutor.truncate(result.output)
            exitCode = result.exitCode
            running = false
        }
    }
}

/// Monospaced output that scrolls both ways and follows the end while a command runs.
struct LiveOutputView: View {
    let text: String
    var isLive = false
    var maxHeight: CGFloat = 320

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView([.vertical, .horizontal]) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(text.isEmpty ? (isLive ? "Waiting for output…" : "(no output)") : text)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(8)
                    Color.clear.frame(height: 1).id("end")
                }
            }
            .frame(maxHeight: maxHeight)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .onChange(of: text.count) { _, _ in
                if isLive { proxy.scrollTo("end", anchor: .bottom) }
            }
        }
    }
}

/// An image referenced by the model: a local file (relative to the working directory) or a
/// remote URL. Click to open it in Quick Look.
struct ImageBlockView: View {
    @Environment(AppModel.self) private var model
    let alt: String
    let source: String
    let explicit: Bool
    @State private var image: NSImage?
    @State private var loadedModified: Date?
    @State private var missing = false
    @State private var previewURL: URL?

    private var isRemote: Bool { source.hasPrefix("http://") || source.hasPrefix("https://") }

    private var fileURL: URL? {
        if isRemote { return nil }
        if source.hasPrefix("file://") { return URL(string: source) }
        let cwd = model.selected?.workingDirectory ?? NSHomeDirectory()
        return ToolExecutor.resolve(source, cwd: cwd)
    }

    var body: some View {
        Group {
            if let image {
                VStack(alignment: .leading, spacing: 4) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: min(640, max(80, image.size.width)), maxHeight: min(420, max(80, image.size.height)))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
                        .onTapGesture { open() }
                        .help(isRemote ? "Click to open in your browser" : "Click to preview")
                    HStack(spacing: 10) {
                        Text(caption).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        if let fileURL {
                            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([fileURL]) }
                        } else if let url = URL(string: source) {
                            Button("Open") { NSWorkspace.shared.open(url) }
                        }
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
            } else if explicit && missing {
                Label("Image not found: \(source)", systemImage: "photo.badge.exclamationmark")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .quickLookPreview($previewURL)
        .task(id: "\(source)|\(model.toolRunCount)") { await load() }
    }

    private var caption: String {
        let name = fileURL?.lastPathComponent ?? URL(string: source)?.lastPathComponent ?? source
        guard let image else { return name }
        let px = "\(Int(image.size.width))×\(Int(image.size.height))"
        return alt.isEmpty ? "\(name) · \(px)" : "\(alt) · \(name) · \(px)"
    }

    private func open() {
        if let fileURL { previewURL = fileURL } else if let url = URL(string: source) { NSWorkspace.shared.open(url) }
    }

    private func load() async {
        if isRemote {
            guard image == nil, let url = URL(string: source) else { return }
            if let (data, _) = try? await URLSession.shared.data(from: url), let img = NSImage(data: data) { image = img } else { missing = true }
            return
        }
        guard let fileURL else { return }
        let path = fileURL.path
        let modified = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        guard modified != nil else {
            if image == nil { missing = true }
            return
        }
        if image != nil, modified == loadedModified { return }
        let loaded = await Task.detached(priority: .userInitiated) { NSImage(contentsOf: fileURL) }.value
        if let loaded {
            image = loaded
            loadedModified = modified
            missing = false
        } else {
            missing = true
        }
    }
}
