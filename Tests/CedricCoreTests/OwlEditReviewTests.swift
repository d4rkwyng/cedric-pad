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

    @Test func largeModeAndPausedExtrasAreReadOnly() throws {
        #expect(OwlEditAccess.readOnly(editable: true, following: false, largeDocument: true, extrasPaused: false))
        #expect(OwlEditAccess.readOnly(editable: true, following: false, largeDocument: false, extrasPaused: true))
        #expect(OwlEditAccess.readOnly(editable: false, following: false, largeDocument: false, extrasPaused: false))
        #expect(OwlEditAccess.readOnly(editable: true, following: true, largeDocument: false, extrasPaused: false))
        #expect(!OwlEditAccess.readOnly(editable: true, following: false, largeDocument: false, extrasPaused: false))
        let p = try OwlEditProposal.anchored(find: "Seeds cost 40 euros.", replace: "Seeds cost 45 euros.", in: snap()).get()
        #expect(p.state(text: Self.doc as NSString, generation: 4, readOnly: true) == .readOnly)
    }

    @Test func cardsAreSearchedOncePerFindAndOnlyWhileThePanelIsVisible() throws {
        #expect(OwlCardRefresh.debounce == 0.15)
        #expect(!OwlCardRefresh.shouldRefresh(panelVisible: false, largeDocument: false, extrasPaused: false, hasCards: true))
        #expect(!OwlCardRefresh.shouldRefresh(panelVisible: true, largeDocument: true, extrasPaused: false, hasCards: true))
        #expect(!OwlCardRefresh.shouldRefresh(panelVisible: true, largeDocument: false, extrasPaused: true, hasCards: true))
        #expect(!OwlCardRefresh.shouldRefresh(panelVisible: true, largeDocument: false, extrasPaused: false, hasCards: false))
        #expect(OwlCardRefresh.shouldRefresh(panelVisible: true, largeDocument: false, extrasPaused: false, hasCards: true))

        let s = snap()
        let ns = Self.doc as NSString
        let seeds = try OwlEditProposal.anchored(find: "Seeds cost 40 euros.", replace: "Seeds cost 45 euros.", in: s).get()
        let seedsAgain = try OwlEditProposal.anchored(find: "Seeds cost 40 euros.", replace: "Seeds cost 41 euros.", in: s).get()
        let compost = try OwlEditProposal.anchored(find: "Compost cost 25 euros.", replace: "Compost cost 30 euros.", in: s).get()
        let once = OwlEditProposal.refresh([seeds, seedsAgain, compost], text: ns, generation: 9, readOnly: false)
        #expect(once.searches == 2)
        #expect(once.states.count == 3 && once.states.allSatisfy { if case .ready = $0 { return true }; return false })

        let lines = try #require(OwlEditProposal.lines(3, 3, with: "Seeds cost 45 euros.", in: s))
        let byLine = OwlEditProposal.refresh([lines], text: ns, generation: s.generation, readOnly: false)
        #expect(byLine.searches == 0 && byLine.states == [.ready(lines.range)])

        let many = String(repeating: "a", count: 5_000) as NSString
        let hit = OwlEditProposal(range: NSRange(location: 0, length: 1), original: "a", replacement: "b",
                                  reason: "", firstLine: 1, lastLine: 1, generation: 1, anchor: .text)
        let bounded = OwlEditProposal.refresh([hit, hit], text: many, generation: 1, readOnly: false)
        #expect(bounded.searches == 1 && bounded.states == [.stale, .stale])
        #expect(OwlEditProposal.occurrences(of: "a", in: many, limit: 2).count == 2)

        let blocked = OwlEditProposal.refresh([seeds, compost], text: ns, generation: 4, readOnly: true)
        #expect(blocked.searches == 0 && blocked.states == [.readOnly, .readOnly])
    }
}
