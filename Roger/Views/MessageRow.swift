import SwiftUI
import QuickLook

struct MessageRow: View {
    @Environment(AppModel.self) private var model
    let message: ChatMessage
    var isLast: Bool = false
    @State private var hovering = false
    @State private var editing = false
    @State private var draft = ""

    private var isSearchHit: Bool { model.isSearching && model.messageMatches(message) }

    var body: some View {
        Group {
            if message.role == .user { userRow } else { assistantRow }
        }
        .padding(isSearchHit ? 6 : 0)
        .background(isSearchHit ? Color.yellow.opacity(0.14) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onHover { hovering = $0 }
        .onChange(of: model.selectedID) { _, _ in editing = false }
    }

    // MARK: - User

    private var userRow: some View {
        HStack(alignment: .top) {
            Spacer(minLength: editing ? 40 : 80)
            VStack(alignment: .trailing, spacing: 6) {
                if !message.attachments.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(message.attachments) { AttachmentChip(attachment: $0) }
                    }
                }
                if editing {
                    editor
                } else {
                    if !message.content.isEmpty {
                        Text(message.content)
                            .textSelection(.enabled)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(Color.accentColor.opacity(0.18), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    HStack(spacing: 12) {
                        if message.editedAt != nil {
                            Text("Edited").font(.caption2).foregroundStyle(.tertiary)
                        }
                        if hovering {
                            if !message.content.isEmpty {
                                Button {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(message.content, forType: .string)
                                } label: { Label("Copy", systemImage: "doc.on.doc").font(.caption2) }
                                .buttonStyle(.borderless)
                                .foregroundStyle(.secondary)
                            }
                            if !model.isGenerating {
                                Button {
                                    draft = message.content
                                    editing = true
                                } label: { Label("Edit", systemImage: "pencil").font(.caption2) }
                                .buttonStyle(.borderless)
                                .foregroundStyle(.secondary)
                                .help("Change this message and ask again from here")
                            }
                        }
                    }
                    .frame(height: 14)
                }
            }
        }
    }

    private var editor: some View {
        let discarded = model.messagesAfter(message.id)
        return VStack(alignment: .trailing, spacing: 8) {
            TextField("Edit your message…", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...15)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.accentColor, lineWidth: 1))
                .onSubmit(commitEdit)
                .onExitCommand { editing = false }
            HStack(spacing: 8) {
                if discarded > 0 {
                    Text("Sending discards the \(discarded) later message\(discarded == 1 ? "" : "s").")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { editing = false }
                    .keyboardShortcut(.cancelAction)
                Button("Send") { commitEdit() }
                    .buttonStyle(.borderedProminent)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && message.attachments.isEmpty)
                    .help("Resend from here (⏎, ⌥⏎ for a new line)")
            }
            .controlSize(.small)
        }
        .frame(maxWidth: 640)
    }

    private func commitEdit() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !(text.isEmpty && message.attachments.isEmpty) else { return }
        editing = false
        model.editAndResend(messageID: message.id, text: text)
    }

    // MARK: - Assistant

    private var assistantRow: some View {
        HStack(alignment: .top, spacing: 12) {
            RogerAvatar()
            VStack(alignment: .leading, spacing: 10) {
                let hasThinking = !(message.thinking ?? "").isEmpty
                if model.settings.showReasoning, let thinking = message.thinking, hasThinking {
                    ThinkingView(messageID: message.id, text: thinking, isStreaming: message.isStreaming && message.content.isEmpty)
                }
                if !message.content.isEmpty {
                    MarkdownView(text: message.content) { command in
                        model.send(text: command, attachments: [])
                    }
                }
                ForEach(message.toolCalls) { call in
                    ToolCallCard(call: call, messageID: message.id)
                }
                if message.isStreaming && message.content.isEmpty && message.toolCalls.isEmpty && (!hasThinking || !model.settings.showReasoning) {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(hasThinking ? "Reasoning…" : "Thinking…").foregroundStyle(.secondary)
                    }
                }
                if message.stopped && message.content.isEmpty && message.toolCalls.isEmpty && message.error == nil {
                    Text(hasThinking ? "Stopped while the model was still reasoning." : "Stopped before the model produced any output.")
                        .italic().foregroundStyle(.secondary)
                }
                if let error = message.error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
                footer
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, message.stopped ? 10 : 0)
            .overlay(alignment: .leading) {
                if message.stopped {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Color.orange.opacity(0.6))
                        .frame(width: 3)
                        .padding(.vertical, 2)
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if message.stopped {
                Label("Stopped · partial reply", systemImage: "stop.fill")
                    .font(.caption2).foregroundStyle(.orange)
                    .help("You stopped this reply before the model finished. What is shown is everything it produced.")
            }
            if message.answeredInReasoning {
                Label("Answered in its reasoning", systemImage: "brain")
                    .font(.caption2).foregroundStyle(.purple)
                    .help("The model put its whole answer in its reasoning and never wrote a final reply, so Roger shows the reasoning as the answer. Ask it to \"answer directly\" or try another model if this keeps happening.")
            }
            if let name = message.model {
                Label(name, systemImage: "cpu")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .help(modelTooltip)
            }
            if let stats = message.stats {
                Text(stats).font(.caption2).foregroundStyle(.tertiary)
            }
            if hovering && !message.content.isEmpty {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(message.content, forType: .string)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc").font(.caption2)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
            }
            if isLast && !message.isStreaming && !model.isGenerating {
                Button { model.regenerateLast() } label: {
                    Label("Regenerate", systemImage: "arrow.clockwise").font(.caption2)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Discard this reply and generate a new one")
            }
        }
        .frame(height: 14)
    }

    private var modelTooltip: String {
        var lines = ["Reply generated by \(message.model ?? "unknown model")"]
        if let p = message.promptTokens { lines.append("Prompt: \(p) tokens (as reported by Ollama)") }
        if let c = message.completionTokens { lines.append("Reply: \(c) tokens") }
        return lines.joined(separator: "\n")
    }
}

struct ThinkingView: View {
    @Environment(AppModel.self) private var model
    let messageID: UUID
    let text: String
    let isStreaming: Bool

    var body: some View {
        // Auto-expanded while the model is thinking, auto-collapsed once done,
        // unless the user has toggled it. State lives in the model so it survives scrolling.
        let expanded = model.isDetailExpanded(messageID, default: isStreaming)
        VStack(alignment: .leading, spacing: 4) {
            DisclosureRow(isExpanded: expanded, action: { model.toggleDetail(messageID, default: isStreaming) }) {
                HStack(spacing: 6) {
                    if isStreaming {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "brain").font(.caption).foregroundStyle(.secondary)
                    }
                    Text(isStreaming ? "Thinking…" : "Thought process")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            if expanded {
                Text(text)
                    .font(.callout)
                    .italic()
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(.leading, 18)
                    .padding(.trailing, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

struct AttachmentChip: View {
    let attachment: Attachment
    var onRemove: (() -> Void)? = nil
    @State private var thumbnail: NSImage?
    @State private var previewURL: URL?

    var body: some View {
        HStack(spacing: 5) {
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 18, height: 18)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            } else {
                Image(systemName: attachment.isImage ? "photo" : "doc.text")
            }
            Text(attachment.fileName).lineLimit(1)
            if let onRemove {
                Button(action: onRemove) { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.quaternary, in: Capsule())
        .contentShape(Capsule())
        .onTapGesture { previewURL = AttachmentLoader.previewURL(for: attachment) }
        .quickLookPreview($previewURL)
        .help((attachment.path ?? attachment.fileName) + "\nClick to preview")
        .task(id: attachment.id) {
            guard attachment.isImage, thumbnail == nil, let b64 = attachment.imageBase64 else { return }
            thumbnail = await Task.detached(priority: .utility) { () -> NSImage? in
                guard let data = Data(base64Encoded: b64), let img = NSImage(data: data) else { return nil }
                return img
            }.value
        }
    }
}
