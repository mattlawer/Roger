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
        .sheet(isPresented: $model.showModelsSheet) {
            ModelsView().environment(model)
        }
        .alert("Something went wrong", isPresented: Binding(get: { model.errorBanner != nil }, set: { if !$0 { model.errorBanner = nil } })) {
            Button("OK") { model.errorBanner = nil }
        } message: {
            Text(model.errorBanner ?? "")
        }
    }
}
