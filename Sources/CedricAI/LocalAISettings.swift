import Foundation

/// The user-facing settings for the owl's local-AI hints.
///
/// Privacy defaults: `enabled` is **false**. When enabled, requests go only
/// to `baseURL`, which must be a loopback, `.local`, or private-network
/// (RFC 1918 / CGNAT / link-local) host — see `LocalEndpointPolicy`. There is
/// no cloud backend and no API-key field.
public struct LocalAISettings: Codable, Sendable, Equatable {
    /// Where the AI runs ("engine"), in the settings sheet's order.
    /// `custom` is another Mac on the network (raw value kept for saved
    /// settings). `builtIn` is Cedric's own engine (llama.cpp, models
    /// downloaded in the app); `apple` is Apple Intelligence's on-device model.
    public enum Backend: String, Codable, Sendable, CaseIterable {
        case builtIn, lmStudio, ollama, custom, apple

        public var defaultBaseURL: URL {
            switch self {
            case .ollama: return URL(string: "http://localhost:11434/v1")!
            default: return URL(string: "http://localhost:1234/v1")!
            }
        }

        /// Talks to an OpenAI-compatible server at `baseURL`.
        public var usesServer: Bool { self == .lmStudio || self == .ollama || self == .custom }
    }

    public var enabled: Bool
    public var backend: Backend
    /// The OpenAI-compatible root, ending in `/v1`.
    public var baseURL: URL
    /// The model id as `/v1/models` lists it; nil = auto-pick a small Qwen.
    public var model: String?
    /// Minimum seconds between two requests for the same document.
    public var minInterval: TimeInterval
    /// Typing must pause this long before a check is considered.
    public var pauseDelay: TimeInterval
    /// Hard cap on one request, cancelled sooner by a new edit.
    public var timeout: TimeInterval
    /// A document must have been open and idle this long before the AI
    /// looks at it (any engine). Not shown in the sheet; tests shorten it.
    public var minIdle: TimeInterval
    /// Ask the model on its own after typing pauses. Off by default on
    /// Intel Macs (`defaultAutomaticChecks`): there the editor comes first
    /// and the model is asked only when the user clicks "Ask AI Now".
    public var automaticChecks: Bool

    /// True on Apple silicon; false on Intel, where a model on the CPU
    /// would compete with typing.
    public static var defaultAutomaticChecks: Bool {
        #if arch(x86_64)
        return false
        #else
        return true
        #endif
    }

    public init(enabled: Bool = false,
                backend: Backend = .builtIn,
                baseURL: URL? = nil,
                model: String? = nil,
                minInterval: TimeInterval = 90,
                pauseDelay: TimeInterval = 5,
                timeout: TimeInterval = 20,
                minIdle: TimeInterval = 10,
                automaticChecks: Bool = LocalAISettings.defaultAutomaticChecks) {
        self.enabled = enabled
        self.backend = backend
        self.baseURL = baseURL ?? backend.defaultBaseURL
        self.model = model
        self.minInterval = minInterval
        self.pauseDelay = pauseDelay
        self.timeout = timeout
        self.minIdle = minIdle
        self.automaticChecks = automaticChecks
    }

    enum CodingKeys: String, CodingKey {
        case enabled, backend, baseURL, model, minInterval, pauseDelay, timeout, minIdle, automaticChecks
    }

    /// Settings saved before `minIdle` or `automaticChecks` existed still
    /// load (with this Mac's defaults).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decode(Bool.self, forKey: .enabled)
        backend = try c.decode(Backend.self, forKey: .backend)
        baseURL = try c.decode(URL.self, forKey: .baseURL)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        minInterval = try c.decode(TimeInterval.self, forKey: .minInterval)
        pauseDelay = try c.decode(TimeInterval.self, forKey: .pauseDelay)
        timeout = try c.decode(TimeInterval.self, forKey: .timeout)
        minIdle = try c.decodeIfPresent(TimeInterval.self, forKey: .minIdle) ?? 10
        automaticChecks = try c.decodeIfPresent(Bool.self, forKey: .automaticChecks) ?? Self.defaultAutomaticChecks
    }

    public static let `default` = LocalAISettings()

    static let defaultsKey = "CedricLocalAISettings"

    /// The saved settings; with nothing saved, the defaults with the best
    /// engine this Mac has (`AIEngines.defaultBackend`). Still off.
    public static func load(from defaults: UserDefaults = .standard,
                            defaultBackend: @autoclosure () -> Backend = AIEngines.defaultBackend()) -> LocalAISettings {
        guard let data = defaults.data(forKey: defaultsKey),
              let s = try? JSONDecoder().decode(LocalAISettings.self, from: data) else {
            return LocalAISettings(backend: defaultBackend())
        }
        return s
    }

    public func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }
}

/// Keeps the provider on-device or on the LAN. Anything that resolves to a
/// public hostname or address is refused before a request is built.
public enum LocalEndpointPolicy {
    public static func isAllowed(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              var host = url.host?.lowercased(), !host.isEmpty else { return false }
        if host.hasPrefix("[") && host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if host == "localhost" || host.hasSuffix(".localhost") { return true }
        if host.hasSuffix(".local") || host.hasSuffix(".lan") || host.hasSuffix(".home.arpa") { return true }
        if !host.contains(".") && !host.contains(":") { return true }   // bare LAN name, e.g. "studio"
        if host.hasSuffix(".ts.net") { return true }                     // tailnet MagicDNS
        if host == "::1" { return true }
        if host.contains(":") {
            // IPv6: unique-local fc00::/7 and link-local fe80::/10.
            return host.hasPrefix("fc") || host.hasPrefix("fd") || host.hasPrefix("fe8")
                || host.hasPrefix("fe9") || host.hasPrefix("fea") || host.hasPrefix("feb")
        }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }) else {
            return false   // a dotted public hostname
        }
        switch (parts[0], parts[1]) {
        case (127, _), (10, _), (192, 168), (169, 254): return true
        case (172, 16...31): return true
        case (100, 64...127): return true   // CGNAT / Tailscale
        default: return false
        }
    }
}

// MARK: - The settings sheet's model

extension LocalAISettings.Backend {
    /// The endpoint preset's name in the settings sheet.
    public var title: String {
        switch self {
        case .builtIn: return "Built-in (on this Mac)"
        case .lmStudio: return "LM Studio on this Mac"
        case .ollama: return "Ollama on this Mac"
        case .custom: return "Another Mac on your network (URL)"
        case .apple: return "Apple Intelligence (on this Mac, private)"
        }
    }
}

extension LocalAISettings {
    /// Shown under the endpoint in the settings sheet, word for word.
    public static let privacyNote = "Sends only the visible text (up to 8 KB) to the address above. Never the cloud."
    /// The same promise for engines without an address.
    public static let privacyNoteOnDevice = "Uses only the visible text (up to 8 KB), on this Mac. Never the cloud."
    /// Shown when the chosen (or only available) model is ≤ 2B.
    public static let weakModelNote = "Small models give weaker hints."
    /// The interval menu, in seconds (default 90).
    public static let intervalChoices: [TimeInterval] = [30, 60, 90, 120, 300]

    /// Picks an endpoint preset. LM Studio and Ollama set their localhost
    /// URL; Custom keeps the current URL for the user to edit. A different
    /// server means a different model list, so the model goes back to auto.
    public mutating func selectBackend(_ b: Backend) {
        guard b != backend else { return }
        backend = b
        if b != .custom { baseURL = b.defaultBaseURL }
        model = nil
    }

    /// Parses what the user typed in the Custom URL field: adds `http://`
    /// when there is no scheme and `/v1` when there is no path. nil when it
    /// isn't a URL or the host isn't local/LAN (`LocalEndpointPolicy`).
    public static func parseEndpoint(_ raw: String) -> URL? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if !s.contains("://") { s = "http://" + s }
        guard var c = URLComponents(string: s), c.host?.isEmpty == false else { return nil }
        if c.path.isEmpty || c.path == "/" { c.path = "/v1" }
        while c.path.count > 1 && c.path.hasSuffix("/") { c.path.removeLast() }
        guard let url = c.url, LocalEndpointPolicy.isAllowed(url) else { return nil }
        return url
    }

    /// Ready to register: on, with a local/LAN endpoint.
    public var isUsable: Bool { enabled && (!backend.usesServer || LocalEndpointPolicy.isAllowed(baseURL)) }
}
