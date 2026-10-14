import SwiftUI

struct ChatView: View {
    @Environment(AppModel.self) private var model
    /// How far the content extends below the visible area, in points.
    @State private var distanceFromBottom: CGFloat = 0
    /// Whether new output should pull the view to the bottom. On when the reader is at the
    /// bottom, sends a message, opens a chat or a reply starts; off once they scroll away.
    @State private var followOutput = true
    /// The reader is scrolling (gesture, wheel or momentum), as opposed to our own scrollTo.
    @State private var userScrolling = false
    /// While a freshly opened chat settles at the bottom, geometry readings are transient.
    @State private var settlingUntil = Date.distantPast
    /// While one of our animated scrolls is in flight. Content that grows faster than the
    /// animation moves (a reply starting right after the user's message) reads as distance
    /// from the bottom; in that window only a reported gesture counts as the reader leaving.
    @State private var ownScrollUntil = Date.distantPast
    /// Time of the last scroll-wheel event in the window (trackpad or mouse). Legacy mouse
    /// wheels report no scroll phases, so this is how their scrolls are told apart from ours.
    @State private var lastWheelEvent = Date.distantPast
    @State private var wheelMonitor: Any?
    /// Bumped when the view is found past the end of the content, to scroll back to the bottom.
    @State private var bottomRequest = 0
    // macOS 14 fallback measurements (see legacy probes below).
    @State private var legacyViewportHeight: CGFloat = 0
    @State private var legacyContentBottom: CGFloat = 0

    /// Distance from the bottom under which the view counts as "at the bottom".
    private static let followThreshold: CGFloat = 120
    /// Offset the reader must move away from the bottom (per geometry event) to stop following
    /// when no wheel, trackpad or scroll phase explains the move: a scrollbar drag. Content
    /// laid out after one of our scrolls can move the offset by less than this on its own.
    private static let leaveThreshold: CGFloat = 48
    /// Distance from the bottom beyond which the pill is offered once following stopped.
    private static let pillThreshold: CGFloat = 40

    /// What the body derives from the conversation. Computed once per evaluation, since the
    /// body runs on every refresh of a streaming reply and the context plan walks every message.
    private struct Derived {
        var messages: [ChatMessage]
        var plan: ContextPlan?
        /// First message still sent to the model, when older ones are trimmed.
        var trimBoundaryID: UUID?
        var trimmedVisibleCount: Int
    }

    private var derived: Derived {
        let convo = model.selected
        let all = convo?.messages ?? []
        let messages = all.filter { $0.role == .user || $0.role == .assistant }
        let plan = convo.map { model.contextPlan(for: $0) }
        var boundary: UUID?
        var trimmed = 0
        if let plan, plan.trimmedCount > 0, plan.firstSentIndex <= all.count {
            if plan.firstSentIndex < all.count { boundary = all[plan.firstSentIndex].id }
            trimmed = all[..<plan.firstSentIndex].filter { $0.role == .user || $0.role == .assistant }.count
        }
        return Derived(messages: messages, plan: plan, trimBoundaryID: boundary, trimmedVisibleCount: trimmed)
    }

    /// Changes whenever the last message grows, so the view can follow streaming output.
    /// Byte counts, because counting characters walks the whole string.
    private func scrollKey(_ messages: [ChatMessage]) -> String {
        guard let last = messages.last else { return "0" }
        let tools = last.toolCalls.map { $0.status.rawValue + ($0.result == nil ? "" : "r") }.joined(separator: ",")
        return "\(messages.count)-\(last.content.utf8.count)-\(last.thinking?.utf8.count ?? 0)-\(tools)-\(last.isStreaming)"
    }

    private var isNearBottom: Bool { distanceFromBottom < Self.followThreshold }
    /// The pill is offered only once the reader has left the bottom; while following, growth
    /// can momentarily read as distance and must not flash it.
    private func showJump(_ messages: [ChatMessage]) -> Bool {
        !followOutput && distanceFromBottom > Self.pillThreshold && !messages.isEmpty
    }

    var body: some View {
        let d = derived
        let messages = d.messages
        let lastID = messages.last?.id
        return VStack(spacing: 0) {
            if case .unreachable = model.status { OllamaBanner() }
            if let name = model.currentModelName, model.modelSupportsTools(name) == false, model.settings.toolsEnabled {
                InfoBar(text: "\(name) doesn't support tool calling. Roger will answer in text and suggest commands you can run with one click.", systemImage: "info.circle")
            }
            if let plan = d.plan, plan.exceedsWindow { contextBanner(plan, trimmedVisibleCount: d.trimmedVisibleCount) }
            if let name = model.currentModelName, model.modelSupportsVision(name) == false,
               model.selected?.messages.contains(where: { $0.attachments.contains(where: \.isImage) }) == true {
                InfoBar(text: "\(name) can't look at images, so the images in this chat are left out of what it receives." + (model.visionModels.isEmpty ? "" : " Vision models installed: \(model.visionModels.map(\.name).joined(separator: ", "))."),
                        systemImage: "eye.slash", tint: .orange)
            }
            if model.settings.internetEnabled, model.settings.proxyMode == .tor, !model.tor.isRunning {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Web access is routed through Tor, but Tor isn't running. Web searches and page fetches will fail until it is.")
                        .font(.callout)
                    TorStatusView(compact: true)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color.orange.opacity(0.1))
            }
            ScrollViewReader { proxy in
                tracked(ScrollView {
                    // Lazy: a long chat's rows are heavy (a message can hold large code blocks,
                    // images and selectable-text overlays, tens of MB of AppKit backing store
                    // each). Realising every row at once drove memory past 3 GB on a big
                    // conversation, which pushed the whole machine into swap and slowed the model
                    // to a token every several seconds. Only the rows near the viewport are now
                    // built. Scrolling to "bottom" still works because it targets a real view id.
                    LazyVStack(alignment: .leading, spacing: 18) {
                        if messages.isEmpty { welcome }
                        ForEach(messages) { message in
                            if message.id == d.trimBoundaryID { TrimDivider(count: d.trimmedVisibleCount) }
                            MessageRow(message: message, isLast: message.id == lastID && message.role == .assistant)
                                .id(message.id)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                    .frame(maxWidth: 900)
                    .frame(maxWidth: .infinity)
                    .background(legacyContentProbe)
                })
                .coordinateSpace(name: "chatScroll")
                .background(legacyViewportProbe)
                .defaultScrollAnchor(.bottom)
                .overlay(alignment: .bottom) {
                    if showJump(messages) {
                        JumpToLatestButton(live: model.isGenerating) { resumeFollowing(proxy, animated: true) }
                            .padding(.bottom, 12)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .animation(.easeOut(duration: 0.18), value: showJump(messages))
                .onChange(of: scrollKey(messages)) { _, _ in
                    // New output: follow it only while the reader wants to be at the bottom.
                    if followOutput { scrollToBottom(proxy, animated: false) }
                }
                .onChange(of: bottomRequest) { _, _ in
                    // Content shrank under the reader: the view sat past its end.
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
                .onChange(of: messages.last?.role == .user ? messages.count : -1) { _, _ in
                    // A message the user just sent is always brought into view.
                    resumeFollowing(proxy, animated: true)
                }
                .onChange(of: model.isGenerating) { _, generating in
                    if generating { resumeFollowing(proxy, animated: false) }
                }
                .onChange(of: model.selectedID) { _, _ in
                    distanceFromBottom = 0
                    followOutput = true
                    if model.isSearching { scrollToFirstMatch(proxy) } else { settleAtBottom(proxy) }
                }
                .onChange(of: model.trimmedSearchQuery) { _, _ in scrollToFirstMatch(proxy) }
                .onAppear { if model.isSearching { scrollToFirstMatch(proxy) } else { settleAtBottom(proxy) } }
            }
            Divider()
            ComposerView()
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onAppear {
            guard wheelMonitor == nil else { return }
            wheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
                lastWheelEvent = Date()
                return event
            }
        }
        .onDisappear {
            if let wheelMonitor { NSEvent.removeMonitor(wheelMonitor) }
            wheelMonitor = nil
        }
        .task(id: model.currentModelName) {
            // Learn the model's real context limit so the budget meter can cap the Settings value.
            if let name = model.currentModelName { await model.loadStats(for: name) }
        }
    }

    // MARK: - Scroll tracking

    private struct ScrollSnapshot: Equatable {
        var offset: CGFloat
        var distance: CGFloat
        /// How far the visible area extends past the end of the content once the content is
        /// taller than the view: content shrank under the reader (the thinking section
        /// collapsing when a reply ends, for instance) and the view must be pulled back.
        var overshoot: CGFloat
    }

    /// Observes the scroll view's geometry. On macOS 15 this uses the dedicated API; a change
    /// of offset (a scroll, by the reader or by us) decides whether to keep following, while
    /// content growth alone never turns following off.
    @ViewBuilder
    private func tracked<V: View>(_ scrollView: V) -> some View {
        if #available(macOS 15.0, *) {
            scrollView
                .onScrollGeometryChange(for: ScrollSnapshot.self) { geo in
                    let tallerThanView = geo.contentSize.height > geo.visibleRect.height
                    return ScrollSnapshot(offset: geo.contentOffset.y,
                                          distance: max(0, geo.contentSize.height - geo.visibleRect.maxY),
                                          overshoot: tallerThanView ? max(0, geo.visibleRect.maxY - geo.contentSize.height) : 0)
                } action: { old, new in
                    scrollChanged(offsetMoved: old.offset != new.offset, distance: new.distance)
                    // Past the end of the content while nobody is scrolling: content shrank
                    // under the reader. The elastic bounce of a scroll gesture also overshoots
                    // and must be left alone, or the view fights the reader's hand.
                    let readerScrolling = userScrolling || Date().timeIntervalSince(lastWheelEvent) < 0.6
                    if new.overshoot > 1, followOutput, !readerScrolling, Date() > settlingUntil { bottomRequest += 1 }
                }
                .onScrollPhaseChange { _, phase in
                    // Trackpad gestures report phases; legacy mouse wheels do not, so this is
                    // only an extra signal on top of the distance heuristic below.
                    userScrolling = phase == .interacting || phase == .decelerating || phase == .tracking
                }
        } else {
            scrollView
        }
    }

    /// macOS 14: measure the content's frame in the viewport's space. State is written on
    /// the next run-loop turn so it never happens inside AppKit's layout pass.
    @ViewBuilder
    private var legacyContentProbe: some View {
        if #unavailable(macOS 15.0) {
            GeometryReader { g in
                let frame = g.frame(in: .named("chatScroll"))
                Color.clear
                    .onChange(of: frame.maxY, initial: true) { _, v in
                        DispatchQueue.main.async { legacyContentBottom = v; legacyUpdate(offsetMoved: false) }
                    }
                    .onChange(of: frame.minY) { _, _ in
                        DispatchQueue.main.async { legacyUpdate(offsetMoved: true) }
                    }
            }
        }
    }

    @ViewBuilder
    private var legacyViewportProbe: some View {
        if #unavailable(macOS 15.0) {
            GeometryReader { g in
                Color.clear.onChange(of: g.size.height, initial: true) { _, v in
                    DispatchQueue.main.async { legacyViewportHeight = v; legacyUpdate(offsetMoved: false) }
                }
            }
        }
    }

    private func legacyUpdate(offsetMoved: Bool) {
        guard legacyViewportHeight > 0 else { return }
        scrollChanged(offsetMoved: offsetMoved, distance: max(0, legacyContentBottom - legacyViewportHeight))
    }

    private func scrollChanged(offsetMoved: Bool, distance: CGFloat) {
        let previous = distanceFromBottom
        if abs(distance - previous) > 0.5 { distanceFromBottom = distance }
        // Content growth leaves the offset alone and never changes the decision to follow.
        guard offsetMoved, Date() > settlingUntil else { return }
        let byReader = userScrolling || Date().timeIntervalSince(lastWheelEvent) < 0.4
        if distance > previous + (byReader ? 0.5 : Self.leaveThreshold) {
            // Moved away from the bottom: only the reader does that; our scrolls go toward it.
            if byReader || Date() > ownScrollUntil { followOutput = false }
        } else if distance < Self.followThreshold && distance <= previous + 0.5 {
            // Arrived (back) at the bottom.
            followOutput = true
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool) {
        if animated {
            ownScrollUntil = Date().addingTimeInterval(0.6)
            withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo("bottom", anchor: .bottom) }
        } else {
            proxy.scrollTo("bottom", anchor: .bottom)
        }
    }

    private func resumeFollowing(_ proxy: ScrollViewProxy, animated: Bool) {
        followOutput = true
        scrollToBottom(proxy, animated: animated)
    }

    /// Opening a chat shows its latest messages. The lazy stack sizes itself in passes, so
    /// scroll once now and once more after layout has settled.
    private func settleAtBottom(_ proxy: ScrollViewProxy) {
        followOutput = true
        settlingUntil = Date().addingTimeInterval(0.6)
        DispatchQueue.main.async { proxy.scrollTo("bottom", anchor: .bottom) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            if distanceFromBottom > Self.followThreshold { proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }

    private func scrollToFirstMatch(_ proxy: ScrollViewProxy) {
        guard model.isSearching, let convo = model.selected,
              let first = model.searchMatches(in: convo).first else { return }
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(first.id, anchor: .center) }
        }
    }

    private func contextBanner(_ plan: ContextPlan, trimmedVisibleCount: Int) -> some View {
        let name = model.currentModelName ?? "the model"
        let window = TokenEstimator.format(plan.window)
        let text: String
        if !plan.autoTrim {
            text = "This chat (≈\(TokenEstimator.format(plan.totalTokens)) tokens) exceeds \(name)'s \(window)-token context window. The model may lose track of earlier messages or fail. Turn on automatic trimming or raise the context length in Settings."
        } else if plan.stillTooLong {
            text = "Even the latest message (≈\(TokenEstimator.format(plan.sentTokens)) tokens) does not fit \(name)'s \(window)-token context window. Shorten it, remove attachments, or raise the context length in Settings."
        } else {
            let n = trimmedVisibleCount
            text = "This chat exceeds \(name)'s \(window)-token context window. The oldest \(n) message\(n == 1 ? " is" : "s are") no longer sent to the model."
        }
        return InfoBar(text: text, systemImage: "gauge.with.dots.needle.100percent", tint: plan.stillTooLong || !plan.autoTrim ? .red : .orange)
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                RogerAvatar(size: 40)
                VStack(alignment: .leading) {
                    Text("Hi, I'm Roger.").font(.title2.bold())
                    Text(model.settings.internetEnabled
                         ? "A local assistant powered by Ollama. Web access is on, \(model.settings.webConfig.routeDescription)."
                         : "A local assistant powered by Ollama. Nothing leaves your Mac unless you turn on web access in Settings.")
                        .foregroundStyle(.secondary)
                }
            }
            Text("Try asking:").font(.headline).padding(.top, 8)
            ForEach(suggestions, id: \.self) { s in
                Button { model.send(text: s, attachments: []) } label: {
                    HStack {
                        Image(systemName: "arrow.turn.down.right").foregroundStyle(.secondary)
                        Text(s)
                    }
                }
                .buttonStyle(.plain)
            }
            Text("Attach files with the paperclip or by dropping them on the message box. Add working folders below the message box so Roger can read, edit and run things in your project.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.top, 8)
        }
        .padding(.top, 40)
        .padding(.bottom, 20)
    }

    private var suggestions: [String] {
        ["List the files in my working directory and explain what this project does.",
         "Write a Swift function that parses ISO 8601 dates, with tests.",
         "Explain the difference between a Swift actor and a class."]
    }
}

/// Floating pill shown when the reader has scrolled up; a pulsing dot while a reply streams.
struct JumpToLatestButton: View {
    var live: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if live {
                    // A static dot: continuously animating children (spinner, pulse) kept the
                    // pill out of the accessibility tree while a reply streamed.
                    Circle().fill(Color.accentColor).frame(width: 7, height: 7)
                }
                Image(systemName: "arrow.down")
                Text(live ? "Jump to latest" : "Jump to end")
            }
            .font(.callout.weight(.medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12)))
            .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
        }
        .buttonStyle(.plain)
        .help(live ? "Follow the reply as it streams" : "Scroll to the end of the chat")
    }
}

/// Marks the point above which messages are no longer part of what the model sees.
struct TrimDivider: View {
    var count: Int
    var body: some View {
        HStack(spacing: 8) {
            line
            Label("\(count) older message\(count == 1 ? "" : "s") above no longer fit the context window and aren't sent to the model",
                  systemImage: "scissors")
                .font(.caption).foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
            line
        }
        .padding(.vertical, 4)
    }
    private var line: some View {
        Rectangle().fill(Color.secondary.opacity(0.3)).frame(height: 1).frame(maxWidth: .infinity)
    }
}

struct InfoBar: View {
    var text: String
    var systemImage: String
    var tint: Color = .accentColor
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage).foregroundStyle(tint == .accentColor ? Color.primary : tint)
            Text(text).font(.callout)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(tint.opacity(0.1))
    }
}

struct OllamaBanner: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Ollama is not running").bold()
                Text("Roger needs Ollama at \(model.settings.host). Start it, or change the host in Settings.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if model.isStartingOllama {
                ProgressView().controlSize(.small)
            } else {
                Button("Start Ollama") { model.startOllama() }
                Button("Retry") { Task { await model.refreshStatus() } }
            }
        }
        .padding(12)
        .background(Color.orange.opacity(0.12))
    }
}

struct RogerAvatar: View {
    var size: CGFloat = 28
    var body: some View {
        Text("R")
            .font(.system(size: size * 0.55, weight: .heavy, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                LinearGradient(colors: [Color(red: 0.98, green: 0.55, blue: 0.25), Color(red: 0.80, green: 0.22, blue: 0.40)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            )
            .clipShape(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
    }
}
