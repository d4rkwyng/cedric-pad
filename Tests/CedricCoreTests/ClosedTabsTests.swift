import Foundation
import Testing
@testable import CedricCore

@Suite struct ClosedTabsTests {
    func tab(_ name: String, dirty: Bool) -> SessionTab { SessionTab(untitledName: name, hasBuffer: dirty) }

    @Test func newestLastAndOneEntryPerTab() {
        let a = tab("a", dirty: true), b = tab("b", dirty: false)
        var list = ClosedTabs.push(a, onto: []).list
        list = ClosedTabs.push(b, onto: list).list
        #expect(list.map(\.untitledName) == ["a", "b"])
        // The same tab closed again moves to the top, once.
        list = ClosedTabs.push(a, onto: list).list
        #expect(list.map(\.untitledName) == ["b", "a"])
    }

    @Test func overTheLimitCleanTabsGoFirst() {
        var list: [SessionTab] = []
        var dropped: [SessionTab] = []
        for (n, dirty) in [("d1", true), ("c1", false), ("d2", true), ("c2", false)] {
            let r = ClosedTabs.push(tab(n, dirty: dirty), onto: list, limit: 3)
            list = r.list
            dropped += r.dropped
        }
        // c1 (the oldest without unsaved text) went, not d1.
        #expect(list.map(\.untitledName) == ["d1", "d2", "c2"])
        #expect(dropped.map(\.untitledName) == ["c1"])
        // All unsaved: only then does the oldest unsaved one go.
        let r = ClosedTabs.push(tab("d3", dirty: true), onto: [tab("x", dirty: true), tab("y", dirty: true)], limit: 2)
        #expect(r.list.map(\.untitledName) == ["y", "d3"])
        #expect(r.dropped.map(\.untitledName) == ["x"])
    }

    @Test func savedWithTheSession() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cedric-closed-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SessionStore(directory: dir)
        let closed = tab("Untitled 2", dirty: true)
        try store.writeBuffer(closed.id, text: "closed but kept")
        try store.save(Session(windows: [], closedTabs: [closed]))
        // Pruning keeps what the caller keeps: the closed tab's buffer.
        store.pruneBuffers(keeping: [closed.id])
        let loaded = try #require(store.load())
        #expect(loaded.closedTabs == [closed])
        #expect(store.readBuffer(closed.id) == "closed but kept")
    }
}
