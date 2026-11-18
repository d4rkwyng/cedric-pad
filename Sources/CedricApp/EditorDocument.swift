import AppKit
import CedricCore

/// One open buffer: where it lives (or its untitled name), how to write it
/// back, and whether it has unsaved changes. The text itself lives in the
/// tab's text storage.
///
/// Not NSDocument: Notepad++'s model (quit without prompts, unsaved and
/// untitled tabs restored next launch) fights NSDocument's save-on-quit
/// review and its own untitled autosave locations, so Cedric keeps a small
/// model of its own and its own session store.
@MainActor
final class EditorDocument {
    let id: UUID
    var fileURL: URL?
    var untitledName: String
    var encoding: TextEncoding = .utf8
    var lineEnding: LineEnding = .lf
    var mixedLineEndings = false
    var language: Language = .plain
    /// Picked from the menu: don't re-detect on save or paste.
    var languageIsManual = false
    var fileModified: Date?

    /// Edits since open; compared with the count at the last save.
    private(set) var changeCount = 0
    private var savedChangeCount = 0
    /// The change count the session store last saved a buffer for.
    var sessionChangeCount = -1

    var isDirty: Bool { changeCount != savedChangeCount }
    /// When the document last went from saved to unsaved (the owl's "Save a copy?").
    private(set) var unsavedSince: Date?
    /// The file changed on disk while the tab had unsaved edits (clean tabs just reload).
    var changedOnDisk = false

    init(id: UUID = UUID(), fileURL: URL? = nil, untitledName: String) {
        self.id = id
        self.fileURL = fileURL
        self.untitledName = untitledName
    }

    var displayName: String { fileURL?.lastPathComponent ?? untitledName }

    func noteChange() {
        if !isDirty { unsavedSince = Date() }
        changeCount += 1
        if !isDirty { unsavedSince = nil }
    }
    func markSaved() { savedChangeCount = changeCount; unsavedSince = nil; changedOnDisk = false }
    /// Restored from a session buffer: unsaved by definition.
    func markDirtyFromSession() { changeCount = savedChangeCount + 1; unsavedSince = unsavedSince ?? Date() }

    enum LoadError: Error, LocalizedError {
        case unreadable(URL, Error)
        case notText(URL)
        var errorDescription: String? {
            switch self {
            case .unreadable(let u, let e): return String(localized: "Couldn’t open “\(u.lastPathComponent)”: \(e.localizedDescription)")
            case .notText(let u): return String(localized: "“\(u.lastPathComponent)” isn’t text in a supported encoding.")
            }
        }
    }

    /// Reads and decodes a file; returns the LF-normalised text.
    static func read(_ url: URL, encoding: TextEncoding? = nil) throws -> (DecodedText, Date?) {
        let data: Data
        do {
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw LoadError.unreadable(url, error)
        }
        guard let decoded = TextCodec.decode(data, as: encoding) else { throw LoadError.notText(url) }
        let mod = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        return (decoded, mod)
    }

    func apply(_ d: DecodedText) {
        encoding = d.encoding
        lineEnding = d.lineEnding
        mixedLineEndings = d.mixedLineEndings
    }

    /// Writes `text` to `url` in this document's encoding and line ending.
    func write(_ text: String, to url: URL) throws {
        guard let data = TextCodec.encode(text, encoding: encoding, lineEnding: lineEnding) else {
            throw NSError(domain: "Cedric", code: 1, userInfo: [NSLocalizedDescriptionKey:
                String(localized: "Some characters can’t be saved as \(encoding.displayName). Choose UTF-8 from the encoding menu in the status bar and save again.")])
        }
        try data.write(to: url, options: .atomic)
        fileURL = url
        fileModified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        mixedLineEndings = false
        markSaved()
    }
}
