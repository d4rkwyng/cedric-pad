import Foundation
import Testing
@testable import CedricCore

/// A stale Copy as Rich Text completion must not replace a newer copy,
/// and must not write once its document is no longer the active one.
@Suite struct CopyGenerationTests {
    @Test func onlyTheLatestCopyFromTheActiveDocumentWrites() {
        var g = CopyGeneration()
        #expect(!g.allowsPasteboardWrite(ticket: 0, documentIsActive: true))
        let first = g.issue()
        #expect(first == 1)
        #expect(g.allowsPasteboardWrite(ticket: first, documentIsActive: true))
        // Switched to another tab: the same copy must not write.
        #expect(!g.allowsPasteboardWrite(ticket: first, documentIsActive: false))
        // A second rich-text copy, or a synchronous plain Copy, takes the next number.
        let second = g.issue()
        #expect(second > first)
        #expect(!g.allowsPasteboardWrite(ticket: first, documentIsActive: true))
        #expect(g.allowsPasteboardWrite(ticket: second, documentIsActive: true))
        #expect(!g.allowsPasteboardWrite(ticket: second, documentIsActive: false))
        // Back on that document, only the latest copy may write.
        let plain = g.issue()
        #expect(plain == g.latest)
        #expect(!g.allowsPasteboardWrite(ticket: second, documentIsActive: true))
        #expect(g.allowsPasteboardWrite(ticket: plain, documentIsActive: true))
    }
}
