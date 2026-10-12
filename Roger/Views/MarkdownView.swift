import SwiftUI
import QuickLook

enum MarkdownBlock: Hashable {
    case paragraph(String)
    case heading(Int, String)
    /// `complete` is false while the closing fence has not arrived yet (a streaming reply).
    case code(lang: String, code: String, complete: Bool)
    /// `start` is the number of the first item of an ordered list, so a list that a code
    /// block or a paragraph interrupted continues its numbering.
    case list(items: [String], ordered: Bool, start: Int)
    case quote(String)
    case table([String])
    case rule
    /// An image the text refers to. `explicit` is Markdown image syntax; otherwise it is a
    /// bare path the model mentioned, shown only if the file exists.
    case image(alt: String, source: String, explicit: Bool)
}

enum MarkdownParser {
    static func parse(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        let lines = text.components(separatedBy: "\n")
        var i = 0
        var paragraph: [String] = []
        var listItems: [String] = []
        var listOrdered = false
        var listStart = 1
        var quote: [String] = []
        var table: [String] = []
        /// The block most recently added was a list: indented lines that follow belong to it
        /// (nested items, continuation text), not to an indented code block.
        var afterList = false

        func flushParagraph() {
            if !paragraph.isEmpty {
                let (text, images) = extractImages(paragraph.joined(separator: "\n"))
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { blocks.append(.paragraph(text)) }
                blocks.append(contentsOf: images)
                paragraph = []
                afterList = false
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
                blocks.append(.list(items: items, ordered: listOrdered, start: listStart))
                blocks.append(contentsOf: images)
                listItems = []
                afterList = true
            }
        }
        func flushQuote() {
            if !quote.isEmpty { blocks.append(.quote(quote.joined(separator: "\n"))); quote = []; afterList = false }
        }
        func flushTable() {
            if !table.isEmpty { blocks.append(.table(table)); table = []; afterList = false }
        }
        func flushAll() { flushParagraph(); flushList(); flushQuote(); flushTable() }

        // A reply that begins inside a code block (the model continuing one it could no longer
        // see): indented code first, then a bare closing fence before any opening one. All of
        // it up to that fence is code.
        func isFence(_ l: String) -> Bool { let t = l.trimmingCharacters(in: .whitespaces); return t.hasPrefix("```") || t.hasPrefix("~~~") }
        func fenceTag(_ l: String) -> String { l.trimmingCharacters(in: .whitespaces).dropFirst(3).trimmingCharacters(in: .whitespaces) }
        if let first = lines.firstIndex(where: isFence), fenceTag(lines[first]).isEmpty,
           let next = lines[(first + 1)...].firstIndex(where: isFence), !fenceTag(lines[next]).isEmpty,
           let firstText = lines[..<first].first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
           firstText.first?.isWhitespace == true {
            let code = lines[..<first].joined(separator: "\n").trimmingCharacters(in: .newlines)
            blocks.append(.code(lang: "", code: code, complete: true))
            i = first + 1
        }

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                let fence = String(trimmed.prefix(3))
                let lang = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                // A bare fence whose next fence carries a language is a stray closing fence,
                // not an opener: models sometimes start a reply as if a code block were
                // already open. Skipping it keeps the text after it as Markdown and lets the
                // tagged fence open the real block.
                if lang.isEmpty,
                   let next = lines[(i + 1)...].firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix(fence) }),
                   !lines[next].trimmingCharacters(in: .whitespaces).dropFirst(3).trimmingCharacters(in: .whitespaces).isEmpty {
                    i += 1
                    continue
                }
                flushAll()
                var code: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    code.append(lines[i]); i += 1
                }
                blocks.append(.code(lang: lang, code: code.joined(separator: "\n"), complete: i < lines.count))
                afterList = false
                i += 1
                continue
            }

            if trimmed.isEmpty {
                flushAll(); i += 1; continue
            }

            // An indented code block (four spaces or a tab) at a block boundary, as models
            // often write instead of fences. It cannot interrupt a paragraph or a list, where
            // such lines are continuation text. Blank lines inside it are kept; trailing ones
            // are left to the normal flow.
            if paragraph.isEmpty, listItems.isEmpty, quote.isEmpty, table.isEmpty, !afterList, isIndentedCode(line) {
                var code: [String] = []
                var j = i
                var pendingBlank = 0
                while j < lines.count {
                    let l = lines[j]
                    if l.trimmingCharacters(in: .whitespaces).isEmpty { pendingBlank += 1; j += 1; continue }
                    guard isIndentedCode(l) else { break }
                    code.append(contentsOf: Array(repeating: "", count: pendingBlank)); pendingBlank = 0
                    code.append(dedent(l))
                    j += 1
                }
                // Still growing while the reply streams unless something follows it.
                blocks.append(.code(lang: "", code: code.joined(separator: "\n"), complete: j < lines.count))
                i = j - pendingBlank
                continue
            }

            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flushAll(); blocks.append(.rule); afterList = false; i += 1; continue
            }

            if let heading = parseHeading(trimmed) {
                flushAll(); blocks.append(.heading(heading.0, heading.1)); afterList = false; i += 1; continue
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
                if listItems.isEmpty { listStart = item.number ?? 1 }
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

    /// Results for the paragraphs seen most recently. A streaming reply is parsed again on
    /// every refresh, and only its last paragraph has changed.
    private static let imageCache = RenderCache<(String, [MarkdownBlock])>(capacity: 2048)

    /// Pulls image references out of a text run: Markdown images are removed from the text
    /// (their alt text stays) and bare image paths are reported as candidates.
    static func extractImages(_ text: String) -> (String, [MarkdownBlock]) {
        imageCache.value(for: text) { extractImagesUncached(text) }
    }

    private static func extractImagesUncached(_ text: String) -> (String, [MarkdownBlock]) {
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

    private static func isIndentedCode(_ line: String) -> Bool {
        line.hasPrefix("    ") || line.hasPrefix("\t")
    }

    private static func dedent(_ line: String) -> String {
        line.hasPrefix("\t") ? String(line.dropFirst()) : String(line.dropFirst(4))
    }

    private static func parseHeading(_ s: String) -> (Int, String)? {
        var level = 0
        var idx = s.startIndex
        while idx < s.endIndex, s[idx] == "#", level < 6 { level += 1; idx = s.index(after: idx) }
        guard level > 0, idx < s.endIndex, s[idx] == " " else { return nil }
        return (level, String(s[idx...]).trimmingCharacters(in: .whitespaces))
    }

    private static func parseListItem(_ line: String) -> (text: String, ordered: Bool, number: Int?)? {
        let t = line.trimmingCharacters(in: .whitespaces)
        for marker in ["- ", "* ", "+ ", "• "] where t.hasPrefix(marker) {
            return (String(t.dropFirst(marker.count)), false, nil)
        }
        if t.hasPrefix("- [ ] ") || t.hasPrefix("- [x] ") { return (String(t.dropFirst(2)), false, nil) }
        var digits = 0
        var idx = t.startIndex
        while idx < t.endIndex, t[idx].isNumber, digits < 4 { digits += 1; idx = t.index(after: idx) }
        if digits > 0, idx < t.endIndex, t[idx] == "." || t[idx] == ")" {
            let after = t.index(after: idx)
            if after < t.endIndex, t[after] == " " {
                return (String(t[after...]).trimmingCharacters(in: .whitespaces), true, Int(t[..<idx]))
            }
        }
        return nil
    }
}

/// Renders Markdown text. It stores only comparable values (no closures), so SwiftUI skips
/// it entirely while its text is unchanged.
struct MarkdownView: View {
    let text: String
    /// Offer to send the output of a command run from a code block back to the model.
    var canSendOutput = true
    /// Whether the text can be selected. Off while a reply streams: selectable text is an
    /// AppKit text field under the hood, and updating those on every refresh is what kept
    /// the main thread busy (and, once, spinning) during long replies.
    var selectable = true
    /// Smaller headings, for the thinking section.
    var compact = false

    var body: some View {
        // Blocks are identified by position, so the paragraph or code block at the end of a
        // streaming reply is updated in place on every refresh instead of being replaced.
        let blocks = MarkdownParser.parse(text)
        return VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                render(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func render(_ block: MarkdownBlock) -> some View {
        switch block {
        case .paragraph(let s):
            Text(inline(s)).selectable(selectable).lineSpacing(3)
        case .heading(let level, let s):
            Text(inline(s))
                .font(compact ? (level <= 2 ? .headline : .subheadline.bold())
                              : (level == 1 ? .title2.bold() : level == 2 ? .title3.bold() : .headline))
                .padding(.top, 4)
                .selectable(selectable)
        case .code(let lang, let code, let complete):
            CodeBlockView(language: lang, code: code, complete: complete, canSendOutput: canSendOutput, selectable: selectable)
        case .list(let items, let ordered, let start):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(ordered ? "\(start + idx)." : "•")
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 16, alignment: .trailing)
                        Text(inline(item)).selectable(selectable)
                    }
                }
            }
        case .quote(let s):
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 2).fill(Color.accentColor.opacity(0.6)).frame(width: 3)
                Text(inline(s)).foregroundStyle(.secondary).selectable(selectable)
            }
        case .table(let rows):
            table(rows)
        case .rule:
            Divider()
        case .image(let alt, let source, let explicit):
            ImageBlockView(alt: alt, source: source, explicit: explicit)
        }
    }

    /// A Markdown table: the first row is the header and cells keep inline Markdown such as
    /// bold. Columns are as wide as their content; when the table is wider than the chat, the
    /// wide columns give way and their cells wrap (see `TableLayout`). Cells are rendered one
    /// by one, so while a table streams only its last row is new work.
    private func table(_ rows: [String]) -> some View {
        let parsed = rows.map(Self.tableCells)
        let columns = max(1, parsed.first?.count ?? 1)
        let cells = parsed.flatMap { row in (0..<columns).map { $0 < row.count ? row[$0] : "" } }
        return TableLayout(columns: columns) {
            ForEach(Array(cells.enumerated()), id: \.offset) { index, cell in
                let header = index < columns
                Text(inline(cell))
                    .fontWeight(header ? .semibold : .regular)
                    .padding(.trailing, 16)
                    .padding(.bottom, header ? 5 : 0)
                    .overlay(alignment: .bottom) {
                        if header { Rectangle().fill(Color.secondary.opacity(0.35)).frame(height: 1) }
                    }
                    .selectable(selectable)
            }
        }
        .padding(.vertical, 2)
    }

    /// The cells of one `| a | b |` row.
    static func tableCells(_ row: String) -> [String] {
        var r = Substring(row.trimmingCharacters(in: .whitespaces))
        if r.hasPrefix("|") { r = r.dropFirst() }
        if r.hasSuffix("|") { r = r.dropLast() }
        return r.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// Inline Markdown for the paragraphs rendered most recently. While a reply streams, every
    /// refresh renders all of its paragraphs again and only the last one has changed.
    private static let inlineCache = RenderCache<AttributedString>(capacity: 2048)

    private func inline(_ s: String) -> AttributedString {
        Self.inlineCache.value(for: s) {
            (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
                ?? AttributedString(s)
        }
    }
}

struct CodeBlockView: View {
    let language: String
    let code: String
    /// The closing fence has arrived. Until then (and while the reply still streams) the code
    /// is shown plain, one Text per line: highlighting and laying out a growing block again
    /// on every refresh was the main cost of streaming code, whereas with one view per line
    /// only the last line is new work. The finished block is highlighted once and cached.
    var complete = true
    var canSendOutput = true
    var selectable = true

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
            .buttonStyle(.hoverPress)
            .font(.caption)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(0.06))

            ScrollView(.horizontal, showsIndicators: false) {
                Group {
                    if complete || selectable {
                        Text(SyntaxHighlighter.highlight(code, language: language))
                            .selectable(selectable)
                    } else {
                        let lines = code.split(separator: "\n", omittingEmptySubsequences: false)
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(lines.indices, id: \.self) { i in
                                Text(lines[i].isEmpty ? " " : String(lines[i]))
                            }
                        }
                    }
                }
                .font(.system(.callout, design: .monospaced))
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
                        if canSendOutput, !running {
                            Button("Send output to Roger") {
                                model.send(text: "I ran `\(command)` and got:\n```\n\(output)\n```", attachments: [])
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
                        .selectable(!isLive)
                        .padding(8)
                    Color.clear.frame(height: 1).id("end")
                }
            }
            .frame(maxHeight: maxHeight)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .onChange(of: text.utf8.count) { _, _ in
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

extension View {
    /// `textSelection(.enabled)` when `enabled`, plain text otherwise.
    @ViewBuilder
    func selectable(_ enabled: Bool) -> some View {
        if enabled { textSelection(.enabled) } else { self }
    }
}

/// Lays out table cells (row-major, `columns` per row). Each column is as wide as its widest
/// cell when that fits. Otherwise a column can shrink down to `narrowColumnWidth` (or its
/// own width if it is narrower, so short names and numbers never wrap), and the shortfall is
/// shared in proportion to how much each column can give, so a column of long notes wraps
/// while a column of short names keeps its width. Rows are as tall as their tallest cell.
struct TableLayout: Layout {
    var columns: Int
    var rowSpacing: CGFloat = 5
    var narrowColumnWidth: CGFloat = 120

    private func columnWidths(_ subviews: Subviews, fitting width: CGFloat?) -> [CGFloat] {
        let cols = max(1, columns)
        var ideal = [CGFloat](repeating: 0, count: cols)
        for (i, view) in subviews.enumerated() {
            ideal[i % cols] = max(ideal[i % cols], view.sizeThatFits(.unspecified).width)
        }
        let minimum = ideal.map { min($0, narrowColumnWidth) }
        let idealTotal = ideal.reduce(0, +), minimumTotal = minimum.reduce(0, +)
        guard let width, idealTotal > width else { return ideal }
        guard minimumTotal < width, idealTotal > minimumTotal else { return minimum }
        let t = (width - minimumTotal) / (idealTotal - minimumTotal)
        return (0..<cols).map { floor(minimum[$0] + (ideal[$0] - minimum[$0]) * t) }
    }

    private func rowHeights(_ subviews: Subviews, widths: [CGFloat]) -> [CGFloat] {
        let cols = widths.count
        var heights: [CGFloat] = []
        for (i, view) in subviews.enumerated() {
            let row = i / cols
            if row == heights.count { heights.append(0) }
            let h = view.sizeThatFits(ProposedViewSize(width: widths[i % cols], height: nil)).height
            heights[row] = max(heights[row], h)
        }
        return heights
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let widths = columnWidths(subviews, fitting: proposal.width)
        let heights = rowHeights(subviews, widths: widths)
        return CGSize(width: widths.reduce(0, +),
                      height: heights.reduce(0, +) + rowSpacing * CGFloat(max(0, heights.count - 1)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let widths = columnWidths(subviews, fitting: bounds.width)
        let heights = rowHeights(subviews, widths: widths)
        let cols = widths.count
        var y = bounds.minY
        for (i, view) in subviews.enumerated() {
            let col = i % cols, row = i / cols
            if col == 0, row > 0 { y += heights[row - 1] + rowSpacing }
            let x = bounds.minX + widths[..<col].reduce(0, +)
            view.place(at: CGPoint(x: x, y: y), anchor: .topLeading,
                       proposal: ProposedViewSize(width: widths[col], height: heights[row]))
        }
    }
}
