import Foundation

/// The Settings window's tabs (0.4.1, UX review #1), in toolbar order.
/// The raw value is what is saved, so the window reopens on the tab it
/// was left on.
public enum SettingsPane: String, CaseIterable, Sendable {
    case general, editor, writing, cedric

    /// UserDefaults key of the last selected tab.
    public static let defaultsKey = "settingsPane"

    /// The saved tab, or General when nothing (or something unknown) is saved.
    public static func restored(_ raw: String?) -> SettingsPane {
        raw.flatMap(SettingsPane.init(rawValue:)) ?? .general
    }

    /// The toolbar item's SF Symbol.
    public var symbolName: String {
        switch self {
        case .general: return "gearshape"
        case .editor: return "curlybraces"
        case .writing: return "pencil.line"
        case .cedric: return "sparkles"
        }
    }
}

/// The on/off settings that are also menu toggles (View, Edit), shown as
/// checkboxes in Settings › Editor and Writing. Both places write the same
/// UserDefaults key, so either one updates the other.
public enum MenuToggleSetting: String, CaseIterable, Sendable {
    case wrapLines, showInvisibles, showLineNumbers, highlightOccurrences, autoCloseBrackets
    case checkSpellingWhileTyping, checkGrammar

    /// The UserDefaults key the menu item and the checkbox share.
    public var defaultsKey: String {
        switch self {
        case .checkGrammar: return "checkGrammarInProse"
        default: return rawValue
        }
    }

    /// The value before the user sets one.
    public var defaultValue: Bool {
        switch self {
        case .showInvisibles: return false
        case .wrapLines, .showLineNumbers, .highlightOccurrences, .autoCloseBrackets, .checkSpellingWhileTyping, .checkGrammar: return true
        }
    }

    /// The tab its checkbox is on.
    public var pane: SettingsPane {
        switch self {
        case .checkSpellingWhileTyping, .checkGrammar: return .writing
        default: return .editor
        }
    }
}

/// Runs `work` for submitted values one at a time, in order; values
/// submitted while one runs are coalesced to the newest. Settings that
/// apply instantly (Cedric's AI engine) use it so a burst of changes
/// costs one apply of the last state, never overlapping applies.
@MainActor
public final class LatestOnlyRunner<Value: Sendable> {
    private let work: @MainActor (Value) async -> Void
    private var pending: Value?
    private var running = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(_ work: @escaping @MainActor (Value) async -> Void) { self.work = work }

    /// True while a value is applied or waiting.
    public var isBusy: Bool { running || pending != nil }

    public func submit(_ value: Value) {
        pending = value
        guard !running else { return }
        running = true
        Task { @MainActor in
            while let next = pending {
                pending = nil
                await work(next)
            }
            running = false
            let w = waiters
            waiters = []
            for c in w { c.resume() }
        }
    }

    /// Returns once nothing is running or pending.
    public func idle() async {
        guard isBusy else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}
