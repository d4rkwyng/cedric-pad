import Foundation

/// One tab as it was when the session was saved.
public struct SessionTab: Codable, Equatable, Sendable {
    public var id: UUID
    /// The file, or nil for an untitled tab.
    public var path: String?
    /// "Untitled 3": kept so a restored tab keeps its name.
    public var untitledName: String?
    /// Unsaved changes, kept in the session's buffer file `<id>.txt`.
    public var hasBuffer: Bool
    public var encoding: TextEncoding
    public var lineEnding: LineEnding
    /// A language the user picked by hand (nil: detect again).
    public var language: Language?
    public var selectionLocation: Int
    public var selectionLength: Int
    /// The first visible line, to scroll back to.
    public var topLine: Int
    /// The file's modification date when its buffer was saved; if the
    /// file changed on disk since, the buffer still wins (it is the
    /// user's unsaved work) but the tab says so.
    public var fileModified: Date?
    /// Bookmarked lines (0-based); nil in sessions saved before bookmarks.
    public var bookmarks: [Int]?
    /// Indentation picked for this tab (nil: the file's own or the default).
    public var indentation: Indentation?
    /// The preview was in its own window (View › Detach Preview), and
    /// that window's frame (NSWindow's frame descriptor). Nil otherwise.
    public var previewDetached: Bool?
    public var previewFrame: String?
    /// A PDF tab (a read-only viewer, never written): its page and zoom.
    /// Nil for text tabs and in sessions saved before PDF tabs.
    public var pdf: PDFTabState?

    public init(id: UUID = UUID(), path: String? = nil, untitledName: String? = nil, hasBuffer: Bool = false,
                encoding: TextEncoding = .utf8, lineEnding: LineEnding = .lf, language: Language? = nil,
                selectionLocation: Int = 0, selectionLength: Int = 0, topLine: Int = 0, fileModified: Date? = nil,
                bookmarks: [Int]? = nil, indentation: Indentation? = nil, previewDetached: Bool? = nil, previewFrame: String? = nil, pdf: PDFTabState? = nil) {
        self.id = id
        self.path = path
        self.untitledName = untitledName
        self.hasBuffer = hasBuffer
        self.encoding = encoding
        self.lineEnding = lineEnding
        self.language = language
        self.selectionLocation = selectionLocation
        self.selectionLength = selectionLength
        self.topLine = topLine
        self.fileModified = fileModified
        self.bookmarks = bookmarks
        self.indentation = indentation
        self.previewDetached = previewDetached
        self.previewFrame = previewFrame
        self.pdf = pdf
    }
}

/// One window's tabs, in order.
public struct SessionWindow: Codable, Equatable, Sendable {
    public var tabs: [SessionTab]
    public var selectedTab: Int
    /// NSWindow's frame descriptor string.
    public var frame: String?

    public init(tabs: [SessionTab], selectedTab: Int = 0, frame: String? = nil) {
        self.tabs = tabs
        self.selectedTab = selectedTab
        self.frame = frame
    }
}

public struct Session: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public var version = Session.currentVersion
    public var windows: [SessionWindow]
    /// Unused since untitled names reuse the lowest free number (kept so
    /// older session files still decode).
    public var untitledCounter: Int
    /// Tabs the user closed, oldest first, for File › Reopen Closed Tab.
    /// One with `hasBuffer` keeps its text in its buffer file, so closing
    /// a tab with unsaved changes never loses them. Nil in older sessions.
    public var closedTabs: [SessionTab]?

    public init(windows: [SessionWindow], untitledCounter: Int = 0, closedTabs: [SessionTab]? = nil) {
        self.windows = windows
        self.untitledCounter = untitledCounter
        self.closedTabs = closedTabs
    }

    public var allTabs: [SessionTab] { windows.flatMap(\.tabs) }
}

/// Saves and restores the session: `session.json` plus one UTF-8 buffer
/// file per tab with unsaved changes, in a directory under Application
/// Support. Every write is atomic (temp file + rename), so a crash
/// mid-write leaves the previous version intact; buffers are written
/// before the session that refers to them.
public final class SessionStore: @unchecked Sendable {
    public let directory: URL
    private let fm = FileManager.default
    private let lock = NSLock()

    public init(directory: URL) {
        self.directory = directory
    }

    /// ~/Library/Application Support/Cedric/Session (or `CEDRIC_SESSION_DIR`).
    public static func defaultDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let custom = environment["CEDRIC_SESSION_DIR"], !custom.isEmpty { return URL(fileURLWithPath: custom, isDirectory: true) }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        return base.appendingPathComponent("Cedric/Session", isDirectory: true)
    }

    var sessionFile: URL { directory.appendingPathComponent("session.json") }

    public func bufferURL(_ id: UUID) -> URL { directory.appendingPathComponent("\(id.uuidString).txt") }

    private func ensureDirectory() throws {
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// The saved session, or nil if there is none or it can't be read.
    public func load() -> Session? {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? Data(contentsOf: sessionFile),
              let s = try? JSONDecoder().decode(Session.self, from: data),
              s.version <= Session.currentVersion else { return nil }
        return s
    }

    public func save(_ session: Session) throws {
        lock.lock(); defer { lock.unlock() }
        try ensureDirectory()
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(session).write(to: sessionFile, options: .atomic)
    }

    public func writeBuffer(_ id: UUID, text: String) throws {
        lock.lock(); defer { lock.unlock() }
        try ensureDirectory()
        try Data(text.utf8).write(to: bufferURL(id), options: .atomic)
    }

    public func readBuffer(_ id: UUID) -> String? {
        guard let data = try? Data(contentsOf: bufferURL(id)) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    public func removeBuffer(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }
        try? fm.removeItem(at: bufferURL(id))
    }

    /// Deletes buffer files no tab refers to.
    public func pruneBuffers(keeping ids: Set<UUID>) {
        lock.lock(); defer { lock.unlock() }
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for f in files where f.pathExtension == "txt" {
            if let id = UUID(uuidString: f.deletingPathExtension().lastPathComponent), !ids.contains(id) {
                try? fm.removeItem(at: f)
            }
        }
    }
}

/// The closed-tabs list behind File › Reopen Closed Tab.
public enum ClosedTabs {
    /// How many closed tabs are remembered.
    public static let limit = 50

    /// `tab` pushed on `list` (newest last). Past `limit`, the oldest tabs
    /// without unsaved text go. A tab with unsaved text is never dropped
    /// (its buffer would be deleted, and that text is nowhere else): when
    /// they alone pass the limit, the list grows past it. Returns the new
    /// list and what was dropped (whose buffers the caller deletes).
    public static func push(_ tab: SessionTab, onto list: [SessionTab], limit: Int = ClosedTabs.limit)
        -> (list: [SessionTab], dropped: [SessionTab]) {
        // Reopening and closing the same tab again: one entry.
        var out = list.filter { $0.id != tab.id }
        out.append(tab)
        var dropped: [SessionTab] = []
        while out.count > max(1, limit), let i = out.firstIndex(where: { !$0.hasBuffer }) {
            dropped.append(out.remove(at: i))
        }
        return (out, dropped)
    }
}

/// Untitled tab names, as TextEdit numbers them: the first is "Untitled",
/// then the lowest free "Untitled N" (N ≥ 2) among the untitled tabs open
/// now, so numbers are reused once their tabs close.
public enum UntitledNames {
    public static func next(open: [String], base: String = "Untitled") -> String {
        let taken = Set(open)
        if !taken.contains(base) { return base }
        var n = 2
        while taken.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }
}
