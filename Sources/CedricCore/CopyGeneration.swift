import Foundation

/// Which copy may still write the general pasteboard. Each copy takes the
/// next generation. A Copy as Rich Text completion writes only when its
/// generation is still the latest and the document it came from is still
/// the active one. A later copy — another rich-text copy, or any
/// synchronous copy such as plain Copy — takes a newer generation, so the
/// older completion does not overwrite it.
///
/// A value, so the rule can be tested without AppKit. The app keeps one
/// on the main actor (`PasteboardCopy`).
public struct CopyGeneration: Equatable, Sendable {
    public private(set) var latest: UInt64 = 0

    public init() {}

    /// The next generation. Call for every copy that writes the pasteboard.
    public mutating func issue() -> UInt64 {
        latest &+= 1
        return latest
    }

    /// True when `ticket` is still the latest copy and its document is still active.
    /// A ticket of 0 was never issued.
    public func allowsPasteboardWrite(ticket: UInt64, documentIsActive: Bool) -> Bool {
        documentIsActive && ticket > 0 && ticket == latest
    }
}
