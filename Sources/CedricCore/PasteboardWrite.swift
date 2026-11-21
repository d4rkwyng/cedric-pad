import Foundation

/// Whether an async Copy as Rich Text or Copy as HTML completion may
/// still write the general pasteboard. Record the pasteboard's change
/// count when the request starts (`init(changeCount:)`). The completion
/// writes only when that count is unchanged — every copy, in this app or
/// any other, advances it, including a plain AppKit copy that never calls
/// into Cedric — and the document is still the active one.
///
/// A value, so the rule can be tested without AppKit. The change count
/// at write time is passed in.
public struct PasteboardWrite: Equatable, Sendable {
    public let startedAt: Int

    public init(changeCount: Int) {
        startedAt = changeCount
    }

    /// True when `changeCount` is still the count from the start of the
    /// request and the document is still active.
    public func allowsWrite(changeCount: Int, documentIsActive: Bool) -> Bool {
        documentIsActive && changeCount == startedAt
    }
}
