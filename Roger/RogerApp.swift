import SwiftUI

@main
struct RogerApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                .frame(minWidth: 900, minHeight: 600)
                .task { await model.bootstrap() }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Chat") { model.newConversation() }
                    .keyboardShortcut("n", modifiers: .command)
                Button("New Group…") { model.newGroupRequest = NewGroupRequest() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
            }
            CommandGroup(after: .textEditing) {
                Button("Find in Chats") { model.searchFocusRequest += 1 }
                    .keyboardShortcut("f", modifiers: .command)
            }
            CommandMenu("Roger") {
                Button("Manage Models…") { model.showModelsSheet = true }
                    .keyboardShortcut("m", modifiers: [.command, .shift])
                Button("Choose Working Directory…") { model.chooseWorkingDirectory() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                Divider()
                Button("Clear Chat") { model.clearMessages() }
                    .keyboardShortcut("k", modifiers: [.command, .shift])
                Button("Stop Generating") { model.stopGeneration() }
                    .keyboardShortcut(".", modifiers: .command)
                    .disabled(!model.isGenerating)
                Divider()
                Button("Reconnect to Ollama") { Task { await model.refreshStatus() } }
            }
        }

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}
