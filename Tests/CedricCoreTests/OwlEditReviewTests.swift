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

    @Test func invisibleCharactersAreShownAndNamed() {
        #expect(OwlTools.maxFindLength == 2_000 && OwlTools.maxReplaceLength == 2_000)
        #expect(!OwlEditInvisibles.contains("a\tb\nc"))
        #expect(OwlEditInvisibles.render("a\tb").text == "a\tb")
        #expect(OwlEditInvisibles.render("a\tb").invisibleRanges.isEmpty)
        let rendered = OwlEditInvisibles.render("a\u{200B}\u{0000}b")
        #expect(rendered.text == "a⟨U+200B⟩⟨U+0000⟩b")
        #expect(rendered.containsInvisible && rendered.invisibleRanges.count == 2)
        let token = "⟨U+200B⟩" as NSString
        #expect(rendered.invisibleRanges[0] == NSRange(location: 1, length: token.length))
        #expect(OwlEditInvisibles.spoken("a\u{200B}") == "a zero width space (U+200B)")
        #expect(OwlEditInvisibles.warning == "Contains invisible characters")
        let long = String(repeating: "b", count: 500)
        let p = OwlEditProposal(range: NSRange(location: 0, length: 2), original: "a\u{200B}", replacement: long,
                                reason: "", firstLine: 1, lastLine: 1, generation: 1, anchor: .text)
        #expect(p.spokenDiff == "Replace “a zero width space (U+200B)” with “\(long)”.")
        #expect(!p.spokenDiff.contains("…"))
        let gone = OwlEditProposal(range: NSRange(location: 0, length: 2), original: "\u{FEFF}x", replacement: "",
                                   reason: "", firstLine: 1, lastLine: 1, generation: 1, anchor: .text)
        #expect(gone.spokenDiff.contains("byte order mark (U+FEFF)"))
        #expect(gone.spokenDiff.hasPrefix("Delete"))
    }

    @Test func applyWaitsUntilTheFullReplacementHasBeenShown() {
        #expect(!OwlEditReview.needsShowAll(rows: ["old", "new"], charsPerRow: 40))
        #expect(OwlEditReview.needsShowAll(rows: [String(repeating: "a", count: 2_000)], charsPerRow: 40))
        #expect(OwlEditReview.needsShowAll(rows: (0..<7).map { "line \($0)" }, charsPerRow: 80))
        #expect(!OwlEditReview.needsShowAll(rows: (0..<6).map { "line \($0)" }, charsPerRow: 80))
        let zw = String(repeating: "\u{200B}", count: 40)
        #expect(OwlEditReview.needsShowAll(rows: [zw], charsPerRow: 40))
        #expect(!OwlEditReview.applyEnabled(ready: true, needsShowAll: true, hasShownAll: false))
        #expect(OwlEditReview.applyEnabled(ready: true, needsShowAll: true, hasShownAll: true))
        #expect(OwlEditReview.applyEnabled(ready: true, needsShowAll: false, hasShownAll: false))
        #expect(!OwlEditReview.applyEnabled(ready: false, needsShowAll: false, hasShownAll: true))
        #expect(!OwlEditReview.applyEnabled(ready: false, needsShowAll: true, hasShownAll: true))
    }

    @Test func theLineTitleFollowsTheUniqueMatch() {
        let text = "one\ntwo\nSeeds cost 40 euros.\n" as NSString
        let index = LineIndex(text)
        let at = text.range(of: "Seeds cost 40 euros.")
        #expect(OwlEditProposal.lineSpan(at, in: index) == (first: 3, last: 3))
        let shifted = "\n" + (text as String) as NSString
        let moved = shifted.range(of: "Seeds cost 40 euros.")
        #expect(OwlEditProposal.lineSpan(moved, lines: LineIndex(shifted), length: shifted.length) == (first: 4, last: 4))
        // The newline belongs to the line it ends, not the one it starts.
        #expect(OwlEditProposal.lineSpan(NSRange(location: 0, length: 4), lines: index, length: text.length) == (first: 1, last: 1))
        #expect(OwlEditProposal.lineSpan(NSRange(location: 0, length: 8), lines: index, length: text.length) == (first: 1, last: 2))
    }
}
