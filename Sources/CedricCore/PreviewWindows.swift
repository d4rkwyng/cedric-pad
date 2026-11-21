import Foundation

/// The iPad's detached preview ("Open Preview in New Window"): a second
/// window (scene) showing only the Markdown preview of a document that is
/// open in an editor window, following its text live. It is strictly a
/// read-only view of the editor's text: it never opens the document itself
/// and never writes it, so it is exempt from the one-window-per-document
/// rule (`OpenDocumentRegistry`), which only editors register with.
///
/// This is the routing that can be tested without UIKit: what the
/// activity (or the restored session's user info) says, which kind of
/// window a connecting scene becomes, which preview windows follow which
/// document, and what happens to them when the editor goes.
public enum PreviewWindows {
    /// The `NSUserActivity` type that asks for a preview window.
    public static let activityType = "app.owlink.ios.preview"
    /// The plain New Window activity (an empty editor window).
    public static let newWindowActivityType = "app.owlink.ios.newWindow"

    static let roleKey = "owlink.role"
    static let roleValue = "preview"
    static let pathKey = "owlink.documentPath"
    static let editorKey = "owlink.editorWindow"
    static let titleKey = "owlink.title"

    /// Which document a preview window follows, and the editor window it
    /// was detached from.
    public struct Target: Equatable, Hashable, Sendable {
        public var documentPath: String
        public var editorWindow: String
        /// The document's name, for the window's title.
        public var title: String

        public init(documentPath: String, editorWindow: String, title: String) {
            self.documentPath = documentPath
            self.editorWindow = editorWindow
            self.title = title
        }

        /// The same key `OpenDocumentRegistry` uses, however the path is spelled.
        public var documentKey: String { OpenDocumentRegistry.key(forPath: documentPath) }
    }

    /// The activity's (and the scene session's) user info for `target`:
    /// plist types only, so it survives state restoration.
    public static func userInfo(for target: Target) -> [String: String] {
        [roleKey: roleValue, pathKey: target.documentPath, editorKey: target.editorWindow, titleKey: target.title]
    }

    /// The target an activity names; nil for any other activity, or one
    /// with its user info missing or damaged.
    public static func target(activityType: String?, userInfo: [AnyHashable: Any]?) -> Target? {
        guard activityType == Self.activityType else { return nil }
        return target(userInfo: userInfo)
    }

    /// The target a scene session's own user info names (a restored
    /// preview window, which comes back without its activity).
    public static func target(userInfo: [AnyHashable: Any]?) -> Target? {
        guard let info = userInfo, info[roleKey] as? String == roleValue,
              let path = info[pathKey] as? String, !path.isEmpty,
              let editor = info[editorKey] as? String else { return nil }
        let title = (info[titleKey] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? URL(fileURLWithPath: path).lastPathComponent
        return Target(documentPath: path, editorWindow: editor, title: title)
    }

    /// What a connecting scene becomes.
    public enum Route: Equatable, Sendable {
        /// The usual window: the document browser (and an editor).
        case editor
        /// A preview-only window following `Target`'s document.
        case preview(Target)
    }

    /// The connecting scene's activities (type and user info each), then
    /// the session's own user info (a restored window).
    public static func route(activities: [(type: String, userInfo: [AnyHashable: Any]?)],
                             sessionUserInfo: [AnyHashable: Any]?) -> Route {
        for a in activities {
            if let t = target(activityType: a.type, userInfo: a.userInfo) { return .preview(t) }
        }
        if let t = target(userInfo: sessionUserInfo) { return .preview(t) }
        return .editor
    }

    /// "Open Preview in New Window" is offered only where an app can have
    /// more than one window: never on an iPhone (one scene), nor where the
    /// system says multiple scenes aren't supported.
    public static func detachAvailable(supportsMultipleScenes: Bool, isPhone: Bool) -> Bool {
        supportsMultipleScenes && !isPhone
    }

    /// What a preview window shows.
    public enum State: Equatable, Sendable {
        /// The document is open in an editor: its text, live.
        case live
        /// Nobody has it open (the editor closed it, or the window came
        /// back after a relaunch on its own): a quiet blank page.
        case blank
    }

    /// Live while any editor window has the document open (it may have
    /// been reopened in another window since); blank otherwise.
    public static func state(for target: Target, documents: OpenDocumentRegistry) -> State {
        documents.contains(path: target.documentPath) ? .live : .blank
    }
}

/// The preview windows that are open, and which document each follows.
/// Separate from `OpenDocumentRegistry`: a preview never claims its
/// document, so opening that document again still brings its editor
/// forward, not the preview.
public struct PreviewWindowRegistry: Sendable {
    private var targets: [String: PreviewWindows.Target] = [:]

    public init() {}

    public var count: Int { targets.count }

    public mutating func register(previewWindow: String, target: PreviewWindows.Target) {
        targets[previewWindow] = target
    }

    public mutating func unregister(previewWindow: String) {
        targets[previewWindow] = nil
    }

    public func target(ofPreviewWindow id: String) -> PreviewWindows.Target? { targets[id] }

    /// The preview windows following the document at `path`, oldest-ID first
    /// (sorted, so the answer is stable).
    public func previewWindows(forPath path: String) -> [String] {
        let k = OpenDocumentRegistry.key(forPath: path)
        return targets.filter { $0.value.documentKey == k }.map(\.key).sorted()
    }

    public func hasPreviews(forPath path: String) -> Bool { !previewWindows(forPath: path).isEmpty }

    /// Asking for a preview of a document that already has one brings that
    /// window forward instead of opening another.
    public func existing(forPath path: String) -> String? { previewWindows(forPath: path).first }

    /// What happens to the preview windows when an editor lets a document go.
    public enum EditorEvent: Equatable, Sendable {
        /// The editor closed the document (Close, ⌘W, a linked note
        /// opened in its place): its preview windows close.
        case documentClosed(path: String)
        /// The editor's window went away (closed, or discarded by the
        /// system, which may bring it back): its preview windows go blank
        /// rather than vanish, and can be closed.
        case editorWindowGone(window: String)
    }

    public enum Action: Equatable, Sendable {
        case close
        case blank
    }

    /// The preview windows `event` affects and what each should do. A
    /// window gone only blanks previews of documents no other editor
    /// window still has open (`documents`, after the window's removal).
    public func actions(for event: EditorEvent, documents: OpenDocumentRegistry) -> [String: Action] {
        switch event {
        case .documentClosed(let path):
            // Still open in an editor (reopened elsewhere meanwhile): keep.
            guard !documents.contains(path: path) else { return [:] }
            return Dictionary(uniqueKeysWithValues: previewWindows(forPath: path).map { ($0, .close) })
        case .editorWindowGone(let window):
            var out: [String: Action] = [:]
            for (id, t) in targets where t.editorWindow == window && !documents.contains(path: t.documentPath) {
                out[id] = .blank
            }
            return out
        }
    }
}

/// Keeps a detached preview roughly in step with the editor's scroll
/// without reloading or jittering: only a change of more than `threshold`
/// (a share of the page) is passed on.
public struct PreviewScrollFollow: Sendable {
    public var threshold: Double
    private(set) public var last: Double?

    public init(threshold: Double = 0.01) { self.threshold = threshold }

    /// The fraction to apply, or nil if it hasn't moved enough to bother.
    public mutating func next(_ fraction: Double) -> Double? {
        let f = min(max(fraction.isFinite ? fraction : 0, 0), 1)
        if let l = last, abs(l - f) < threshold, f != 0, f != 1 { return nil }
        if let l = last, l == f { return nil }
        last = f
        return f
    }
}
