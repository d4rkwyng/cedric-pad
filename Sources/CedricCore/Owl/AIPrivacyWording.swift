import Foundation

/// What Cedric says about where the text goes, chosen from the engine
/// actually in use: on this Mac (built-in, Apple Intelligence) or the AI
/// server the user set up (LM Studio, Ollama, another Mac), and whether
/// the automatic AI grammar pass also sends prose without being asked.
public struct AIPrivacyWording: Sendable, Equatable {
    public enum Engine: Sendable, Equatable {
        /// No engine ready.
        case none
        /// Runs on this Mac.
        case local
        /// A server the user set up; `host` as shown (nil if unknown).
        case server(host: String?)
    }

    public var engine: Engine
    /// Automatic AI grammar is on: prose is checked after typing pauses.
    public var autoGrammar: Bool

    public init(engine: Engine, autoGrammar: Bool) {
        self.engine = engine; self.autoGrammar = autoGrammar
    }

    /// "the AI server you set up (192.168.1.20)".
    private var serverName: String {
        if case .server(let host?) = engine, !host.isEmpty { return String(localized: "the AI server you set up (\(host))") }
        return String(localized: "the AI server you set up")
    }

    /// The last sentence of the owl's one-time Ask Cedric bubble.
    public var introSentence: String {
        switch engine {
        case .none, .local: return String(localized: "It stays on this Mac.")
        case .server: return String(localized: "What you ask goes to \(serverName), nowhere else.")
        }
    }

    /// The last sentences of the Ask Cedric setting's tooltip.
    public var settingsSentence: String {
        switch (engine, autoGrammar) {
        case (.none, _):
            return String(localized: "Nothing is sent until an engine is set up and you ask.")
        case (.local, false):
            return String(localized: "The engine runs on this Mac: nothing leaves it, and nothing is read until you ask.")
        case (.local, true):
            return String(localized: "The engine runs on this Mac and nothing leaves it. With automatic AI grammar on, prose you write is also checked by it after you pause typing, without asking.")
        case (.server, false):
            return String(localized: "Text is sent to \(serverName) only when you ask.")
        case (.server, true):
            return String(localized: "Text is sent to \(serverName) when you ask, and, with automatic AI grammar on, prose you write is also sent to it after you pause typing, without asking.")
        }
    }
}
