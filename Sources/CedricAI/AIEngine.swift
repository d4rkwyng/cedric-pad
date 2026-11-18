import Foundation
import CedricCore

/// Where the owl's AI runs. The settings sheet talks only to this protocol
/// (availability, model list, test, provider), so a new engine, such as the
/// built-in one with its own model downloader, plugs in without UI changes.
/// Every engine uses the same prompts (`OwlPrompts`).
public protocol AIEngine: Sendable {
    var kind: LocalAISettings.Backend { get }
    var title: String { get }
    /// False: shown, but disabled in the picker.
    var isAvailable: Bool { get }
    /// Why it's disabled ("Coming soon", "Needs Apple Intelligence…").
    var unavailableReason: String? { get }
    /// The engine needs an address (a server on this Mac or the LAN).
    var needsAddress: Bool { get }
    /// A caveat shown under the picker when available ("Slow on Intel Macs…").
    var note: String? { get }
    /// The models this engine can run.
    func models() async throws -> [LocalModelInfo]
    /// "Test Connection": the models, latency and the suggested model.
    func test() async -> ConnectionReport
    /// The automatic choice from `models` (never a big one), or nil.
    func suggestedModel(in models: [LocalModelInfo]) -> LocalModelInfo?
    /// A provider for `model` (nil: the suggested one), or nil if none.
    func makeProvider(model: String?) async -> (any OwlHintProvider)?
}

extension AIEngine {
    public var title: String { kind.title }
    public var note: String? { nil }
}

public enum AIEngines {
    /// The engine a fresh install starts with (nothing saved yet): Apple
    /// Intelligence when this Mac can run it, else Cedric's built-in engine,
    /// else LM Studio (the user picks a server).
    public static func defaultBackend(appleAvailable: Bool = AppleFoundationModelsProvider.isAvailable,
                                      builtInAvailable: Bool = ModelCatalog.bundled() != nil) -> LocalAISettings.Backend {
        if appleAvailable { return .apple }
        if builtInAvailable { return .builtIn }
        return .lmStudio
    }

    /// The engine the settings select.
    public static func engine(for settings: LocalAISettings, session: URLSession? = nil) -> any AIEngine {
        switch settings.backend {
        case .builtIn: return BuiltInEngine()
        case .apple: return AppleIntelligenceEngine()
        case .lmStudio, .ollama, .custom:
            return ServerEngine(kind: settings.backend,
                                client: LocalModelClient(baseURL: settings.baseURL, timeout: settings.timeout, session: session))
        }
    }
}

/// LM Studio / Ollama on this Mac, or either on another Mac on the LAN:
/// an OpenAI-compatible server, local or LAN only (`LocalEndpointPolicy`).
public struct ServerEngine: AIEngine {
    public let kind: LocalAISettings.Backend
    public let client: LocalModelClient

    public init(kind: LocalAISettings.Backend, client: LocalModelClient) {
        self.kind = kind
        self.client = client
    }

    public var isAvailable: Bool { true }
    public var unavailableReason: String? { nil }
    public var needsAddress: Bool { true }

    public func models() async throws -> [LocalModelInfo] { try await client.listModels() }
    public func test() async -> ConnectionReport { await client.testConnection() }
    public func suggestedModel(in models: [LocalModelInfo]) -> LocalModelInfo? { ModelPicker.pickSmallQwen(models) }

    public func makeProvider(model: String?) async -> (any OwlHintProvider)? {
        guard LocalEndpointPolicy.isAllowed(client.baseURL) else { return nil }
        if let model, !model.isEmpty { return LocalModelHintProvider(client: client, model: model) }
        guard let models = try? await models(), let pick = suggestedModel(in: models) else { return nil }
        return LocalModelHintProvider(client: client, model: pick.id)
    }
}

// BuiltInEngine (Cedric's own engine, llama.cpp + in-app downloads) is in BuiltIn/BuiltInEngine.swift.

/// Apple Intelligence's on-device model (macOS 26+, Apple silicon, turned
/// on). Never the Private Cloud Compute model.
public struct AppleIntelligenceEngine: AIEngine {
    public static let modelID = "apple-on-device"
    /// This Mac's Apple Intelligence state, read once when the engine is made
    /// (`AppleFoundationModelsProvider.status`); tests pass one in.
    public let status: AppleIntelligenceStatus
    public init(status: AppleIntelligenceStatus = AppleFoundationModelsProvider.status) { self.status = status }
    public var kind: LocalAISettings.Backend { .apple }
    public var isAvailable: Bool { status == .available }
    public var unavailableReason: String? { status.message }
    public var needsAddress: Bool { false }
    public func models() async throws -> [LocalModelInfo] { isAvailable ? [LocalModelInfo(id: Self.modelID, type: "llm")] : [] }
    public func test() async -> ConnectionReport {
        let m = (try? await models()) ?? []
        return ConnectionReport(models: m, latency: 0, suggested: m.first,
                                error: isAvailable ? nil : .transport(unavailableReason ?? "unavailable"))
    }
    public func suggestedModel(in models: [LocalModelInfo]) -> LocalModelInfo? { models.first }
    public func makeProvider(model: String?) async -> (any OwlHintProvider)? {
        isAvailable ? AppleFoundationModelsProvider() : nil
    }
}
