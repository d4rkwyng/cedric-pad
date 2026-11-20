import UIKit
import UniformTypeIdentifiers
import CedricCore

/// One text file, opened through the Files app (local, iCloud Drive or
/// any file provider). Reading and writing go through the core's
/// `TextCodec`, as on the Mac: the encoding and line ending are detected on
/// open, the text is held with LF line endings, and saving writes the
/// file's own encoding and line ending back.
final class TextDocument: UIDocument {
    enum OpenError: LocalizedError {
        case binary, undecodable, unencodable(TextEncoding)
        var errorDescription: String? {
            switch self {
            case .binary: return String(localized: "This file looks like a binary file, not text.")
            case .undecodable: return String(localized: "Owlink couldn’t read this file as text.")
            case .unencodable(let e): return String(localized: "Some characters can’t be saved as \(e.displayName). Choose UTF-8 in the document menu.")
            }
        }
    }

    /// LF-normalised text.
    var text = ""
    var encoding: TextEncoding = .utf8
    var lineEnding: LineEnding = .lf
    var mixedLineEndings = false
    var language = LanguageChoice()
    /// Allows opening a file that looks binary (asked once).
    var openBinaryAnyway = false
    /// Called on the main queue after the file was (re)read from disk.
    var onReload: (() -> Void)?
    /// Called on the main queue when the file changed on disk while there
    /// were unsaved edits: nothing was reloaded; the editor asks Keep Mine
    /// / Use Theirs.
    var onExternalChange: (() -> Void)?
    /// The app asked for the next revert itself (Use Theirs, Keep Other).
    private var revertChosen = false
    /// Keep Mine / Use Theirs is being asked.
    private(set) var externalChangePending = false
    /// Set by the editor: returns its current text before a save.
    var currentText: (() -> String)?
    private(set) var firstUnsavedEdit: Date?
    /// Called on the main queue when `hasUnsavedChanges` may have changed
    /// (an edit, a save, a revert): the editor's "Edited" mark.
    var onEditedChange: (() -> Void)?
    /// Called on the main queue after a save that succeeded.
    var onSaved: (() -> Void)?
    /// "Save automatically" (Settings): read at each autosave.
    var saveAutomatically: () -> Bool = { AppSettings.saveAutomatically }
    /// This document's copy of the file as opened (Revert to Opened Version).
    let openedCopyID = UUID().uuidString
    /// What happened to that copy (nil: not opened yet).
    private(set) var openedCopy: RevertStore.Kept?

    override func contents(forType typeName: String) throws -> Any {
        if let t = currentText?() { text = t }
        guard let data = TextCodec.encode(text, encoding: encoding, lineEnding: lineEnding) else {
            throw OpenError.unencodable(encoding)
        }
        return data
    }

    override func load(fromContents contents: Any, ofType typeName: String?) throws {
        let data: Data
        if let d = contents as? Data { data = d } else if let w = contents as? FileWrapper, let d = w.regularFileContents { data = d } else { data = Data() }
        guard let decoded = TextCodec.decode(data) else { throw OpenError.undecodable }
        if decoded.looksBinary && !openBinaryAnyway { throw OpenError.binary }
        // The bytes as first opened (not on a reload after a change elsewhere).
        if openedCopy == nil { openedCopy = SaveSafetyStores.revert.keep(data, id: openedCopyID) }
        text = decoded.text
        encoding = decoded.encoding
        lineEnding = decoded.lineEnding
        mixedLineEndings = decoded.mixedLineEndings
        if !language.isManual { language = .forFile(named: fileURL.lastPathComponent, content: decoded.text) }
        firstUnsavedEdit = nil
        if let onReload { DispatchQueue.main.async(execute: onReload) }
    }

    override func updateChangeCount(_ change: UIDocument.ChangeKind) {
        super.updateChangeCount(change)
        if change == .done, firstUnsavedEdit == nil { firstUnsavedEdit = Date() }
        if change == .cleared { firstUnsavedEdit = nil }
        notifyEdited()
    }

    private func notifyEdited() {
        guard let onEditedChange else { return }
        if Thread.isMainThread { onEditedChange() } else { DispatchQueue.main.async(execute: onEditedChange) }
    }

    /// UIKit autosaves on a timer, when the app goes to the background and
    /// when the document closes; with "Save automatically" off it doesn't.
    /// Nothing is lost: the editor keeps a recovery copy while there are
    /// unsaved changes, and closing asks Save / Don't Save / Cancel.
    override func autosave(completionHandler: ((Bool) -> Void)? = nil) {
        guard SavePolicy.shouldAutosave(saveAutomatically: saveAutomatically(), hasUnsavedChanges: hasUnsavedChanges) else {
            completionHandler?(true)
            return
        }
        super.autosave(completionHandler: completionHandler)
    }

    /// The private copy of the file as opened, if one was kept.
    func openedBytes() -> Data? { SaveSafetyStores.revert.load(id: openedCopyID) }

    func discardOpenedCopy() { SaveSafetyStores.revert.clear(id: openedCopyID) }

    override func save(to url: URL, for saveOperation: UIDocument.SaveOperation, completionHandler: ((Bool) -> Void)? = nil) {
        super.save(to: url, for: saveOperation) { ok in
            if ok { self.firstUnsavedEdit = nil }
            completionHandler?(ok)
            if ok { self.onSaved?() }
            self.notifyEdited()
        }
    }

    /// UIDocument reverts when the file changed elsewhere, which discards
    /// unsaved edits. With unsaved edits it doesn't, yet: the editor copies
    /// both sides and asks (`onExternalChange`).
    override func revert(toContentsOf url: URL, completionHandler: ((Bool) -> Void)? = nil) {
        switch ExternalChange.onRevert(hasUnsavedChanges: hasUnsavedChanges, chosen: revertChosen, asking: externalChangePending) {
        case .reload:
            revertChosen = false
            externalChangePending = false
            super.revert(toContentsOf: url, completionHandler: completionHandler)
        case .askFirst:
            externalChangePending = true
            completionHandler?(false)
            if let onExternalChange { DispatchQueue.main.async(execute: onExternalChange) }
        case .ignore:
            completionHandler?(false)
        }
    }

    /// Reads the file again after the person chose its version on disk
    /// (Use Theirs, Keep Other Version in a conflict).
    func revertAfterChoice(_ done: @escaping (Bool) -> Void) {
        revertChosen = true
        revert(toContentsOf: fileURL, completionHandler: done)
    }

    /// Keep Mine: the edits stay unsaved, and the next save replaces theirs.
    func keepMineAfterExternalChange() {
        externalChangePending = false
        updateChangeCount(.done)
    }

    var displayName: String { fileURL.lastPathComponent }

    /// The file types the document browser shows: text of any kind, and any
    /// other file (opened as text when it is text).
    static let browsableTypes: [UTType] = [.text, .sourceCode, .script, .json, .xml, .yaml, .commaSeparatedText,
                                            .propertyList, .data]
}
