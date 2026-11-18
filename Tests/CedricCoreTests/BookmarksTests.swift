import Foundation
import Testing
@testable import CedricCore

@Suite struct BookmarksTests {
    @Test func toggleNextPrevious() {
        var b = Bookmarks()
        b.toggle(5)
        b.toggle(2)
        b.toggle(9)
        #expect(b.lines == [2, 5, 9])
        b.toggle(5)
        #expect(b.lines == [2, 9])
        #expect(b.next(after: 2) == 9)
        #expect(b.next(after: 9) == 2)  // wraps
        #expect(b.previous(before: 9) == 2)
        #expect(b.previous(before: 2) == 9) // wraps
        #expect(Bookmarks().next(after: 0) == nil)
        b.insert(contentsOf: [9, 1, 1])
        #expect(b.lines == [1, 2, 9])
        #expect(b.contains(2) && !b.contains(3))
        b.clamp(lineCount: 5)
        #expect(b.lines == [1, 2])
    }

    @Test func followEdits() {
        // Return in the middle of bookmarked line 3: the bookmark stays, lines below move.
        var b = Bookmarks([3, 7])
        b.adjust(firstLine: 3, removed: 0, inserted: 1, wholeLines: false)
        #expect(b.lines == [3, 8])
        // A line inserted at the start of line 3 pushes its text (and bookmark) down.
        b = Bookmarks([3, 7])
        b.adjust(firstLine: 3, removed: 0, inserted: 1, wholeLines: true)
        #expect(b.lines == [4, 8])
        // Whole lines 3–4 deleted: line 3's bookmark goes, line 5 (now 3) keeps its own.
        b = Bookmarks([3, 5, 9])
        b.adjust(firstLine: 3, removed: 2, inserted: 0, wholeLines: true)
        #expect(b.lines == [3, 7])
        // A selection from inside line 3 to inside line 5 deleted: merged into line 3.
        b = Bookmarks([1, 4, 5, 9])
        b.adjust(firstLine: 3, removed: 2, inserted: 0, wholeLines: false)
        #expect(b.lines == [1, 3, 7])
        // Typing on a line changes nothing.
        b = Bookmarks([2])
        b.adjust(firstLine: 2, removed: 0, inserted: 0, wholeLines: false)
        #expect(b.lines == [2])
    }

    @Test func moveWithTheirLines() {
        var b = Bookmarks([2, 4])
        b.moveLines(2..<3, by: -1) // line 2 swaps with line 1
        #expect(b.lines == [1, 4])
        b.moveLines(3..<5, by: 1) // lines 3–4 swap with line 5
        #expect(b.lines == [1, 5])
        b = Bookmarks([1, 3])
        b.moveLines(3..<4, by: -1) // bookmarked line 3 swaps with unbookmarked 2
        #expect(b.lines == [1, 2])
        b = Bookmarks([2, 3])
        b.moveLines(2..<3, by: 1)  // both bookmarked: both stay marked
        #expect(b.lines == [2, 3])
    }
}

@Suite struct BookmarkSessionTests {
    @Test func savedWithTheTabAndOldSessionsStillLoad() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cedric-bm-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SessionStore(directory: dir)
        let tab = SessionTab(path: "/tmp/a.txt", bookmarks: [3, 10])
        try store.save(Session(windows: [SessionWindow(tabs: [tab])]))
        #expect(store.load()?.allTabs.first?.bookmarks == [3, 10])
        // A session.json from before bookmarks (no key) decodes with none.
        let old = #"{"version":1,"untitledCounter":0,"windows":[{"selectedTab":0,"tabs":[{"id":"\#(UUID().uuidString)","hasBuffer":false,"encoding":"utf8","lineEnding":"lf","selectionLocation":0,"selectionLength":0,"topLine":0}]}]}"#
        try Data(old.utf8).write(to: dir.appendingPathComponent("session.json"))
        let loaded = try #require(store.load())
        #expect(loaded.allTabs.count == 1)
        #expect(loaded.allTabs[0].bookmarks == nil)
    }
}
