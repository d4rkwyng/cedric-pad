import AppKit
import CedricCore

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
                  blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
    }
}

extension Notification.Name {
    /// The theme, font size or a view option changed: every editor restyles.
    static let cedricAppearanceChanged = Notification.Name("CedricAppearanceChanged")
    /// The owl was switched on or off, or its hint source changed.
    static let cedricOwlSettingsChanged = Notification.Name("CedricOwlSettingsChanged")
}

/// App-wide view settings: theme, font size, wrap, invisibles, line
/// numbers. Saved in UserDefaults; `CEDRIC_THEME` overrides the theme for
/// one run (screenshots) without saving it.
@MainActor
final class Settings {
    static let shared = Settings()
    private let defaults = UserDefaults.standard
    /// CEDRIC_THEME, or set by the typing check: used for this run, not saved.
    var themeOverride: EditorTheme?

    static let defaultFontSize: CGFloat = 13

    private init() {
        themeOverride = ProcessInfo.processInfo.environment["CEDRIC_THEME"].flatMap(EditorTheme.init(rawValue:))
    }

    var theme: EditorTheme {
        get { themeOverride ?? defaults.string(forKey: EditorTheme.defaultsKey).flatMap(EditorTheme.init(rawValue:)) ?? .system }
        set { defaults.set(newValue.rawValue, forKey: EditorTheme.defaultsKey); changed() }
    }

    var fontSize: CGFloat {
        get { let v = defaults.double(forKey: "fontSize"); return v > 0 ? v : Self.defaultFontSize }
        set { defaults.set(min(72, max(6, newValue)), forKey: "fontSize"); changed() }
    }

    var wrapLines: Bool {
        get { defaults.object(forKey: "wrapLines") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "wrapLines"); changed() }
    }

    /// CEDRIC_INVISIBLES=1: on for this run, not saved.
    let invisiblesOverride = ProcessInfo.processInfo.environment["CEDRIC_INVISIBLES"] == "1" ? true : nil as Bool?

    var showInvisibles: Bool {
        get { invisiblesOverride ?? defaults.bool(forKey: "showInvisibles") }
        set { defaults.set(newValue, forKey: "showInvisibles"); changed() }
    }

    var showLineNumbers: Bool {
        get { defaults.object(forKey: "showLineNumbers") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "showLineNumbers"); changed() }
    }

    /// CEDRIC_OWL=1: show the owl for this run, not saved.
    var owlOverride = ProcessInfo.processInfo.environment["CEDRIC_OWL"].map { $0 == "1" }

    /// "Show Cedric the owl": off by default.
    var showOwl: Bool {
        get { owlOverride ?? defaults.bool(forKey: "showOwl") }
        set { defaults.set(newValue, forKey: "showOwl"); NotificationCenter.default.post(name: .cedricOwlSettingsChanged, object: nil) }
    }

    /// View › Check Spelling While Typing: on by default.
    var checkSpellingWhileTyping: Bool {
        get { defaults.object(forKey: "checkSpellingWhileTyping") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "checkSpellingWhileTyping"); changed() }
    }

    /// View › Highlight Occurrences: other occurrences of the selection or
    /// the word under the caret are tinted on screen. On by default.
    var highlightOccurrences: Bool {
        get { defaults.object(forKey: "highlightOccurrences") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "highlightOccurrences"); changed() }
    }

    /// Edit › Auto-Close Brackets and Quotes (code only, not prose). On by default.
    var autoCloseBrackets: Bool {
        get { defaults.object(forKey: "autoCloseBrackets") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "autoCloseBrackets") }
    }

    /// The checks move the owl without saving where he is.
    var owlPlacementInMemory: OwlPlacement?
    var owlPlacementSaves = ProcessInfo.processInfo.environment["CEDRIC_NO_SESSION_SAVE"] != "1"

    /// Where the owl sits over the editor (shared by every tab), as a
    /// corner plus an inset, so it survives window resizes.
    var owlPlacement: OwlPlacement {
        get {
            if !owlPlacementSaves { return owlPlacementInMemory ?? .default }
            guard let data = defaults.data(forKey: "owlPlacement"),
                  let p = try? JSONDecoder().decode(OwlPlacement.self, from: data) else { return .default }
            return p
        }
        set {
            if !owlPlacementSaves { owlPlacementInMemory = newValue; return }
            if let data = try? JSONEncoder().encode(newValue) { defaults.set(data, forKey: "owlPlacement") }
        }
    }

    /// CEDRIC_OWL_SOURCE=rulesAndAI: the hint source for this run, not saved.
    var owlSourceOverride = ProcessInfo.processInfo.environment["CEDRIC_OWL_SOURCE"].flatMap(OwlHintSource.init(rawValue:))

    /// "Hint source": Rules, or Rules + AI (only once an AI provider registers).
    var owlHintSource: OwlHintSource {
        get { owlSourceOverride ?? defaults.string(forKey: "owlHintSource").flatMap(OwlHintSource.init(rawValue:)) ?? .rules }
        set {
            if owlSourceOverride != nil { owlSourceOverride = newValue } else { defaults.set(newValue.rawValue, forKey: "owlHintSource") }
            NotificationCenter.default.post(name: .cedricOwlSettingsChanged, object: nil)
        }
    }

    var font: NSFont { NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular) }

    /// The palette for a view, resolving System against its appearance.
    func palette(for appearance: NSAppearance?) -> EditorPalette {
        let dark = (appearance ?? NSApp.effectiveAppearance).bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return theme.palette(systemIsDark: dark)
    }

    /// The window appearance a theme forces (nil: follow the system).
    var windowAppearance: NSAppearance? {
        switch theme {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark, .tankard, .dracula, .cedricNight: return NSAppearance(named: .darkAqua)
        case .cedric: return NSAppearance(named: .aqua)
        }
    }

    private func changed() {
        NotificationCenter.default.post(name: .cedricAppearanceChanged, object: nil)
    }
}
