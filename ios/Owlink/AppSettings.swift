import UIKit
import CedricCore

/// The iOS app's own settings (font size, theme, wrap, owl hints), in
/// UserDefaults. The theme uses the Mac's key and values. Editors listen
/// for `AppSettings.changed`.
enum AppSettings {
    static let changed = Notification.Name("OwlinkSettingsChanged")

    enum Key {
        static let fontSize = "ios.fontSize"
        static let wrap = "ios.wrap"
        static let owlHints = "ios.owlHints"
        static let lineNumbers = "ios.lineNumbers"
        static let theme = EditorTheme.defaultsKey
    }

    static let defaults = UserDefaults.standard

    static var defaultFontSize: Double { UIDevice.current.userInterfaceIdiom == .pad ? 15 : 13 }
    static let fontSizes: ClosedRange<Double> = 9...32

    static var fontSize: Double {
        get { let v = defaults.double(forKey: Key.fontSize); return v == 0 ? defaultFontSize : min(max(v, fontSizes.lowerBound), fontSizes.upperBound) }
        set { defaults.set(min(max(newValue, fontSizes.lowerBound), fontSizes.upperBound), forKey: Key.fontSize); post() }
    }

    static var wrap: Bool {
        get { defaults.object(forKey: Key.wrap) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.wrap); post() }
    }

    /// The owl's offline hints (rules): on by default, like the Mac.
    static var owlHints: Bool {
        get { defaults.object(forKey: Key.owlHints) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.owlHints); post() }
    }

    static var theme: EditorTheme {
        get { defaults.string(forKey: Key.theme).flatMap(EditorTheme.init(rawValue:)) ?? .system }
        set { defaults.set(newValue.rawValue, forKey: Key.theme); post() }
    }

    static func post() { NotificationCenter.default.post(name: changed, object: nil) }

    static func font(size: Double? = nil) -> UIFont {
        UIFont.monospacedSystemFont(ofSize: CGFloat(size ?? fontSize), weight: .regular)
    }
}

extension UIColor {
    /// An sRGB colour from the core palettes' 0xRRGGBB.
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
                  blue: CGFloat(hex & 0xff) / 255, alpha: 1)
    }
}
