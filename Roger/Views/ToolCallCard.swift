import SwiftUI

struct ToolCallCard: View {
    @Environment(AppModel.self) private var model
    let call: ToolCall
    let messageID: UUID

    private var isPending: Bool { call.status == .pending && model.pendingApprovalID == call.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: icon).foregroundStyle(iconColor).frame(width: 18)
                Text(title).font(.callout.weight(.semibold))
                Spacer()
                statusBadge
            }
            if let detail {
                Text(detail)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(6)
            }
            preview
            if isPending {
                HStack(spacing: 8) {
                    Button("Allow") { model.resolveApproval(.allow) }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                    Menu("Always allow…") {
                        ForEach(rememberOptions, id: \.title) { option in
                            Button(option.title) { model.rememberApproval(option.scope, call: call, messageID: messageID) }
                        }
                    }
                    .fixedSize()
                    .help("Remember this choice for the working directory and its subfolders. Manage remembered approvals in Settings.")
                    Button("Allow all this session") { model.resolveApproval(.allowAll) }
                    Button("Deny", role: .destructive) { model.resolveApproval(.deny) }
                        .keyboardShortcut(.cancelAction)
                    Spacer()
                    Text("Roger wants to \(actionVerb).").font(.caption).foregroundStyle(.secondary)
                }
                .padding(.top, 2)
            }
            if let approvedBy = call.approvedBy, call.status != .pending {
                Label("Auto-approved: \(approvedBy)", systemImage: "checkmark.shield")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .help("A remembered approval allowed this without asking. You can forget it in Settings → Tools.")
            }
            if call.status == .running || (call.result != nil && call.status != .pending) {
                let result = call.result ?? ""
                let isCommand = ToolRegistry.isCommand(call.name)
                let def = call.status == .failed || (isCommand && (call.status == .done || call.status == .running))
                let expanded = model.isDetailExpanded(call.id, default: def)
                DisclosureRow(isExpanded: expanded, action: { model.toggleDetail(call.id, default: def) }) {
                    Text(call.status == .running ? liveSummary(result) : resultSummary(result))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                if expanded {
                    if call.name == ToolRegistry.webSearch, call.status == .done {
                        MarkdownView(text: result)
                            .padding(8)
                            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
                    } else {
                        LiveOutputView(text: result.count > 6000 && call.status != .running ? String(result.prefix(6000)) + "\n…" : result,
                                       isLive: call.status == .running)
                    }
                }
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(isPending ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: isPending ? 1.5 : 1))

    }

    @ViewBuilder
    private var preview: some View {
        switch call.name {
        case ToolRegistry.writeFile:
            if let content = call.string("content") {
                let full = diffForWrite(content)
                DiffDisclosure(fileName: shortPath(call.string("path") ?? "file"),
                               displayLines: Diff.collapse(full, context: 2),
                               added: full.lazy.filter { $0.kind == .added }.count,
                               removed: full.lazy.filter { $0.kind == .removed }.count)
            }
        case ToolRegistry.editFile:
            if let old = call.string("old_text"), let new = call.string("new_text") {
                let full = Diff.lines(old: old, new: new)
                DiffDisclosure(fileName: shortPath(call.string("path") ?? "file"),
                               displayLines: full,
                               added: full.lazy.filter { $0.kind == .added }.count,
                               removed: full.lazy.filter { $0.kind == .removed }.count)
            }
        default:
            EmptyView()
        }
    }

    private func diffForWrite(_ content: String) -> [DiffLine] {
        let cwd = model.selected?.workingDirectory ?? NSHomeDirectory()
        let url = ToolExecutor.resolve(call.string("path"), cwd: cwd)
        if call.status == .pending, let existing = try? String(contentsOf: url, encoding: .utf8) {
            return Diff.lines(old: existing, new: content)
        }
        return content.components(separatedBy: "\n").map { DiffLine(kind: .added, text: $0) }
    }

    private var icon: String {
        switch call.name {
        case ToolRegistry.readFile: return "doc.text.magnifyingglass"
        case ToolRegistry.writeFile: return "doc.badge.plus"
        case ToolRegistry.editFile: return "pencil.line"
        case ToolRegistry.listDirectory: return "folder"
        case ToolRegistry.searchFiles: return "magnifyingglass"
        case ToolRegistry.runCommand: return "terminal"
        case ToolRegistry.webSearch: return "globe.badge.chevron.backward"
        case ToolRegistry.fetchURL: return "doc.text.below.ecg"
        default: return "wrench"
        }
    }

    private var iconColor: Color {
        switch call.status {
        case .denied, .failed: return .red
        case .pending: return .orange
        case .cancelled: return .secondary
        default: return .accentColor
        }
    }

    private var title: String {
        let path = call.string("path").map { shortPath($0) }
        switch call.name {
        case ToolRegistry.readFile: return "Read \(path ?? "file")"
        case ToolRegistry.writeFile: return "Write \(path ?? "file")"
        case ToolRegistry.editFile: return "Edit \(path ?? "file")"
        case ToolRegistry.listDirectory: return "List \(path ?? "working directory")"
        case ToolRegistry.searchFiles: return "Search for /\(call.string("pattern") ?? "")/" + (path.map { " in \($0)" } ?? "")
        case ToolRegistry.runCommand: return "Run command"
        case ToolRegistry.webSearch: return "Search the web for “\(call.string("query") ?? "")”"
        case ToolRegistry.fetchURL: return "Read \(call.string("url") ?? "page")"
        default: return call.name
        }
    }

    private var actionVerb: String {
        switch call.name {
        case ToolRegistry.writeFile: return "write this file"
        case ToolRegistry.editFile: return "edit this file"
        case ToolRegistry.runCommand: return "run this command"
        case ToolRegistry.webSearch: return "search the web"
        case ToolRegistry.fetchURL: return "read this page"
        default: return "do this"
        }
    }

    private var detail: String? {
        if call.name == ToolRegistry.runCommand { return call.string("command") }
        return nil
    }

    private func shortPath(_ p: String) -> String {
        let cwd = model.selected?.workingDirectory ?? ""
        if !cwd.isEmpty, p.hasPrefix(cwd + "/") { return String(p.dropFirst(cwd.count + 1)) }
        return p.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch call.status {
        case .pending:
            Text("Needs approval").font(.caption).foregroundStyle(.orange)
        case .running:
            ProgressView().controlSize(.mini)
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        case .denied:
            Text("Denied").font(.caption).foregroundStyle(.red)
        case .cancelled:
            Text("Stopped").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func resultSummary(_ result: String) -> String {
        let lines = result.components(separatedBy: "\n")
        if lines.count <= 1 { return result }
        if ToolRegistry.isWeb(call.name) { return lines.first ?? "" }
        return "\(lines.count) lines of output — \(lines.first ?? "")"
    }

    private func liveSummary(_ result: String) -> String {
        if result.isEmpty { return "Running…" }
        let lines = result.components(separatedBy: "\n")
        return "Running… \(lines.count) line\(lines.count == 1 ? "" : "s") so far"
    }

    /// "Always allow" choices that fit this call.
    private var rememberOptions: [(title: String, scope: ApprovalScope)] {
        let folder = ApprovalRules.shortPath(URL(fileURLWithPath: model.selected?.workingDirectory ?? NSHomeDirectory()).standardizedFileURL.path)
        var options: [(String, ApprovalScope)] = []
        if ToolRegistry.isWeb(call.name) {
            return [(title: "Web searches and page fetches", scope: .webRequests)]
        }
        if ToolRegistry.isCommand(call.name) {
            let command = call.string("command") ?? ""
            if CommandClassifier.isReadOnly(command) {
                options.append(("Read-only commands in \(folder)", .readOnlyCommands))
            }
            if let sig = CommandClassifier.signature(command) {
                options.append(("Commands like “\(sig)” in \(folder)", .commandsLike(sig)))
            }
            options.append(("Any command in \(folder)", .allCommands))
        } else {
            options.append(("File writes and edits in \(folder)", .fileEdits))
        }
        return options.map { (title: $0.0, scope: $0.1) }
    }
}

/// A collapsible file diff: header shows the file name with green +added / red -removed
/// line counts; the body shows the red/green diff and can be retracted to just the header.
struct DiffDisclosure: View {
    let fileName: String
    let displayLines: [DiffLine]
    let added: Int
    let removed: Int
    @State private var expanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            DisclosureRow(isExpanded: expanded,
                          trailing: expanded ? "Hide diff" : "Show diff",
                          action: { withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() } }) {
                HStack(spacing: 6) {
                    Image(systemName: "doc.text").font(.caption).foregroundStyle(.secondary)
                    Text(fileName).font(.callout.weight(.medium))
                    if added > 0 {
                        Text("+\(added)").font(.caption.weight(.semibold).monospacedDigit()).foregroundStyle(.green)
                    }
                    if removed > 0 {
                        Text("-\(removed)").font(.caption.weight(.semibold).monospacedDigit()).foregroundStyle(.red)
                    }
                    if added == 0 && removed == 0 {
                        Text("no changes").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .help(expanded ? "Retract the diff" : "Show the changed lines")

            if expanded {
                DiffView(lines: displayLines)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

struct DiffView: View {
    let lines: [DiffLine]

    var body: some View {
        // Both axes: a long file must scroll inside the card, not spill over the chat.
        ScrollView([.vertical, .horizontal]) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(lines.prefix(400)) { line in
                    HStack(spacing: 0) {
                        Text(prefix(line.kind))
                            .frame(width: 16)
                            .foregroundStyle(.secondary)
                        Text(line.text.isEmpty ? " " : line.text)
                    }
                    .font(.system(.caption, design: .monospaced))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(background(line.kind))
                }
                if lines.count > 400 {
                    Text("… \(lines.count - 400) more lines").font(.caption).foregroundStyle(.secondary).padding(6)
                }
            }
            .textSelection(.enabled)
        }
        .frame(maxHeight: 360)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 6))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func prefix(_ kind: DiffLine.Kind) -> String {
        switch kind { case .same: return " "; case .added: return "+"; case .removed: return "-" }
    }

    private func background(_ kind: DiffLine.Kind) -> Color {
        switch kind {
        case .same: return .clear
        case .added: return .green.opacity(0.18)
        case .removed: return .red.opacity(0.18)
        }
    }
}
