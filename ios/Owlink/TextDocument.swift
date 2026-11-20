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
    /// Set by the editor: returns its current text before a save.
    var currentText: (() -> String)?
    private(set) var firstUnsavedEdit: Date?

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
    }

    override func save(to url: URL, for saveOperation: UIDocument.SaveOperation, completionHandler: ((Bool) -> Void)? = nil) {
        super.save(to: url, for: saveOperation) { ok in
            if ok { self.firstUnsavedEdit = nil }
            completionHandler?(ok)
        }
    }

    var displayName: String { fileURL.lastPathComponent }

    /// The file types the document browser shows: text of any kind, and any
    /// other file (opened as text when it is text).
    static let browsableTypes: [UTType] = [.text, .sourceCode, .script, .json, .xml, .yaml, .commaSeparatedText,
                                            .propertyList, .data]
}
