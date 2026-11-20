import Foundation

/// The theme choices, the same set as Tankard's: System (light or dark
/// with macOS), Light, Dark, Tankard (deep purple and amber) and Dracula.
public enum EditorTheme: String, CaseIterable, Codable, Sendable {
    case system, light, dark, tankard, dracula, cedric, cedricNight

    public static let defaultsKey = "theme"

    public var displayName: String {
        switch self {
        case .system: return String(localized: "System")
        case .light: return String(localized: "Light")
        case .dark: return String(localized: "Dark")
        case .tankard: return "Tankard"
        case .dracula: return "Dracula"
        case .cedric: return "Cedric"
        case .cedricNight: return "Cedric Night"
        }
    }

    /// The palette to draw with, given whether macOS is in dark mode.
    public func palette(systemIsDark: Bool) -> EditorPalette {
        switch self {
        case .system: return systemIsDark ? EditorPalettes.dark : EditorPalettes.light
        case .light: return EditorPalettes.light
        case .dark: return EditorPalettes.dark
        case .tankard: return EditorPalettes.tankard
        case .dracula: return EditorPalettes.dracula
        case .cedric: return EditorPalettes.cedric
        case .cedricNight: return EditorPalettes.cedricNight
        }
    }
}

/// Every colour the editor draws, as sRGB hex, like Tankard's
/// `TankardColors`: each theme is one complete value, and the contrast
/// test checks them all.
public struct EditorPalette: Sendable {
    public var name: String
    public var isDark: Bool
    public var background: UInt32
    public var foreground: UInt32
    public var gutterBackground: UInt32
    public var gutterForeground: UInt32
    public var currentLine: UInt32
    public var selection: UInt32
    public var caret: UInt32
    public var invisibles: UInt32
    public var findMatch: UInt32
    public var statusBar: UInt32
    public var tokens: [TokenKind: UInt32]

    public func color(for kind: TokenKind) -> UInt32 { kind == .embeddedCode ? foreground : tokens[kind] ?? foreground }

    /// The Context Bar's icons (0.4.0 UX polish): tinted explicitly, not
    /// left to the system's template grey, which fell below WCAG's 3:1 for
    /// graphics on the bar (2.62:1 light, 2.86:1 Tankard). The gutter's
    /// muted colour, and the link colour for a toggle that is on; the test
    /// checks both against `statusBar` in every theme.
    public var contextBarIcon: UInt32 { gutterForeground }
    public var contextBarIconOn: UInt32 { color(for: .link) }

    /// Text/background pairs that must meet WCAG AA (4.5:1).
    public var textPairs: [(String, UInt32, UInt32)] {
        var pairs: [(String, UInt32, UInt32)] = [
            ("\(name): text", foreground, background),
            ("\(name): text on current line", foreground, currentLine),
            ("\(name): text on selection", foreground, selection),
            ("\(name): line numbers", gutterForeground, gutterBackground),
        ]
        for kind in TokenKind.allCases where kind != .plain {
            pairs.append(("\(name): \(kind)", color(for: kind), background))
            pairs.append(("\(name): \(kind) on current line", color(for: kind), currentLine))
        }
        return pairs
    }
}

public enum EditorPalettes {
    /// Xcode-like light colours, adjusted so every token reaches 4.5:1.
    public static let light = EditorPalette(
        name: "light", isDark: false,
        background: 0xffffff, foreground: 0x1d1d1f, gutterBackground: 0xf5f5f7, gutterForeground: 0x6e6e73,
        currentLine: 0xeef3fb, selection: 0xb4d5fe, caret: 0x0a60ff, invisibles: 0xc2c2c7, findMatch: 0xffe36e,
        statusBar: 0xf2f2f4,
        tokens: [
            .keyword: 0x9b2393, .type: 0x0b4f79, .string: 0xc41a16, .number: 0x1c00cf, .constant: 0x9b2393,
            .comment: 0x5d6c79, .function: 0x326d74, .attribute: 0x815f03, .variable: 0x3e6d8a, .preprocessor: 0x643820,
            .tag: 0x9b2393, .key: 0x0b4f79, .heading: 0x0b4f79, .emphasis: 0x6c3a9e, .strong: 0x8a3b12,
            .link: 0x0e5bd8, .code: 0xb2380b, .punctuation: 0x6e6e73,
        ])

    /// Xcode-like dark colours, comments lifted to reach 4.5:1.
    public static let dark = EditorPalette(
        name: "dark", isDark: true,
        background: 0x1f1f24, foreground: 0xdfdfe0, gutterBackground: 0x1a1a1e, gutterForeground: 0x8e8e93,
        currentLine: 0x2a2a31, selection: 0x3f638b, caret: 0xffffff, invisibles: 0x48484f, findMatch: 0x6b5a1e,
        statusBar: 0x26262b,
        tokens: [
            .keyword: 0xfc5fa3, .type: 0x5dd8ff, .string: 0xfc6a5d, .number: 0xd0bf69, .constant: 0xfc5fa3,
            .comment: 0x8a96a2, .function: 0x67b7a4, .attribute: 0xfd8f3f, .variable: 0xa8c9ff, .preprocessor: 0xfd8f3f,
            .tag: 0xfc5fa3, .key: 0x5dd8ff, .heading: 0x5dd8ff, .emphasis: 0xc9a6ff, .strong: 0xffb37a,
            .link: 0x6bb0ff, .code: 0xfd8f3f, .punctuation: 0xa0a0a8,
        ])

    /// Tankard's deep palette: the window purple #1f0d3d, foam text, amber
    /// accent for keywords, its badge colours for the rest.
    public static let tankard = EditorPalette(
        name: "tankard", isDark: true,
        background: 0x1f0d3d, foreground: 0xfff6e6, gutterBackground: 0x170a2e, gutterForeground: 0xab9bd0,
        currentLine: 0x27124c, selection: 0x5a3550, caret: 0xf2a93b, invisibles: 0x4a3570, findMatch: 0x6e4a1a,
        statusBar: 0x331a62,
        tokens: [
            .keyword: 0xf2a93b, .type: 0xf3c2ff, .string: 0x8fe8a8, .number: 0xb0ccff, .constant: 0xffc46e,
            .comment: 0xab9bd0, .function: 0xffc46e, .attribute: 0xd98cff, .variable: 0xd6c8f0, .preprocessor: 0xd98cff,
            .tag: 0xf2a93b, .key: 0xb0ccff, .heading: 0xf2a93b, .emphasis: 0xece4f8, .strong: 0xfff6e6,
            .link: 0xb0ccff, .code: 0x8fe8a8, .punctuation: 0xab9bd0,
        ])

    /// Dracula (draculatheme.com, MIT). The comment grey is lightened
    /// (#6272a4 → #8f9bc8) to reach 4.5:1, as Tankard does with its greys.
    public static let dracula = EditorPalette(
        name: "dracula", isDark: true,
        background: 0x282a36, foreground: 0xf8f8f2, gutterBackground: 0x21222c, gutterForeground: 0x9ea3c0,
        currentLine: 0x2f3142, selection: 0x44475a, caret: 0xf8f8f2, invisibles: 0x4b4e66, findMatch: 0x5e5a2e,
        statusBar: 0x21222c,
        tokens: [
            .keyword: 0xff79c6, .type: 0x8be9fd, .string: 0xf1fa8c, .number: 0xbd93f9, .constant: 0xbd93f9,
            .comment: 0x8f9bc8, .function: 0x50fa7b, .attribute: 0x50fa7b, .variable: 0xffb86c, .preprocessor: 0xff79c6,
            .tag: 0xff79c6, .key: 0x8be9fd, .heading: 0xbd93f9, .emphasis: 0xf1fa8c, .strong: 0xffb86c,
            .link: 0x8be9fd, .code: 0x50fa7b, .punctuation: 0xff79c6,
        ])

    /// The owl's own colours (tools/icon/cedric_icon.py): warm peach paper
    /// from the coral plate (#ff7c5c), navy text (#27295a), gold (#ffc533,
    /// darkened to read on paper) for keywords and numbers, coral for
    /// strings, the wing and body navies for types and functions, the chest
    /// chevron's grey-blue (#5d5f83) for comments.
    public static let cedric = EditorPalette(
        name: "cedric", isDark: false,
        background: 0xfbeee4, foreground: 0x27295a, gutterBackground: 0xf4e2d4, gutterForeground: 0x5d5f83,
        currentLine: 0xf6e3d4, selection: 0xf2cf7a, caret: 0x27295a, invisibles: 0xd9c2b1, findMatch: 0xffc533,
        statusBar: 0xf4e2d4,
        tokens: [
            .keyword: 0x8a5300, .type: 0x2f4f9a, .string: 0xb2391d, .number: 0x855400, .constant: 0x8a5300,
            .comment: 0x5d5f83, .function: 0x3b3e7c, .attribute: 0x8a5300, .variable: 0x3b4f8a, .preprocessor: 0x9a3412,
            .tag: 0xb2391d, .key: 0x2f4f9a, .heading: 0x3b3e7c, .emphasis: 0x5a3e8c, .strong: 0x9a3412,
            .link: 0x2f4f9a, .code: 0xb2391d, .punctuation: 0x5d5f83,
        ])

    /// Cedric at night: the owl's navy as the page, sepia text, gold and
    /// coral accents.
    public static let cedricNight = EditorPalette(
        name: "cedricNight", isDark: true,
        background: 0x1b1c3d, foreground: 0xf3e3d3, gutterBackground: 0x17183a, gutterForeground: 0x9a9cc0,
        currentLine: 0x24264f, selection: 0x4d4426, caret: 0xffc533, invisibles: 0x3b3e7c, findMatch: 0x6b5320,
        statusBar: 0x22234a,
        tokens: [
            .keyword: 0xffc533, .type: 0xa9b4ff, .string: 0xff8d6b, .number: 0xffd36e, .constant: 0xffb48a,
            .comment: 0x9a9cc0, .function: 0xc9c2ff, .attribute: 0xffb46b, .variable: 0xd6ccff, .preprocessor: 0xff9e7d,
            .tag: 0xff8d6b, .key: 0xa9b4ff, .heading: 0xffc533, .emphasis: 0xe8d5ff, .strong: 0xffd9b0,
            .link: 0x8fb0ff, .code: 0xff9e7d, .punctuation: 0x9a9cc0,
        ])

    public static let all = [light, dark, tankard, dracula, cedric, cedricNight]

    /// WCAG relative-luminance contrast ratio of two sRGB colours.
    public static func contrast(_ a: UInt32, _ b: UInt32) -> Double {
        func lum(_ c: UInt32) -> Double {
            func ch(_ v: UInt32) -> Double {
                let s = Double(v) / 255
                return s <= 0.03928 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * ch((c >> 16) & 0xff) + 0.7152 * ch((c >> 8) & 0xff) + 0.0722 * ch(c & 0xff)
        }
        let la = lum(a), lb = lum(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }
}
