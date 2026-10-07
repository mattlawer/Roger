import SwiftUI
import UniformTypeIdentifiers

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @State private var renaming: Conversation?
    @State private var renameText = ""
    @State private var renamingGroup: ChatGroup?
    @State private var groupNameText = ""
    @State private var newGroupName = ""
    @State private var dropTargetGroup: UUID??
    @FocusState private var searchFocused: Bool

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selectedID) {
            if model.isSearching {
                searchResults
            } else {
                ForEach(model.sortedGroups) { group in
                    Section {
                        let chats = model.conversations(in: group.id)
                        if chats.isEmpty {
                            Text("No chats yet").font(.caption).foregroundStyle(.tertiary)
                        }
                        ForEach(chats) { convo in chatRow(convo) }
                    } header: {
                        groupHeader(group)
                    }
                }
                Section {
                    ForEach(model.conversations(in: nil)) { convo in chatRow(convo) }
                } header: {
                    ungroupedHeader
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top, spacing: 0) { searchField }
        .safeAreaInset(edge: .bottom) { statusFooter }
        .onChange(of: model.searchFocusRequest) { _, _ in searchFocused = true }
        .alert("Rename chat", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Title", text: $renameText)
            Button("Rename") { if let r = renaming { model.renameConversation(r.id, title: renameText) }; renaming = nil }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .alert("Rename group", isPresented: Binding(get: { renamingGroup != nil }, set: { if !$0 { renamingGroup = nil } })) {
            TextField("Name", text: $groupNameText)
            Button("Rename") { if let g = renamingGroup { model.renameGroup(g.id, name: groupNameText) }; renamingGroup = nil }
            Button("Cancel", role: .cancel) { renamingGroup = nil }
        }
        .alert("New group", isPresented: Binding(get: { model.newGroupRequest != nil }, set: { if !$0 { model.newGroupRequest = nil } })) {
            TextField("Name", text: $newGroupName, prompt: Text("e.g. Work, Side projects"))
            Button("Create") {
                if let g = model.createGroup(named: newGroupName), let convoID = model.newGroupRequest?.conversationID {
                    model.moveConversation(convoID, toGroup: g.id)
                }
                newGroupName = ""
                model.newGroupRequest = nil
            }
            Button("Cancel", role: .cancel) { newGroupName = ""; model.newGroupRequest = nil }
        } message: {
            Text(model.newGroupRequest?.conversationID == nil ? "Groups keep related chats together in the sidebar." : "The chat will be moved into the new group.")
        }
    }

    // MARK: - Rows

    private func chatRow(_ convo: Conversation) -> some View {
        row(convo)
            .tag(convo.id)
            .draggable(convo.id.uuidString)
            .contextMenu { chatMenu(convo) }
    }

    @ViewBuilder
    private func chatMenu(_ convo: Conversation) -> some View {
        Button("Rename…") { renaming = convo; renameText = convo.title }
        Button(model.generatingTitleIDs.contains(convo.id) ? "Generating name…" : "Generate Name") {
            model.generateTitle(for: convo.id, force: true)
        }
        .disabled(model.generatingTitleIDs.contains(convo.id) || !convo.messages.contains { $0.role == .assistant && !$0.content.isEmpty })
        Menu("Move to") {
            Button("No group") { model.moveConversation(convo.id, toGroup: nil) }
                .disabled(convo.groupID == nil)
            if !model.groups.isEmpty { Divider() }
            ForEach(model.sortedGroups) { g in
                Button(g.name) { model.moveConversation(convo.id, toGroup: g.id) }
                    .disabled(convo.groupID == g.id)
            }
            Divider()
            Button("New Group…") { model.newGroupRequest = NewGroupRequest(conversationID: convo.id) }
        }
        Divider()
        Button("Delete", role: .destructive) { model.deleteConversation(convo.id) }
    }

    private func groupHeader(_ group: ChatGroup) -> some View {
        HStack(spacing: 4) {
            Text(group.name)
            if dropTargetGroup == .some(.some(group.id)) {
                Image(systemName: "arrow.down.to.line").font(.caption2).foregroundStyle(Color.accentColor)
            }
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button("New Chat in \(group.name)") { model.newConversation(in: .some(group.id)) }
            Button("Rename Group…") { renamingGroup = group; groupNameText = group.name }
            Divider()
            Button("Remove Group", role: .destructive) { model.deleteGroup(group.id) }
        }
        .dropDestination(for: String.self) { items, _ in
            move(items, to: group.id)
        } isTargeted: { dropTargetGroup = $0 ? .some(.some(group.id)) : nil }
    }

    private var ungroupedHeader: some View {
        HStack(spacing: 4) {
            Text(model.groups.isEmpty ? "Chats" : "Other chats")
            if dropTargetGroup == .some(.none) {
                Image(systemName: "arrow.down.to.line").font(.caption2).foregroundStyle(Color.accentColor)
            }
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button("New Group…") { model.newGroupRequest = NewGroupRequest() }
        }
        .dropDestination(for: String.self) { items, _ in
            move(items, to: nil)
        } isTargeted: { dropTargetGroup = $0 ? .some(.none) : nil }
    }

    private func move(_ items: [String], to groupID: UUID?) -> Bool {
        let ids = items.compactMap(UUID.init(uuidString:))
        guard !ids.isEmpty else { return false }
        for id in ids { model.moveConversation(id, toGroup: groupID) }
        return true
    }

    @ViewBuilder
    private var searchResults: some View {
        Section("Results") {
            let shown = model.filteredConversations
            if shown.isEmpty {
                Text("No chats match “\(model.trimmedSearchQuery)”")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(shown) { convo in chatRow(convo) }
        }
    }

    private func row(_ convo: Conversation) -> some View {
        let matches = model.isSearching ? model.searchMatches(in: convo) : []
        return Label {
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(highlighted(convo.title)).lineLimit(1)
                    if model.isSearching {
                        if let first = matches.first {
                            Text(snippet(of: first))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        if matches.count > 1 {
                            Text("\(matches.count) matching messages").font(.caption2).foregroundStyle(.tertiary)
                        } else if matches.isEmpty {
                            Text("Title matches").font(.caption2).foregroundStyle(.tertiary)
                        }
                        if let g = model.group(convo.groupID) {
                            Label(g.name, systemImage: "folder").font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                }
                if model.generatingTitleIDs.contains(convo.id) {
                    Spacer(minLength: 0)
                    ProgressView().controlSize(.mini).help("Naming this chat…")
                }
            }
        } icon: {
            Image(systemName: convo.id == model.selectedID && model.isGenerating ? "ellipsis.bubble" : "bubble.left")
        }
    }

    // MARK: - Search

    private var searchField: some View {
        @Bindable var model = model
        return HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search chats", text: $model.searchQuery)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .onExitCommand {
                    model.searchQuery = ""
                    searchFocused = false
                }
            if !model.searchQuery.isEmpty {
                Button { model.searchQuery = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Clear search")
            }
        }
        .font(.callout)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
            .strokeBorder(searchFocused ? Color.accentColor : Color.clear, lineWidth: 1.5))
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .help("Search chat titles and messages (⌘F)")
    }

    /// The text around the first occurrence of the query, with the matches emphasised.
    private func snippet(of message: ChatMessage) -> AttributedString {
        let q = model.trimmedSearchQuery
        let flat = message.content.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        guard let r = flat.range(of: q, options: .caseInsensitive) else { return highlighted(String(flat.prefix(120))) }
        let start = flat.index(r.lowerBound, offsetBy: -40, limitedBy: flat.startIndex) ?? flat.startIndex
        let end = flat.index(r.upperBound, offsetBy: 80, limitedBy: flat.endIndex) ?? flat.endIndex
        var text = String(flat[start..<end])
        if start > flat.startIndex { text = "…" + text }
        if end < flat.endIndex { text += "…" }
        return highlighted(text)
    }

    private func highlighted(_ text: String) -> AttributedString {
        var attr = AttributedString(text)
        let q = model.trimmedSearchQuery
        guard !q.isEmpty else { return attr }
        var from = attr.startIndex
        while from < attr.endIndex, let r = attr[from...].range(of: q, options: .caseInsensitive) {
            attr[r].inlinePresentationIntent = .stronglyEmphasized
            attr[r].foregroundColor = .primary
            from = r.upperBound
        }
        return attr
    }

    // MARK: - Footer

    private var statusFooter: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 1) {
                    Text(statusTitle).font(.caption).bold()
                    Text(statusDetail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button { model.newGroupRequest = NewGroupRequest() } label: { Image(systemName: "folder.badge.plus") }
                    .buttonStyle(.borderless)
                    .help("New group (⇧⌘N)")
                Button { Task { await model.refreshStatus() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("Reconnect")
            }
            webStatusRow
        }
        .padding(10)
        .background(.bar)
    }

    // MARK: - Web / Tor status

    private var webStatusKey: String {
        let s = model.settings
        return "\(s.internetEnabled)|\(s.proxyMode.rawValue)|\(s.proxyHost)|\(s.proxyPort)|\(s.torPort)|\(s.torControlPort)"
    }

    private var webStatusRow: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(webColor)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(webTitle).font(.caption).bold()
                Text(webDetail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if model.isCheckingConnection || model.tor.isStarting || model.tor.isSignalling {
                ProgressView().controlSize(.mini)
            }
            Menu {
                webActions
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Web connection actions")
        }
        .help(webTooltip)
        .task(id: webStatusKey) {
            // Re-probe when the settings change, then every 30 s while the sidebar is visible.
            while !Task.isCancelled {
                await model.refreshWebStatus()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    @ViewBuilder
    private var webActions: some View {
        let s = model.settings
        if s.internetEnabled {
            Button("Test connection") { model.testConnection() }
                .disabled(model.isCheckingConnection)
            if s.proxyMode == .tor {
                Divider()
                switch model.tor.status {
                case .running:
                    Button("New circuit") { model.newTorCircuit() }
                        .disabled(model.tor.isSignalling)
                    Button("Send SIGHUP (reload & rotate circuits)") { model.reloadTor() }
                        .disabled(model.tor.isSignalling)
                    if model.tor.startedByRoger {
                        Button("Stop Tor") { Task { await model.tor.stop(port: s.torPort) } }
                    }
                case .stopped:
                    Button("Start Tor") { Task { await model.tor.start(port: s.torPort, controlPort: s.torControlPort) } }
                        .disabled(model.tor.isStarting)
                    Button("Copy run command") { model.tor.copyToClipboard(model.tor.startCommand) }
                case .notInstalled:
                    Button("Copy install command") { model.tor.copyToClipboard(model.tor.installCommand) }
                case .unknown:
                    EmptyView()
                }
            }
            Divider()
            Button("Check again") { Task { await model.refreshWebStatus() } }
        }
        SettingsLink { Text("Internet Settings…") }
    }

    private var webColor: Color {
        let s = model.settings
        guard s.internetEnabled else { return .gray }
        switch s.proxyMode {
        case .direct: return .green
        case .http, .socks:
            switch model.proxyReachable {
            case .some(true): return .green
            case .some(false): return .red
            case .none: return .orange
            }
        case .tor:
            switch model.tor.status {
            case .running: return .green
            case .stopped, .notInstalled: return .red
            case .unknown: return .gray
            }
        }
    }

    private var webTitle: String {
        let s = model.settings
        guard s.internetEnabled else { return "Web access off" }
        switch s.proxyMode {
        case .direct: return "Web: direct"
        case .http: return "Web: HTTP proxy"
        case .socks: return "Web: SOCKS5 proxy"
        case .tor:
            if let p = model.tor.activePort { return p == 9150 ? "Web: Tor Browser" : "Web: Tor" }
            return "Web: Tor"
        }
    }

    private var webDetail: String {
        let s = model.settings
        guard s.internetEnabled else { return "Nothing leaves this Mac" }
        if model.isCheckingConnection { return "Testing connection…" }
        switch s.proxyMode {
        case .direct:
            return model.lastExitIP.map { "Public IP \($0)" } ?? "No proxy"
        case .http, .socks:
            guard let ep = s.webConfig.proxyEndpoint else { return "No proxy host set" }
            let reach = model.proxyReachable == false ? " · not answering" : ""
            return "\(ep.host):\(ep.port)\(reach)"
        case .tor:
            switch model.tor.status {
            case .running(let port):
                var parts = ["port \(port)"]
                if model.tor.controlPort != nil { parts.append("control") }
                if let ip = model.lastExitIP { parts.append("exit \(ip)") }
                return parts.joined(separator: " · ")
            case .stopped: return "Not running"
            case .notInstalled: return "Not installed"
            case .unknown: return "Checking…"
            }
        }
    }

    private var webTooltip: String {
        var lines = ["Route for the model's web requests: \(model.settings.webConfig.routeDescription)."]
        if let r = model.connectionResult { lines.append(r) }
        if let a = model.tor.lastActionResult { lines.append(a) }
        return lines.joined(separator: "\n")
    }

    private var statusColor: Color {
        switch model.status {
        case .connected: return .green
        case .unreachable: return .red
        case .unknown: return .gray
        }
    }

    private var statusTitle: String {
        switch model.status {
        case .connected(let v): return "Ollama \(v)"
        case .unreachable: return "Ollama offline"
        case .unknown: return "Connecting…"
        }
    }

    private var statusDetail: String {
        switch model.status {
        case .connected: return "\(model.models.count) model\(model.models.count == 1 ? "" : "s") installed"
        case .unreachable: return model.settings.host
        case .unknown: return ""
        }
    }
}
