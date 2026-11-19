import Foundation
import Testing
@testable import CedricCore

@Suite struct SplitEditorTests {
    @Test func focusFollowsThePanes() {
        var f = PaneFocus()
        #expect(f.active == .first && !f.isSplit && f.other == nil)
        // Unsplit, a "second pane" focus can't happen: commands stay on the first.
        f.focused(.second)
        #expect(f.active == .first)
        f.split(focusSecond: true)
        #expect(f.isSplit && f.active == .second && f.other == .first)
        f.focused(.first)
        #expect(f.active == .first && f.other == .second)
        f.focused(.second)
        #expect(f.active == .second)
    }

    @Test func otherControlsKeepTheLastPane() {
        var f = PaneFocus()
        f.split(focusSecond: true)
        // The find bar, a side panel or a sheet takes the focus: commands
        // still go to the pane it came from.
        f.focused(nil)
        #expect(f.active == .second)
        f.focused(.first)
        f.focused(nil)
        #expect(f.active == .first)
    }

    @Test func unsplitGoesBackToTheFirstPane() {
        var f = PaneFocus()
        f.split(focusSecond: false)
        #expect(f.active == .first && f.isSplit)
        f.focused(.second)
        f.unsplit()
        #expect(f.active == .first && !f.isSplit && f.other == nil)
        // Resplit starts clean.
        f.split(focusSecond: true)
        #expect(f.active == .second)
    }

    @Test func ratioIsClamped() {
        #expect(SplitEditorState.clampRatio(0.5) == 0.5)
        #expect(SplitEditorState.clampRatio(0) == 0.05)
        #expect(SplitEditorState.clampRatio(2) == 0.95)
        #expect(SplitEditorState.clampRatio(.nan) == 0.5)
        #expect(SplitEditorState.clampRatio(-.infinity) == 0.5)
    }

    @Test func dividerPositionKeepsBothPanesUsable() {
        // 601 points with a 1-point divider: halves of 600.
        #expect(SplitEditorState.dividerPosition(ratio: 0.5, total: 601, thickness: 1) == 300)
        // A ratio that would squash a pane below the minimum is held at it.
        #expect(SplitEditorState.dividerPosition(ratio: 0.05, total: 601, thickness: 1) == SplitEditorState.minPane)
        #expect(SplitEditorState.dividerPosition(ratio: 0.95, total: 601, thickness: 1) == 600 - SplitEditorState.minPane)
        // Too little room for two minimum panes: halves.
        #expect(SplitEditorState.dividerPosition(ratio: 0.9, total: 101, thickness: 1) == 50)
        #expect(SplitEditorState.dividerPosition(ratio: 0.5, total: 0, thickness: 1) == 0)
    }

    @Test func ratioRoundTripsThroughThePosition() {
        for r in [0.2, 0.33, 0.5, 0.71] {
            let pos = SplitEditorState.dividerPosition(ratio: r, total: 1001, thickness: 1)
            let back = SplitEditorState.ratio(position: pos, total: 1001, thickness: 1)
            #expect(abs(back - r) < 0.002)
        }
        #expect(SplitEditorState.ratio(position: 10, total: 0, thickness: 1) == 0.5)
    }

    @Test func sessionRoundTrip() throws {
        let split = SplitEditorState(sideBySide: true, ratio: 0.3, topLine: 412, secondFocused: true)
        let tab = SessionTab(path: "/tmp/a.swift", topLine: 7, folds: [3], split: split)
        let back = try JSONDecoder().decode(SessionTab.self, from: JSONEncoder().encode(tab))
        #expect(back == tab && back.split == split)
        // Unsplit tabs write no split key.
        let plain = String(decoding: try JSONEncoder().encode(SessionTab(path: "/tmp/b.txt")), as: UTF8.self)
        #expect(!plain.contains("split"))
    }

    @Test func olderSessionsStillLoad() throws {
        // A 0.2 session tab (no split key) and a split without the optional focus.
        let old = #"{"id":"\#(UUID().uuidString)","hasBuffer":false,"encoding":"utf8","lineEnding":"lf","selectionLocation":0,"selectionLength":0,"topLine":3,"folds":[1]}"#
        let tab = try JSONDecoder().decode(SessionTab.self, from: Data(old.utf8))
        #expect(tab.split == nil && tab.folds == [1] && tab.topLine == 3)
        let minimal = #"{"sideBySide":false,"ratio":0.5,"topLine":10}"#
        let s = try JSONDecoder().decode(SplitEditorState.self, from: Data(minimal.utf8))
        #expect(s.secondFocused == nil && s.topLine == 10 && !s.sideBySide)
        // A whole session with one split tab.
        let session = Session(windows: [SessionWindow(tabs: [SessionTab(path: "/x", split: s), SessionTab(path: "/y")])])
        let back = try JSONDecoder().decode(Session.self, from: JSONEncoder().encode(session))
        #expect(back.allTabs.map(\.split) == [s, nil])
    }
}
