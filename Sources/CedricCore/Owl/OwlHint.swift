import Foundation

public struct OwlHint: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable { case tip, fix, explain, warning }
    public let id: String            // stable, for dedupe/snooze
    public let kind: Kind
    public let title: String         // ≤ 60 chars, shown in the bubble
    public let detail: String?       // optional longer text
    public let range: NSRange?       // text range it refers to, if any
    public let replacement: String?  // if set, bubble offers "Apply"
    public let source: String        // "rules" | "apple" | "local:<model>"

    public init(id: String, kind: Kind, title: String, detail: String? = nil, range: NSRange? = nil,
                replacement: String? = nil, source: String) {
        self.id = id
        self.kind = kind
        self.title = title
        self.detail = detail
        self.range = range
        self.replacement = replacement
        self.source = source
    }
}

public struct OwlContext: Sendable {
    public let fileName: String?; public let language: String
    public let text: String           // only the visible range + ~40 lines margin, capped at 8 KB
    public let textStart: Int         // UTF-16 offset of `text` in the document; hint ranges are relative to `text`
    public let visibleRange: NSRange; public let selection: NSRange?
    public let documentID: UUID; public let editGeneration: Int

    public init(fileName: String?, language: String, text: String, textStart: Int, visibleRange: NSRange, selection: NSRange?,
                documentID: UUID, editGeneration: Int) {
        self.fileName = fileName
        self.language = language
        self.text = text
        self.textStart = textStart
        self.visibleRange = visibleRange
        self.selection = selection
        self.documentID = documentID
        self.editGeneration = editGeneration
    }
}

public protocol OwlHintProvider: Sendable {
    var name: String { get }
    func hints(for context: OwlContext) async -> [OwlHint]
}
