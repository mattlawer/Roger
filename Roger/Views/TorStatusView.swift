import SwiftUI

/// Tor's state with the actions that make sense for it: start it, stop it, or copy the
/// command to run or install it. Used in Settings and in the chat banner.
struct TorStatusView: View {
    @Environment(AppModel.self) private var model
    var compact = false
    @State private var copied: String?

    var body: some View {
        let tor = model.tor
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(tor.statusText).font(compact ? .callout : .body)
                if let err = tor.lastError {
                    Text(err).font(.caption).foregroundStyle(.red)
                }
                if !compact, let result = tor.lastActionResult {
                    Text(result).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if !compact, case .running = tor.status, tor.startedByRoger {
                    Text("Started by Roger; it keeps running until you stop it or log out.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if tor.isStarting {
                ProgressView().controlSize(.small)
                Text("Starting…").font(.caption).foregroundStyle(.secondary)
            } else {
                switch tor.status {
                case .stopped:
                    Button("Start Tor") { Task { await tor.start(port: model.settings.torPort, controlPort: model.settings.torControlPort) } }
                        .buttonStyle(.borderedProminent)
                    copyButton("Copy command", tor.startCommand)
                case .notInstalled:
                    copyButton("Copy install command", tor.installCommand)
                        .help("Copies “\(tor.installCommand)” for a terminal (needs Homebrew)")
                case .running:
                    if tor.isSignalling {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("New circuit") { model.newTorCircuit() }
                            .help(tor.controlPort != nil ? "SIGNAL NEWNYM over the control port" : "No control port answers; sends SIGHUP to tor instead")
                        Button("SIGHUP") { model.reloadTor() }
                            .help("Reload tor's configuration and retire the circuits in use")
                    }
                    if tor.startedByRoger {
                        Button("Stop Tor") { Task { await tor.stop(port: model.settings.torPort) } }
                    }
                case .unknown:
                    EmptyView()
                }
                Button { Task { await tor.refresh(preferredPort: model.settings.torPort, controlPort: model.settings.torControlPort) } } label: { Image(systemName: "arrow.clockwise") }
                    .help("Check again")
            }
        }
        .controlSize(compact ? .small : .regular)
        .buttonStyle(.bordered)
        .task { await tor.refresh(preferredPort: model.settings.torPort, controlPort: model.settings.torControlPort) }
    }

    private func copyButton(_ label: String, _ command: String) -> some View {
        Button(copied == command ? "Copied" : label) {
            model.tor.copyToClipboard(command)
            copied = command
            Task { try? await Task.sleep(for: .seconds(1.5)); copied = nil }
        }
        .help("Copies “\(command)” to the clipboard")
    }

    private var icon: String {
        switch model.tor.status {
        case .running: return "checkmark.shield.fill"
        case .stopped: return "shield.slash"
        case .notInstalled: return "shield.slash"
        case .unknown: return "shield"
        }
    }

    private var color: Color {
        switch model.tor.status {
        case .running: return .green
        case .stopped, .notInstalled: return .orange
        case .unknown: return .secondary
        }
    }
}
