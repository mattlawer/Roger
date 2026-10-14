import SwiftUI
import QuickLook

enum MarkdownBlock: Hashable {
    case paragraph(String)
    case heading(Int, String)
    /// `complete` is false while the closing fence has not arrived yet (a streaming reply).
    case code(lang: String, code: String, complete: Bool)
    case list(items: [ListItem])
    case quote(String)
    case table([String])
    case rule
    /// An image the text refers to. `explicit` is Markdown image syntax; otherwise it is a
    /// bare path the model mentioned, shown only if the file exists.
    case image(alt: String, source: String, explicit: Bool)
}

/// One item of a list, with its nesting depth and the marker to show: a bullet, or the
/// item's own number for an ordered list, so a list that a code block or a paragraph
/// interrupted keeps its numbering.
struct ListItem: Hashable {
    var text: String
    var level: Int
    var marker: String
}

enum MarkdownParser {
    /// Parsed blocks are cached by source text. While a reply streams, the growing text is a
    /// new key each refresh (a miss, but parsing a small reply is cheap); once a runaway reply
    /// passes the render cap the shown head stops changing, so every later refresh is a hit and
    /// costs nothing, instead of re-parsing kilobytes twenty times a second.
    private static let cache = RenderCache<[MarkdownBlock]>(capacity: 256)
    static func parse(_ text: String) -> [MarkdownBlock] {
        cache.value(for: text) { parseUncached(text) }
    }

    private static func parseUncached(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var lines = text.components(separatedBy: "\n")
        var i = 0
        var paragraph: [String] = []
        var listItems: [ListItem] = []
        /// Indentation widths of the open nesting levels, outermost first.
        var listIndents: [Int] = []
        /// Next number of an ordered item per level, when the model numbers nothing.
        var listCounts: [Int: Int] = [:]
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
                let items = listItems.map { item -> ListItem in
                    let (text, found) = extractImages(item.text)
                    images.append(contentsOf: found)
                    return ListItem(text: text, level: item.level, marker: item.marker)
                }
                blocks.append(.list(items: items))
                blocks.append(contentsOf: images)
                listItems = []
                listIndents = []
                listCounts = [:]
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
                // A code block inside a list item keeps the list open: the indented text that
                // follows it is the item's continuation, not an indented code block.
                let inList = !listItems.isEmpty || afterList
                flushAll()
                var code: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    code.append(lines[i]); i += 1
                }
                blocks.append(.code(lang: lang, code: code.joined(separator: "\n"), complete: i < lines.count))
                afterList = inList
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
            // An indented list item is a list, however deep the indent.
            if paragraph.isEmpty, listItems.isEmpty, quote.isEmpty, table.isEmpty, !afterList, isIndentedCode(line), parseListItem(line) == nil {
                // Gather the contiguous indented region (blank lines within it are kept).
                var region: [String] = []
                var j = i
                var pendingBlank = 0
                while j < lines.count {
                    let l = lines[j]
                    if l.trimmingCharacters(in: .whitespaces).isEmpty { pendingBlank += 1; j += 1; continue }
                    guard isIndentedCode(l) else { break }
                    region.append(contentsOf: Array(repeating: "", count: pendingBlank)); pendingBlank = 0
                    region.append(l)
                    j += 1
                }
                let end = j - pendingBlank
                // Some models (Gemma 4, for one) indent whole reasoning sections, not just
                // code. If the region reads as prose (a sentence, emphasis, math or a list),
                // it is not a code block: dedent it by its common indent and let it parse as
                // normal Markdown, which wraps. Otherwise it is indented code, as before.
                if indentedRegionIsProse(region) {
                    let indent = region.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                        .map(leadingWidth).min() ?? 0
                    let dedented = region.map { $0.trimmingCharacters(in: .whitespaces).isEmpty ? "" : dropLeading($0, indent) }
                    lines.replaceSubrange(i..<end, with: dedented)
                    continue
                }
                // Still growing while the reply streams unless something follows it.
                blocks.append(.code(lang: "", code: region.map(dedent).joined(separator: "\n"), complete: end < lines.count))
                i = end
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
                // Nesting follows the indentation: deeper than the current level opens one,
                // shallower closes levels until one matches.
                let indent = line.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
                while let last = listIndents.last, last > indent { listIndents.removeLast() }
                if listIndents.last != indent { listIndents.append(indent) }
                let level = listIndents.count - 1
                listCounts = listCounts.filter { $0.key <= level }
                let marker: String
                if item.ordered {
                    let number = item.number ?? listCounts[level, default: 1]
                    listCounts[level] = number + 1
                    marker = "\(number)."
                } else {
                    marker = level == 0 ? "•" : level == 1 ? "◦" : "▪"
                }
                listItems.append(ListItem(text: item.text, level: level, marker: marker))
                i += 1; continue
            }

            if !listItems.isEmpty, line.hasPrefix("  ") || line.hasPrefix("\t") {
                listItems[listItems.count - 1].text += "\n" + trimmed
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

    /// Columns of leading indentation, a tab counting as four.
    private static func leadingWidth(_ line: String) -> Int {
        var n = 0
        for ch in line {
            if ch == " " { n += 1 } else if ch == "\t" { n += 4 } else { break }
        }
        return n
    }

    /// `line` with `width` columns of leading indentation removed (tabs count as four).
    private static func dropLeading(_ line: String, _ width: Int) -> String {
        var remaining = width
        var idx = line.startIndex
        while remaining > 0, idx < line.endIndex {
            if line[idx] == " " { remaining -= 1 } else if line[idx] == "\t" { remaining -= 4 } else { break }
            idx = line.index(after: idx)
        }
        return String(line[idx...])
    }

    /// Whether an indented block is prose a model merely indented, not a code block. The
    /// tells are a list item with words, inline `$…$` math, Markdown emphasis, or a plain
    /// sentence. Real code seldom has any of these, so it still renders as code.
    private static func indentedRegionIsProse(_ region: [String]) -> Bool {
        for raw in region {
            let t = raw.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { continue }
            if let item = parseListItem(t), item.text.contains(" ") { return true }
            if hasInlineMath(t) || hasEmphasis(t) || sentenceLike(t) { return true }
        }
        return false
    }

    private static func hasInlineMath(_ t: String) -> Bool {
        guard let first = t.firstIndex(of: "$") else { return false }
        let after = t.index(after: first)
        guard after < t.endIndex, t[after] != " " else { return false }
        return t[after...].contains("$")
    }

    private static func hasEmphasis(_ t: String) -> Bool {
        if t.range(of: "\\*\\*\\S", options: .regularExpression) != nil { return true }
        if t.range(of: "\\*[^\\s*][^*]*\\*", options: .regularExpression) != nil { return true }
        if t.range(of: "(^|[^A-Za-z0-9_])_[^\\s_][^_]*_([^A-Za-z0-9_]|$)", options: .regularExpression) != nil { return true }
        return false
    }

    /// A natural-language sentence: begins with a capital letter, has several words, and ends
    /// in sentence punctuation. Code rarely matches, so it is left as code.
    private static func sentenceLike(_ t: String) -> Bool {
        guard let first = t.first, first.isLetter, first.isUppercase else { return false }
        guard let last = t.last, ".?!".contains(last) else { return false }
        return t.split(separator: " ").count >= 5
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
struct MarkdownView: View, Equatable {
    let text: String
    /// Offer to send the output of a command run from a code block back to the model.
    var canSendOutput = true
    /// Whether the text can be selected. Off while a reply streams: selectable text is an
    /// AppKit text field under the hood, and updating those on every refresh is what kept
    /// the main thread busy (and, once, spinning) during long replies.
    var selectable = true
    /// Smaller headings, for the thinking section.
    var compact = false
    /// The reply is still arriving. Only then is a very long message clamped for display: a
    /// runaway reply is re-laid-out on every refresh, so its cost must stay bounded; a
    /// finished message is rendered once and shown in full.
    var streaming = false

    /// Equal when the same text would be shown: the flags match and the clamped head is the
    /// same. SwiftUI then skips re-rendering a reply that has already grown past the render
    /// cap, so a model stuck repeating itself no longer re-lays-out the block twenty times a
    /// second.
    static func == (a: MarkdownView, b: MarkdownView) -> Bool {
        guard a.canSendOutput == b.canSendOutput, a.selectable == b.selectable,
              a.compact == b.compact, a.streaming == b.streaming else { return false }
        return a.shownText == b.shownText
    }

    /// The text actually laid out: clamped to the render cap only while streaming.
    private var shownText: String { streaming ? Self.clamp(text).text : text }

    /// How much of a message is laid out as Markdown. A reply that runs away (a model stuck
    /// repeating itself streams tens of thousands of characters in seconds) is parsed and,
    /// while it is still open, rendered line by line on every refresh; past this size that
    /// work pegs a core. Only the start is shown, with a note; the full text is still copied,
    /// searched and sent to the model from the message itself.
    static let maxRenderBytes = 16_000

    var body: some View {
        let shown = streaming ? Self.clamp(text) : (text: text, omitted: 0)
        // Blocks are identified by position, so the paragraph or code block at the end of a
        // streaming reply is updated in place on every refresh instead of being replaced.
        let blocks = MarkdownParser.parse(shown.text)
        return VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                render(block)
            }
            if shown.omitted > 0 {
                Text("… \(shown.omitted.formatted()) more characters not shown. Use Copy to get the whole message.")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The leading part of `text` to render, cut at a line break near the limit, with the
    /// number of characters left out.
    private static func clamp(_ text: String) -> (text: String, omitted: Int) {
        guard text.utf8.count > maxRenderBytes else { return (text, 0) }
        var end = text.startIndex
        var bytes = 0
        var lastBreak: String.Index?
        while end < text.endIndex, bytes < maxRenderBytes {
            if text[end] == "\n" { lastBreak = end }
            bytes += String(text[end]).utf8.count
            end = text.index(after: end)
        }
        let cut = lastBreak.map { text.index(after: $0) } ?? end
        return (String(text[..<cut]), text.distance(from: cut, to: text.endIndex))
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
        case .list(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(item.marker)
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 16, alignment: .trailing)
                        // Claim the remaining width and grow in height: without this a long
                        // nested item sometimes takes its one-line ideal width and is
                        // truncated with an ellipsis instead of wrapping.
                        Text(inline(item.text))
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .selectable(selectable)
                    }
                    .padding(.leading, CGFloat(item.level) * 20)
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
            let text = MathText.rendering(s)
            return (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
                ?? AttributedString(text)
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
                            // Take the full height: inside the reasoning section's styled
                            // container a multi-line Text otherwise collapses to one line
                            // ending in an ellipsis.
                            .fixedSize(horizontal: false, vertical: true)
                            .selectable(selectable)
                    } else {
                        let lines = code.split(separator: "\n", omittingEmptySubsequences: false)
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(lines.indices, id: \.self) { i in
                                Text(lines[i].isEmpty ? " " : String(lines[i]))
                            }
                        }
                        .fixedSize(horizontal: false, vertical: true)
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

/// Turns TeX math spans in chat text into plain Unicode, so `$CO_2$` reads as CO₂ and
/// `$\alpha \leq \beta$` as α ≤ β, without a math typesetter. The constructs models use in
/// conversation are covered: sub- and superscripts, Greek letters, operators and arrows,
/// fractions, roots, \text and friends. Anything else keeps its characters, minus the
/// backslashes and braces. Code spans are left alone, and a lone dollar sign (a price) is
/// not math: like Pandoc, an opening `$` needs a non-space right after it and a closing `$`
/// a non-space right before it and no digit after it.
enum MathText {
    static func rendering(_ s: String) -> String {
        guard s.contains("$") || s.contains("\\(") || s.contains("\\[") else { return s }
        var out = ""
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            if c == "`" {
                // A code span is copied as it is, up to the matching run of backticks.
                var run = i
                while run < s.endIndex, s[run] == "`" { run = s.index(after: run) }
                let ticks = String(s[i..<run])
                if let close = s.range(of: ticks, range: run..<s.endIndex) {
                    out += s[i..<close.upperBound]; i = close.upperBound
                } else {
                    out += ticks; i = run
                }
                continue
            }
            if c == "\\" {
                let next = s.index(after: i)
                if next < s.endIndex {
                    let n = s[next]
                    if n == "$" { out.append("$"); i = s.index(after: next); continue }
                    if n == "(" || n == "[" {
                        let bodyStart = s.index(after: next)
                        if let close = s.range(of: n == "(" ? "\\)" : "\\]", range: bodyStart..<s.endIndex) {
                            out += convert(String(s[bodyStart..<close.lowerBound])); i = close.upperBound; continue
                        }
                    }
                }
                out.append(c); i = next; continue
            }
            if c == "$", let span = mathSpan(in: s, from: i) {
                out += convert(span.body); i = span.end; continue
            }
            out.append(c); i = s.index(after: i)
        }
        return out
    }

    /// The math span opening at `start` (a `$`): its TeX body and the index after it.
    private static func mathSpan(in s: String, from start: String.Index) -> (body: String, end: String.Index)? {
        let afterDollar = s.index(after: start)
        guard afterDollar < s.endIndex else { return nil }
        if s[afterDollar] == "$" {
            let bodyStart = s.index(after: afterDollar)
            guard let close = s.range(of: "$$", range: bodyStart..<s.endIndex) else { return nil }
            let body = String(s[bodyStart..<close.lowerBound])
            guard !body.isEmpty, body.utf8.count <= 2000 else { return nil }
            return (body, close.upperBound)
        }
        guard !s[afterDollar].isWhitespace else { return nil }
        var j = afterDollar
        var previous: Character = "$"
        var length = 0
        while j < s.endIndex {
            let c = s[j]
            if c == "$", previous != "\\", !previous.isWhitespace {
                let after = s.index(after: j)
                if after == s.endIndex || !s[after].isNumber {
                    return (String(s[afterDollar..<j]), after)
                }
            }
            // A span never crosses a blank line or runs into a code span.
            if c == "`" || (c == "\n" && previous == "\n") { return nil }
            length += 1
            if length > 400 { return nil }
            previous = c
            j = s.index(after: j)
        }
        return nil
    }

    static func convert(_ tex: String) -> String {
        var parser = Parser(Array(tex))
        return parser.sequence(until: nil).trimmingCharacters(in: .whitespaces)
    }

    private struct Parser {
        let chars: [Character]
        var i = 0
        init(_ chars: [Character]) { self.chars = chars }

        mutating func sequence(until terminator: Character?) -> String {
            var out = ""
            while i < chars.count {
                let c = chars[i]
                if let terminator, c == terminator { i += 1; return out }
                switch c {
                case "{": i += 1; out += sequence(until: "}")
                case "}": i += 1
                case "\\":
                    i += 1
                    let symbol = command()
                    out += symbol
                    // TeX swallows the space after a command: "\\Delta G" is ΔG. Only a
                    // letter-like symbol does so here, so "\\sin x" and "a \\times b" keep theirs.
                    if symbol.count == 1, symbol.first!.isLetter {
                        var j = i
                        while j < chars.count, chars[j] == " " { j += 1 }
                        if j > i, j < chars.count, chars[j].isLetter || chars[j].isNumber { i = j }
                    }
                case "_": i += 1; out += script(atom(), MathText.subscripts, marker: "_")
                case "^": i += 1; out += script(atom(), MathText.superscripts, marker: "^")
                case "~", "&": i += 1; out += " "
                default: out.append(c); i += 1
                }
            }
            return out
        }

        /// One argument: a braced group, a command, or a single character.
        mutating func atom() -> String {
            guard i < chars.count else { return "" }
            let c = chars[i]
            if c == "{" { i += 1; return sequence(until: "}") }
            if c == "\\" { i += 1; return command() }
            i += 1
            return String(c)
        }

        mutating func command() -> String {
            var name = ""
            while i < chars.count, chars[i].isLetter { name.append(chars[i]); i += 1 }
            if name.isEmpty {
                guard i < chars.count else { return "" }
                let c = chars[i]; i += 1
                switch c {
                case ",", ";", ":", " ": return " "
                case "!": return ""
                case "\\": return "; "
                default: return String(c)
                }
            }
            switch name {
            case "frac", "dfrac", "tfrac":
                let a = atom(), b = atom()
                return group(a) + "/" + group(b)
            case "sqrt":
                if i < chars.count, chars[i] == "[" {
                    while i < chars.count, chars[i] != "]" { i += 1 }
                    i += 1
                }
                let a = atom()
                return "√" + (a.count == 1 ? a : "(" + a + ")")
            case "text", "textrm", "textbf", "textit", "textsf", "texttt", "mathrm", "mathbf", "mathit", "mathsf", "mathtt", "mathcal", "mathbb", "mathfrak", "boldsymbol", "bm", "operatorname", "hat", "vec", "bar", "tilde", "dot", "ddot", "overline", "underline", "widehat", "widetilde":
                return atom()
            case "begin", "end":
                _ = atom()
                return ""
            case "left", "right", "displaystyle", "textstyle", "scriptstyle", "limits", "nolimits", "mathstrut", "nonumber", "notag":
                return ""
            case "quad", "qquad":
                return "  "
            default:
                return MathText.symbols[name] ?? name
            }
        }

        /// A sub- or superscript in Unicode when every character has a form; otherwise the
        /// TeX marker stays, with parentheses around a multi-character script.
        func script(_ s: String, _ map: [Character: Character], marker: String) -> String {
            let mapped = s.compactMap { map[$0] }
            if mapped.count == s.count, !s.isEmpty { return String(mapped) }
            return marker + (s.count > 1 ? "(" + s + ")" : s)
        }

        /// A fraction part in parentheses unless it is a single token.
        func group(_ s: String) -> String {
            s.count <= 1 || s.allSatisfy({ $0.isLetter || $0.isNumber }) ? s : "(" + s + ")"
        }
    }

    static let subscripts: [Character: Character] = [
        "0": "₀", "1": "₁", "2": "₂", "3": "₃", "4": "₄", "5": "₅", "6": "₆", "7": "₇", "8": "₈", "9": "₉",
        "+": "₊", "-": "₋", "=": "₌", "(": "₍", ")": "₎",
        "a": "ₐ", "e": "ₑ", "h": "ₕ", "i": "ᵢ", "j": "ⱼ", "k": "ₖ", "l": "ₗ", "m": "ₘ", "n": "ₙ", "o": "ₒ", "p": "ₚ", "r": "ᵣ", "s": "ₛ", "t": "ₜ", "u": "ᵤ", "v": "ᵥ", "x": "ₓ",
        "β": "ᵦ", "γ": "ᵧ", "ρ": "ᵨ", "φ": "ᵩ", "χ": "ᵪ",
    ]

    static let superscripts: [Character: Character] = [
        "0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴", "5": "⁵", "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹",
        "+": "⁺", "-": "⁻", "=": "⁼", "(": "⁽", ")": "⁾",
        "a": "ᵃ", "b": "ᵇ", "c": "ᶜ", "d": "ᵈ", "e": "ᵉ", "f": "ᶠ", "g": "ᵍ", "h": "ʰ", "i": "ⁱ", "j": "ʲ", "k": "ᵏ", "l": "ˡ", "m": "ᵐ", "n": "ⁿ", "o": "ᵒ", "p": "ᵖ", "r": "ʳ", "s": "ˢ", "t": "ᵗ", "u": "ᵘ", "v": "ᵛ", "w": "ʷ", "x": "ˣ", "y": "ʸ", "z": "ᶻ",
        "A": "ᴬ", "B": "ᴮ", "D": "ᴰ", "E": "ᴱ", "G": "ᴳ", "H": "ᴴ", "I": "ᴵ", "J": "ᴶ", "K": "ᴷ", "L": "ᴸ", "M": "ᴹ", "N": "ᴺ", "O": "ᴼ", "P": "ᴾ", "R": "ᴿ", "T": "ᵀ", "U": "ᵁ", "V": "ⱽ", "W": "ᵂ",
        "α": "ᵅ", "β": "ᵝ", "γ": "ᵞ", "δ": "ᵟ", "φ": "ᵠ", "χ": "ᵡ", "θ": "ᶿ",
    ]

    static let symbols: [String: String] = [
        "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "epsilon": "ε", "varepsilon": "ε", "zeta": "ζ", "eta": "η", "theta": "θ", "vartheta": "ϑ", "iota": "ι", "kappa": "κ", "lambda": "λ", "mu": "μ", "nu": "ν", "xi": "ξ", "pi": "π", "varpi": "ϖ", "rho": "ρ", "varrho": "ϱ", "sigma": "σ", "varsigma": "ς", "tau": "τ", "upsilon": "υ", "phi": "φ", "varphi": "ϕ", "chi": "χ", "psi": "ψ", "omega": "ω",
        "Gamma": "Γ", "Delta": "Δ", "Theta": "Θ", "Lambda": "Λ", "Xi": "Ξ", "Pi": "Π", "Sigma": "Σ", "Upsilon": "Υ", "Phi": "Φ", "Psi": "Ψ", "Omega": "Ω",
        "times": "×", "cdot": "·", "div": "÷", "pm": "±", "mp": "∓", "ast": "∗", "star": "⋆", "circ": "∘", "bullet": "•",
        "leq": "≤", "le": "≤", "geq": "≥", "ge": "≥", "neq": "≠", "ne": "≠", "approx": "≈", "equiv": "≡", "sim": "∼", "simeq": "≃", "cong": "≅", "propto": "∝", "ll": "≪", "gg": "≫",
        "infty": "∞", "partial": "∂", "nabla": "∇", "sum": "∑", "prod": "∏", "int": "∫", "iint": "∬", "iiint": "∭", "oint": "∮",
        "rightarrow": "→", "to": "→", "leftarrow": "←", "gets": "←", "Rightarrow": "⇒", "Leftarrow": "⇐", "leftrightarrow": "↔", "Leftrightarrow": "⇔", "mapsto": "↦", "uparrow": "↑", "downarrow": "↓", "implies": "⇒", "iff": "⇔", "longrightarrow": "⟶", "longleftarrow": "⟵",
        "forall": "∀", "exists": "∃", "nexists": "∄", "in": "∈", "notin": "∉", "ni": "∋", "subset": "⊂", "subseteq": "⊆", "supset": "⊃", "supseteq": "⊇", "cup": "∪", "cap": "∩", "setminus": "∖", "emptyset": "∅", "varnothing": "∅",
        "neg": "¬", "lnot": "¬", "land": "∧", "wedge": "∧", "lor": "∨", "vee": "∨", "oplus": "⊕", "otimes": "⊗", "perp": "⊥", "parallel": "∥", "angle": "∠", "triangle": "△",
        "ldots": "…", "cdots": "⋯", "vdots": "⋮", "ddots": "⋱", "dots": "…",
        "langle": "⟨", "rangle": "⟩", "lfloor": "⌊", "rfloor": "⌋", "lceil": "⌈", "rceil": "⌉", "lbrace": "{", "rbrace": "}", "lvert": "|", "rvert": "|", "lVert": "‖", "rVert": "‖", "vert": "|", "Vert": "‖",
        "hbar": "ℏ", "ell": "ℓ", "Re": "ℜ", "Im": "ℑ", "aleph": "ℵ", "wp": "℘", "degree": "°", "prime": "′", "dagger": "†", "ddagger": "‡", "checkmark": "✓",
        "%": "%", "#": "#", "&": "&", "_": "_",
    ]
}
