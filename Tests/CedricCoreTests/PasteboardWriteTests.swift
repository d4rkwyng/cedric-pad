import Foundation
import Testing
@testable import CedricCore

/// A stale Copy as Rich Text completion must not write once any copy has
/// changed the pasteboard, and must not write once its document is no
/// longer the active one. The change count is injected: the decision
/// does not read the pasteboard.
@Suite struct PasteboardWriteTests {
    @Test func writesOnlyWhenTheChangeCountIsUnchangedAndTheTabIsActive() {
        let write = PasteboardWrite(changeCount: 4)
        #expect(write.startedAt == 4)
        #expect(write.allowsWrite(changeCount: 4, documentIsActive: true))
        // A copy in this app or another advanced the pasteboard.
        #expect(!write.allowsWrite(changeCount: 5, documentIsActive: true))
        // The count moved the other way: still a different pasteboard.
        #expect(!write.allowsWrite(changeCount: 3, documentIsActive: true))
        // Same count, but the tab is no longer the active one.
        #expect(!write.allowsWrite(changeCount: 4, documentIsActive: false))
        #expect(!write.allowsWrite(changeCount: 5, documentIsActive: false))
        // Before the first copy of a session the count is zero.
        let fresh = PasteboardWrite(changeCount: 0)
        #expect(fresh.allowsWrite(changeCount: 0, documentIsActive: true))
        #expect(!fresh.allowsWrite(changeCount: 0, documentIsActive: false))
        #expect(!fresh.allowsWrite(changeCount: 1, documentIsActive: true))
    }
}
