import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section("Ollama") {
                TextField("Host", text: $settings.host, prompt: Text("http://localhost:11434"))
                    .onSubmit { Task { await model.refreshStatus() } }
                HStack {
                    Text(statusText).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Reconnect") { Task { await model.refreshStatus() } }
                }
                Picker("Default model", selection: $settings.defaultModel) {
                    if !model.models.contains(where: { $0.name == settings.defaultModel }) {
                        Text(settings.defaultModel.isEmpty ? "None" : settings.defaultModel).tag(settings.defaultModel)
                    }
                    ForEach(model.models) { Text($0.name).tag($0.name) }
                }
            }

            Section("Generation") {
                HStack {
                    Text("Temperature")
                    Slider(value: $settings.temperature, in: 0...1.5, step: 0.05)
                    Text(String(format: "%.2f", settings.temperature)).monospacedDigit().frame(width: 40)
                }
                Picker("Context length", selection: $settings.contextLength) {
                    ForEach([4096, 8192, 16384, 32768, 65536, 131072], id: \.self) { n in
                        Text("\(n / 1024)k tokens").tag(n)
                    }
                }
                Text("Larger contexts let Roger read more code at once but use more memory. The model must support the chosen size.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Reasoning", selection: $settings.reasoningMode) {
                    Text("Show in a collapsible section").tag(ReasoningMode.show)
                    Text("Hide").tag(ReasoningMode.hidden)
                    Text("Off (ask models not to reason)").tag(ReasoningMode.off)
                }
                Text("Applies to thinking models such as qwen3 or deepseek-r1. “Hide” still lets the model reason but keeps it out of the chat; “Off” sends Ollama's think=false, which is faster but can lower answer quality. When a model answers only inside its reasoning, Roger shows that reasoning as the reply and labels it.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Trim the oldest messages when a chat outgrows the context window", isOn: $settings.autoTrimContext)
                Text("Roger estimates the size of each chat and, when it no longer fits, stops sending the oldest turns to the model. The messages stay in the chat; a divider shows where the model's view starts. With this off, the whole chat is sent and the model may lose track of the beginning.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Tools") {
                Toggle("Let Roger use tools (read, edit, search files, run commands)", isOn: $settings.toolsEnabled)
                Toggle("Auto-approve file writes and edits", isOn: $settings.autoApproveFileEdits)
                    .disabled(!settings.toolsEnabled)
                Toggle("Auto-approve shell commands", isOn: $settings.autoApproveCommands)
                    .disabled(!settings.toolsEnabled)
                Stepper("Max tool steps per message: \(settings.maxToolIterations)", value: $settings.maxToolIterations, in: 1...50)
                    .disabled(!settings.toolsEnabled)
                Toggle("Run commands in a login shell (sources ~/.zprofile)", isOn: $settings.useLoginShell)
                Text("Off by default so shell startup banners and prompts don't pollute command output. Turn on only if your tools rely on PATH or variables set in ~/.zprofile or ~/.zlogin.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Auto-approval lets the model change files or run commands without asking. Only enable it for folders you trust it with.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Internet") {
                Toggle("Let Roger search the web and read pages", isOn: $settings.internetEnabled)
                Text("Adds web_search and fetch_url tools for tool-capable models. Off by default: with it off, nothing leaves your Mac. Only the model's web requests use the connection below; Ollama is never proxied.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Search engine", selection: $settings.searchEngine) {
                    ForEach(SearchEngine.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .disabled(!settings.internetEnabled)
                if settings.searchEngine == .searxng {
                    TextField("SearXNG URL", text: $settings.searxngURL, prompt: Text("https://searx.example.org"))
                        .disabled(!settings.internetEnabled)
                    Text("The instance must allow JSON results (search.formats includes json in its settings.yml).")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Ask before each web request", isOn: $settings.askBeforeInternet)
                    .disabled(!settings.internetEnabled)
                Picker("Connection", selection: $settings.proxyMode) {
                    ForEach(ProxyMode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .disabled(!settings.internetEnabled)
                .onChange(of: settings.proxyMode) { _, _ in
                    model.connectionResult = nil
                    model.lastExitIP = nil
                    Task { await model.refreshWebStatus() }
                }
                if settings.proxyMode == .http || settings.proxyMode == .socks {
                    HStack {
                        TextField("Host", text: $settings.proxyHost, prompt: Text("127.0.0.1"))
                        TextField("Port", value: $settings.proxyPort, format: .number.grouping(.never), prompt: Text("8080"))
                            .frame(width: 80)
                    }
                    .disabled(!settings.internetEnabled)
                }
                if settings.proxyMode == .tor {
                    TorStatusView()
                    HStack {
                        TextField("SOCKS port", value: $settings.torPort, format: .number.grouping(.never))
                            .frame(width: 100)
                        TextField("Control port", value: $settings.torControlPort, format: .number.grouping(.never))
                            .frame(width: 110)
                        Text("9050 / 9051 for a tor service, 9150 / 9151 for Tor Browser.").font(.caption).foregroundStyle(.secondary)
                    }
                    SecureField("Control password (only for HashedControlPassword setups)", text: $settings.torControlPassword)
                    Text("Requests use Tor's SOCKS5 proxy; hostnames are resolved by Tor, so .onion sites work. “New circuit” sends NEWNYM over the control port when one answers (a Tor started by Roger opens one with cookie authentication), otherwise SIGHUP, which reloads tor and retires the circuits in use. brew services start tor keeps Tor running across logins.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button(model.isCheckingConnection ? "Testing…" : "Test connection") { model.testConnection() }
                        .disabled(model.isCheckingConnection || !settings.internetEnabled)
                    if let result = model.connectionResult {
                        Text(result).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
            }

            Section("Remembered approvals") {
                if model.approvals.rules.isEmpty {
                    Text("None yet. When Roger asks to run a command or edit a file, choose “Always allow…” to remember that kind of action for the chat's working directory.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(model.approvals.rules.sorted { $0.createdAt > $1.createdAt }) { rule in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(rule.scope.title)
                                Text(rule.shortDirectory).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Forget") { model.approvals.remove(rule.id) }
                        }
                    }
                    Button("Forget all") { model.approvals.removeAll() }
                }
                if model.allowAllThisSession {
                    HStack {
                        Text("“Allow all this session” is active until Roger quits.").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Ask again") { model.allowAllThisSession = false }
                    }
                }
                Text("Read-only commands are recognised conservatively (listing, reading, searching, git status/log/diff and the like); anything with redirections, pipes to unknown tools or substitutions still asks.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Custom instructions") {
                TextEditor(text: $settings.customInstructions)
                    .font(.body)
                    .frame(minHeight: 80)
                Text("Added to every system prompt, e.g. “Answer in French” or “Prefer Swift 6 concurrency”.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 720)
    }

    private var statusText: String {
        switch model.status {
        case .connected(let v): return "Connected to Ollama \(v)"
        case .unreachable(let e): return "Unreachable: \(e)"
        case .unknown: return "Not connected yet"
        }
    }
}
