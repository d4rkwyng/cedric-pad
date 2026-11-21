import Foundation
import Testing
@testable import CedricCore

/// Review of propose_edit cards: a replaced buffer, large-document Apply,
/// refresh cost, invisible characters, and a refused Apply's undo.
@Suite struct OwlEditReviewTests {
    static let doc = "# Notes\n\nSeeds cost 40 euros.\nCompost cost 25 euros.\n\nWater every 2 days.\nWater every 3 days.\n"
    func snap(_ text: String = doc, generation: Int = 4) -> OwlDocumentSnapshot {
        OwlDocumentSnapshot(text: text, generation: generation, fileName: "notes.md", language: "markdown")
    }

    @Test func aReplacedBufferDropsProposalsAndMovesTheGeneration() throws {
        let s = snap()
        let lines = try #require(OwlEditProposal.lines(3, 3, with: "Seeds cost 45 euros.", in: s))
        let text = try OwlEditProposal.anchored(find: "Seeds cost 40 euros.", replace: "Seeds cost 45 euros.", in: s).get()
        let ns = Self.doc as NSString
        // Same bytes at the stored offset: without a new generation, Apply would edit them.
        #expect(lines.state(text: ns, generation: s.generation) == .ready(lines.range))
        let next = OwlBufferReplacement.generation(after: s.generation)
        #expect(next == s.generation + 1)
        #expect(lines.state(text: ns, generation: next) == .stale)
        // A find/replace is not generation-keyed, so the cards themselves have to go.
        #expect(text.state(text: ns, generation: next) == .ready(ns.range(of: "Seeds cost 40 euros.")))
        #expect(OwlBufferReplacement.kept([lines, text]).isEmpty)
        #expect(OwlBufferReplacement.kept([]).isEmpty)
    }
}
