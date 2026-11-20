import Foundation
import Testing
@testable import CedricCore

/// Ask Cedric's scope (0.4.0): the whole document by default when it fits
/// the model's context, and get_outline's counts for "how many" questions
/// about a file shown only in part.
@Suite struct OwlAskScopeTests {
    /// A games list: three systems, list items under each (one nested), a
    /// table, and a fenced block whose "- " lines aren't items.
    static let games: String = {
        var s = "Intro\n- loose item\n\n# Games\n\n## NES\n"
        for i in 1...5 { s += "- NES game \(i)\n" }
        s += "  - a note under game 5\n\n## SNES\n"
        for i in 1...3 { s += "1. SNES game \(i)\n" }
        s += "\n```\n- not an item\n| not | a row |\n```\n\n## Genesis\n\n| Title | Year |\n|---|---|\n| Sonic | 1991 |\n| Streets | 1991 |\n"
        return s
    }()
    func snap(_ text: String = Self.games, sel: NSRange = NSRange(location: 0, length: 0)) -> OwlDocumentSnapshot {
        OwlDocumentSnapshot(text: text, generation: 1, selection: sel, visible: NSRange(location: 0, length: 20),
                            fileName: "games.md", language: "markdown")
    }

    @Test func defaultIsWholeDocumentWhenItFitsElseVisible() {
        #expect(OwlChatContext.defaultScope(for: snap(), budget: 5_000) == .wholeDocument)
        #expect(OwlChatContext.defaultScope(for: snap(), budget: 50) == .visible)
        // A selection still wins.
        #expect(OwlChatContext.defaultScope(for: snap(sel: NSRange(location: 0, length: 5)), budget: 5_000) == .selection)
        // The default always builds at the same budget.
        let big = String(repeating: "a line of text\n", count: 600)
        let s = snap(big)
        let scope = OwlChatContext.defaultScope(for: s, budget: 5_000)
        #expect(scope == .visible)
        #expect(OwlChatContext.build(s, scope: scope, budget: 5_000) != nil)
    }

    @Test func sectionCountsListItemsNestedAndTableRowsOutsideCode() {
        let c = OwlTools.sectionCounts(snap())
        #expect(c.map { $0.heading?.title } == [nil, "Games", "NES", "SNES", "Genesis"])
        #expect(c.map(\.listItems) == [1, 0, 6, 3, 0])
        #expect(c.map(\.nestedItems) == [0, 0, 1, 0, 0])
        #expect(c.map(\.tableRows) == [0, 0, 0, 0, 2])
        #expect(c[0].first == 1 && c[0].last == 3)
        #expect(c[2].first == 6 && c[2].last == 13)
    }

    @Test func getOutlineGivesCountsAndTotalsFirst() {
        let out = OwlTools.run(OwlToolCall(name: "get_outline"), on: snap()).text
        let lines = out.components(separatedBy: "\n")
        #expect(lines.first == "Total in all 29 lines: 10 list items, 2 table rows")
        #expect(lines.contains("(before the first heading: 1 list item)"))
        #expect(lines.contains("6| ## NES [6 list items (1 nested)]"))
        #expect(lines.contains("14| ## SNES [3 list items]"))
        #expect(lines.contains { $0.hasSuffix("## Genesis [2 table rows]") })
        #expect(lines.contains("4| # Games"))
    }

    @Test func getOutlineTotalsSurviveTheOutputCap() {
        var s = ""
        for i in 1...80 { s += "## System \(i) with a fairly long heading title\n- game a\n- game b\n" }
        let out = OwlTools.run(OwlToolCall(name: "get_outline"), on: snap(s)).text
        #expect(out.hasPrefix("Total in all 240 lines: 160 list items, 0 table rows; more headings than listed"))
        #expect(out.hasSuffix("[… cut]"))
    }

    @Test func csvOutlineCountsDataRows() {
        let s = OwlDocumentSnapshot(text: "name,system\nMario,NES\nSonic,Genesis\n\n", generation: 1, fileName: "g.csv", language: "csv")
        #expect(OwlTools.run(OwlToolCall(name: "get_outline"), on: s).text == "2 data rows; header: name,system")
    }

    @Test func getLinesReportsTheLinesItShowed() {
        let r = OwlTools.run(OwlToolCall(name: "get_lines", arguments: .object(["start": .number(6), "end": .number(9)])), on: snap())
        #expect(r.lines == 6...9)
        // Capped output: only whole lines that arrived count.
        let long = String(repeating: String(repeating: "x", count: 100) + "\n", count: 100)
        let c = OwlTools.run(OwlToolCall(name: "get_lines", arguments: .object(["start": .number(1), "end": .number(100)])), on: snap(long))
        let shown = c.text.components(separatedBy: "\n").filter { $0.contains("| ") }.count
        #expect(c.lines.map { $0.count } ?? 0 <= shown && (c.lines?.count ?? 0) >= shown - 1)
        #expect(OwlTools.run(OwlToolCall(name: "get_outline"), on: snap()).lines == nil)
    }
}
