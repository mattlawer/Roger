import Foundation
import Observation

/// How a model's reasoning ("thinking") is handled.
enum ReasoningMode: String, CaseIterable, Codable {
    /// Stream it into a collapsible section (default).
    case show
    /// Receive it but never show it.
    case hidden
    /// Ask thinking-capable models not to reason at all (faster, sometimes less accurate).
    case off
}

@Observable
final class AppSettings {
    private let defaults = UserDefaults.standard

    var host: String { didSet { defaults.set(host, forKey: "host") } }
    var defaultModel: String { didSet { defaults.set(defaultModel, forKey: "defaultModel") } }
    var temperature: Double { didSet { defaults.set(temperature, forKey: "temperature") } }
    var contextLength: Int { didSet { defaults.set(contextLength, forKey: "contextLength") } }
    var toolsEnabled: Bool { didSet { defaults.set(toolsEnabled, forKey: "toolsEnabled") } }
    var autoApproveFileEdits: Bool { didSet { defaults.set(autoApproveFileEdits, forKey: "autoApproveFileEdits") } }
    var autoApproveCommands: Bool { didSet { defaults.set(autoApproveCommands, forKey: "autoApproveCommands") } }
    var maxToolIterations: Int { didSet { defaults.set(maxToolIterations, forKey: "maxToolIterations") } }
    var customInstructions: String { didSet { defaults.set(customInstructions, forKey: "customInstructions") } }
    var useLoginShell: Bool { didSet { defaults.set(useLoginShell, forKey: "useLoginShell") } }
    var autoTrimContext: Bool { didSet { defaults.set(autoTrimContext, forKey: "autoTrimContext") } }
    var reasoningMode: ReasoningMode { didSet { defaults.set(reasoningMode.rawValue, forKey: "reasoningMode") } }
    var showReasoning: Bool { reasoningMode == .show }
    var internetEnabled: Bool { didSet { defaults.set(internetEnabled, forKey: "internetEnabled") } }
    var askBeforeInternet: Bool { didSet { defaults.set(askBeforeInternet, forKey: "askBeforeInternet") } }
    var searchEngine: SearchEngine { didSet { defaults.set(searchEngine.rawValue, forKey: "searchEngine") } }
    var searxngURL: String { didSet { defaults.set(searxngURL, forKey: "searxngURL") } }
    var proxyMode: ProxyMode { didSet { defaults.set(proxyMode.rawValue, forKey: "proxyMode") } }
    var proxyHost: String { didSet { defaults.set(proxyHost, forKey: "proxyHost") } }
    var proxyPort: Int { didSet { defaults.set(proxyPort, forKey: "proxyPort") } }
    var torPort: Int { didSet { defaults.set(torPort, forKey: "torPort") } }
    var torControlPort: Int { didSet { defaults.set(torControlPort, forKey: "torControlPort") } }
    var torControlPassword: String { didSet { defaults.set(torControlPassword, forKey: "torControlPassword") } }

    /// How the model's web requests are made. Ollama itself is never proxied.
    var webConfig: WebConfig {
        WebConfig(proxyMode: proxyMode, proxyHost: proxyHost, proxyPort: proxyPort, torPort: torPort,
                  searchEngine: searchEngine, searxngURL: searxngURL)
    }

    init() {
        host = defaults.string(forKey: "host") ?? "http://localhost:11434"
        defaultModel = defaults.string(forKey: "defaultModel") ?? ""
        temperature = defaults.object(forKey: "temperature") as? Double ?? 0.3
        contextLength = defaults.object(forKey: "contextLength") as? Int ?? 16384
        toolsEnabled = defaults.object(forKey: "toolsEnabled") as? Bool ?? true
        autoApproveFileEdits = defaults.bool(forKey: "autoApproveFileEdits")
        autoApproveCommands = defaults.bool(forKey: "autoApproveCommands")
        maxToolIterations = defaults.object(forKey: "maxToolIterations") as? Int ?? 15
        customInstructions = defaults.string(forKey: "customInstructions") ?? ""
        useLoginShell = defaults.object(forKey: "useLoginShell") as? Bool ?? false
        autoTrimContext = defaults.object(forKey: "autoTrimContext") as? Bool ?? true
        reasoningMode = ReasoningMode(rawValue: defaults.string(forKey: "reasoningMode") ?? "") ?? .show
        internetEnabled = defaults.bool(forKey: "internetEnabled")
        askBeforeInternet = defaults.bool(forKey: "askBeforeInternet")
        searchEngine = SearchEngine(rawValue: defaults.string(forKey: "searchEngine") ?? "") ?? .duckduckgo
        searxngURL = defaults.string(forKey: "searxngURL") ?? ""
        proxyMode = ProxyMode(rawValue: defaults.string(forKey: "proxyMode") ?? "") ?? .direct
        proxyHost = defaults.string(forKey: "proxyHost") ?? ""
        proxyPort = defaults.object(forKey: "proxyPort") as? Int ?? 0
        torPort = defaults.object(forKey: "torPort") as? Int ?? 9050
        torControlPort = defaults.object(forKey: "torControlPort") as? Int ?? 9051
        torControlPassword = defaults.string(forKey: "torControlPassword") ?? ""
    }

    var hostURL: URL {
        var h = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if h.isEmpty { h = "http://localhost:11434" }
        if !h.contains("://") { h = "http://" + h }
        if !h.hasSuffix("/") { h += "/" }
        return URL(string: h) ?? URL(string: "http://localhost:11434/")!
    }
}
