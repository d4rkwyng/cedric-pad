import Foundation

/// The user-facing settings for the owl's local-AI hints.
///
/// Privacy defaults: `enabled` is **false**. When enabled, requests go only
/// to `baseURL`, which must be a loopback, `.local`, or private-network
/// (RFC 1918 / CGNAT / link-local) host — see `LocalEndpointPolicy`. There is
/// no cloud backend and no API-key field.
public struct LocalAISettings: Codable, Sendable, Equatable {
    public enum Backend: String, Codable, Sendable, CaseIterable {
        case lmStudio, ollama, custom

        public var defaultBaseURL: URL {
            switch self {
            case .lmStudio, .custom: return URL(string: "http://localhost:1234/v1")!
            case .ollama: return URL(string: "http://localhost:11434/v1")!
            }
        }
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

    public init(enabled: Bool = false,
                backend: Backend = .lmStudio,
                baseURL: URL? = nil,
                model: String? = nil,
                minInterval: TimeInterval = 90,
                pauseDelay: TimeInterval = 5,
                timeout: TimeInterval = 20) {
        self.enabled = enabled
        self.backend = backend
        self.baseURL = baseURL ?? backend.defaultBaseURL
        self.model = model
        self.minInterval = minInterval
        self.pauseDelay = pauseDelay
        self.timeout = timeout
    }

    public static let `default` = LocalAISettings()

    static let defaultsKey = "CedricLocalAISettings"

    public static func load(from defaults: UserDefaults = .standard) -> LocalAISettings {
        guard let data = defaults.data(forKey: defaultsKey),
              let s = try? JSONDecoder().decode(LocalAISettings.self, from: data) else {
            return .default
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
