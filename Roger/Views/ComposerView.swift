import SwiftUI
import UniformTypeIdentifiers

struct ComposerView: View {
    @Environment(AppModel.self) private var model
    @State private var text = ""
    @State private var attachments: [Attachment] = []
    @State private var isTargeted = false
    @State private var dropMessage: String?
    @State private var focusRequest = 0
    @State private var editorHeight: CGFloat = 22
    @State private var pastedImages = 0

    private var canSend: Bool {
        !(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty) && model.status.isConnected && !model.isGenerating && !imageConflict
    }

    /// Images are attached but the chat's model is known not to support vision.
    private var imageConflict: Bool {
        attachments.contains(where: \.isImage) && model.modelSupportsVision(model.currentModelName) == false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(attachments) { a in
                            AttachmentChip(attachment: a) { attachments.removeAll { $0.id == a.id } }
                        }
                    }
                }
            }
            if imageConflict { imageConflictBar }
            HStack(alignment: .bottom, spacing: 8) {
                Button { pickFiles() } label: { Image(systemName: "paperclip").font(.title3) }
                    .buttonStyle(.borderless)
                    .help("Attach files")

                ComposerTextView(text: $text, height: $editorHeight,
                                 placeholder: "Message Roger…  (⌥⏎ for a new line, drop files here)",
                                 focusRequest: focusRequest,
                                 onSubmit: send,
                                 onDropFiles: { urls in for url in urls { add(url) } },
                                 onPasteImage: addPastedImage,
                                 onDragTargeted: { isTargeted = $0 })
                    .frame(height: editorHeight)

                if model.isGenerating {
                    Button { model.stopGeneration() } label: { Image(systemName: "stop.circle.fill").font(.title2) }
                        .buttonStyle(.borderless)
                        .help("Stop (⌘.)")
                } else {
                    Button(action: send) { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                        .buttonStyle(.borderless)
                        .disabled(!canSend)
                        .help("Send (⏎)")
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(isTargeted ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: isTargeted ? 2 : 1))
            )
            HStack(alignment: .firstTextBaseline) {
                if let dropMessage {
                    Text(dropMessage).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let convo = model.selected {
                    ContextMeter(plan: model.contextPlan(for: convo), modelName: model.currentModelName,
                                 configuredWindow: model.settings.contextLength,
                                 modelMax: model.currentModelName.flatMap { model.modelStats[$0]?.contextLength },
                                 lastPromptTokens: convo.messages.last(where: { $0.promptTokens != nil })?.promptTokens)
                }
            }
            .frame(minHeight: 14)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            handleDrop(providers)
            return true
        }
        .onAppear { focusRequest += 1 }
        .onChange(of: model.selectedID) { _, _ in focusRequest += 1 }
    }

    private var imageConflictBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "eye.slash").foregroundStyle(.orange)
            Text("\(model.currentModelName ?? "This model") can't look at images.")
                .font(.callout)
            Spacer()
            if model.visionModels.isEmpty {
                Button("Get a vision model…") { model.showModelsSheet = true }
                    .help("No installed model supports images. Pull qwen2.5vl, gemma3 or llava from the Models window.")
            } else if model.visionModels.count == 1, let only = model.visionModels.first {
                Button("Use \(only.name)") { model.setModel(only.name) }
            } else {
                Menu("Switch model") {
                    ForEach(model.visionModels) { m in
                        Button(m.name) { model.setModel(m.name) }
                    }
                }
                .fixedSize()
            }
            Button("Remove images") { attachments.removeAll(where: \.isImage) }
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    /// An image pasted with ⌘V becomes an attachment, sent to vision-capable models.
    private func addPastedImage(_ png: Data) {
        pastedImages += 1
        let name = pastedImages == 1 ? "Pasted image.png" : "Pasted image \(pastedImages).png"
        attachments.append(Attachment(fileName: name, path: nil, imageBase64: png.base64EncodedString()))
        dropMessage = nil
    }

    private func send() {
        guard canSend else { return }
        model.send(text: text, attachments: attachments)
        text = ""
        attachments = []
        dropMessage = nil
    }

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.message = "Attach files to your message. Choosing a folder sets it as the working directory."
        if panel.runModal() == .OK {
            for url in panel.urls { add(url) }
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) {
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in add(url) }
            }
        }
    }

    private func add(_ url: URL) {
        switch AttachmentLoader.load(url) {
        case .attachment(let a):
            if !attachments.contains(where: { $0.path == a.path }) { attachments.append(a) }
            dropMessage = nil
        case .directory(let dir):
            model.setWorkingDirectory(dir)
            dropMessage = "Working directory set to \(dir.path)"
        case .unsupported(let reason):
            dropMessage = reason
        }
    }
}

/// Compact gauge of how much of the model's context window the chat uses. Click for details.
struct ContextMeter: View {
    let plan: ContextPlan
    let modelName: String?
    let configuredWindow: Int
    let modelMax: Int?
    let lastPromptTokens: Int?
    @State private var showDetails = false

    private var color: Color {
        if plan.exceedsWindow { return .red }
        if plan.fraction > 0.8 { return .orange }
        return .secondary
    }

    var body: some View {
        Button { showDetails.toggle() } label: {
            HStack(spacing: 5) {
                ZStack {
                    Circle().stroke(Color.primary.opacity(0.12), lineWidth: 2)
                    Circle()
                        .trim(from: 0, to: min(1, plan.fraction))
                        .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: 11, height: 11)
                Text("≈\(TokenEstimator.format(plan.totalTokens)) / \(TokenEstimator.format(plan.window))")
                    .font(.caption2).monospacedDigit()
                if plan.trimmedCount > 0 {
                    Image(systemName: "scissors").font(.caption2)
                }
            }
            .foregroundStyle(color)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Estimated context window use. Click for details.")
        .popover(isPresented: $showDetails, arrowEdge: .bottom) { details }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Context window").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 5) {
                row("Window", "\(plan.window.formatted()) tokens" + windowNote)
                row("Conversation", "≈ \(plan.totalTokens.formatted()) tokens")
                row("System prompt & tools", "≈ \(plan.fixedTokens.formatted()) tokens")
                row("Reserved for the reply", "\(plan.reserve.formatted()) tokens")
                if plan.trimmedCount > 0 {
                    row("Trimmed", "\(plan.trimmedCount) oldest message\(plan.trimmedCount == 1 ? "" : "s") not sent; ≈ \(plan.sentTokens.formatted()) tokens go to the model")
                }
                if let lastPromptTokens {
                    row("Last request", "\(lastPromptTokens.formatted()) prompt tokens, as counted by Ollama")
                }
            }
            .font(.callout)
            Text(plan.autoTrim
                 ? "When the chat outgrows the window, Roger stops sending the oldest turns. Estimates assume about 4 characters per token."
                 : "Automatic trimming is off: the whole chat is sent and the model may lose track of the start. Estimates assume about 4 characters per token.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                SettingsLink { Text("Context settings…") }.controlSize(.small)
            }
        }
        .padding(14)
        .frame(width: 360)
    }

    private var windowNote: String {
        if let modelMax, modelMax < configuredWindow {
            return " (\(modelName ?? "the model") supports at most \(modelMax.formatted()); Settings asks for \(configuredWindow.formatted()))"
        }
        if let modelMax { return " of the model's \(modelMax.formatted()) maximum" }
        return ""
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(value).fixedSize(horizontal: false, vertical: true)
        }
    }
}
