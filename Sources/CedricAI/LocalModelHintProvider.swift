import Foundation
import os
import CedricCore

/// Budget/latency log. Counts only — no document text, no file names, no
/// model output ever reaches the log.
enum AILog {
    static let logger = Logger(subsystem: "net.mindtricks.cedric", category: "owl-ai")
}

/// The owl's local-AI provider: sends the capped context (visible range +
/// margin, ≤ 8 KB), the language and the file name to a local or LAN
/// OpenAI-compatible server and turns the answer into ≤ 2 hints.
///
/// Ranges in the returned hints are UTF-16 offsets into `context.text`
/// (the text the provider was given), not document offsets.
public struct LocalModelHintProvider: OwlHintProvider {
    public let client: LocalModelClient
    public let model: String
    public let maxTokens: Int
    let clock: any OwlClock

    public var name: String { "local:\(model)" }

    public init(client: LocalModelClient, model: String, maxTokens: Int = 320,
                clock: any OwlClock = SystemClock()) {
        self.client = client
        self.model = model
        self.maxTokens = maxTokens
        self.clock = clock
    }

    public func hints(for context: OwlContext) async -> [OwlHint] {
        (try? await requestHints(for: context)) ?? []
    }

    /// The throwing variant, for "Test" buttons and the real check.
    public func requestHints(for context: OwlContext) async throws -> [OwlHint] {
        let text = HintPrompt.capped(context.text)
        let messages = HintPrompt.messages(for: context, text: text, model: model)
        let sentBytes = messages.reduce(0) { $0 + $1.content.utf8.count }
        do {
            let result = try await client.chat(model: model, messages: messages, maxTokens: maxTokens,
                                               jsonSchema: HintPrompt.schema, clock: clock)
            try Task.checkCancellation()
            let hints = HintPrompt.parse(result.content, text: text, source: name)
            AILog.logger.info("""
                owl-ai ok model=\(model, privacy: .public) gen=\(context.editGeneration) \
                sentBytes=\(sentBytes) promptTokens=\(result.promptTokens ?? -1) \
                completionTokens=\(result.completionTokens ?? -1) \
                latencyMs=\(Int(result.latency * 1000)) hints=\(hints.count)
                """)
            return hints
        } catch {
            let kind: String
            switch error {
            case LocalAIError.cancelled, is CancellationError: kind = "cancelled"
            case LocalAIError.timedOut: kind = "timeout"
            case LocalAIError.http(let code): kind = "http\(code)"
            case LocalAIError.endpointNotLocal: kind = "refused-nonlocal"
            default: kind = "error"
            }
            AILog.logger.info("owl-ai \(kind, privacy: .public) model=\(model, privacy: .public) gen=\(context.editGeneration) sentBytes=\(sentBytes)")
            throw error
        }
    }
}

/// The provider-registry hook. The owl UI (branch owl-ui) owns the registry;
/// it asks this factory for a provider and gets nil while the feature is off.
public enum LocalAIOwl {
    /// nil when disabled, when the endpoint isn't local/LAN, or when no
    /// model is configured and no small Qwen can be found.
    public static func makeProvider(settings: LocalAISettings,
                                    session: URLSession? = nil) async -> LocalModelHintProvider? {
        guard settings.enabled, LocalEndpointPolicy.isAllowed(settings.baseURL) else { return nil }
        let client = LocalModelClient(baseURL: settings.baseURL, timeout: settings.timeout, session: session)
        if let model = settings.model, !model.isEmpty {
            return LocalModelHintProvider(client: client, model: model)
        }
        guard let models = try? await client.listModels(),
              let pick = ModelPicker.pickSmallQwen(models) else { return nil }
        return LocalModelHintProvider(client: client, model: pick.id)
    }

    /// A scheduler wired with the settings' timings and the real clock/power.
    public static func makeScheduler(provider: any OwlHintProvider, settings: LocalAISettings,
                                     deliver: @escaping @Sendable (OwlContext, [OwlHint]) async -> Void) -> OwlScheduler {
        OwlScheduler(provider: provider,
                     config: .init(pauseDelay: settings.pauseDelay, minInterval: settings.minInterval,
                                   timeout: settings.timeout),
                     deliver: deliver)
    }
}
