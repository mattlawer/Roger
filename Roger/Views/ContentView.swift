import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
        } detail: {
            if model.selected != nil {
                ChatView()
            } else {
                ContentUnavailableView("No chat selected", systemImage: "bubble.left.and.bubble.right", description: Text("Create a new chat with ⌘N."))
            }
        }
        .navigationTitle(model.selected?.title ?? "Roger")
        .toolbar { toolbarContent }
        .sheet(isPresented: $model.showModelsSheet) {
            ModelsView().environment(model)
        }
        .alert("Something went wrong", isPresented: Binding(get: { model.errorBanner != nil }, set: { if !$0 { model.errorBanner = nil } })) {
            Button("OK") { model.errorBanner = nil }
        } message: {
            Text(model.errorBanner ?? "")
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button { model.newConversation() } label: { Label("New Chat", systemImage: "square.and.pencil") }
                .help("New chat (⌘N)")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            workingDirectoryButton
            modelPicker
            Button { model.showModelsSheet = true } label: { Label("Models", systemImage: "shippingbox") }
                .help("Manage installed models (⇧⌘M)")
        }
    }

    private var workingDirectoryButton: some View {
        Button { model.chooseWorkingDirectory() } label: {
            Label(URL(fileURLWithPath: model.selected?.workingDirectory ?? NSHomeDirectory()).lastPathComponent, systemImage: "folder")
                .labelStyle(.titleAndIcon)
        }
        .help("Working directory: \(model.selected?.workingDirectory ?? "")\nClick to change (⇧⌘O)")
    }

    private var modelPicker: some View {
        let current = model.currentModelName ?? ""
        var names = model.models.map(\.name)
        if !current.isEmpty, !names.contains(current) { names.append(current) }
        return Picker("Model", selection: Binding(get: { current }, set: { model.setModel($0) })) {
            if names.isEmpty {
                Text("No models").tag("")
            }
            ForEach(names, id: \.self) { name in
                Text(name).tag(name)
            }
        }
        .pickerStyle(.menu)
        .frame(minWidth: 140)
        .help("Model used for this chat")
        .disabled(names.isEmpty)
    }
}
