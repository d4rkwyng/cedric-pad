import Foundation
import Testing
@testable import CedricCore

@Suite struct SettingsPanesTests {
    @Test func fourTabsInToolbarOrder() {
        #expect(SettingsPane.allCases == [.general, .editor, .writing, .cedric])
        #expect(Set(SettingsPane.allCases.map(\.symbolName)).count == 4)
    }

    @Test func restoresTheSavedTabElseGeneral() {
        #expect(SettingsPane.restored("writing") == .writing)
        #expect(SettingsPane.restored("cedric") == .cedric)
        #expect(SettingsPane.restored(nil) == .general)
        #expect(SettingsPane.restored("ai") == .general)
        #expect(SettingsPane.restored("") == .general)
    }

    @Test func menuTogglesKeepTheirKeysAndDefaults() {
        // The keys the menus used before 0.4.1: a checkbox must never start a second copy.
        #expect(MenuToggleSetting.allCases.map(\.defaultsKey) == ["wrapLines", "showInvisibles", "showLineNumbers", "highlightOccurrences",
                                                                  "autoCloseBrackets", "checkSpellingWhileTyping", "checkGrammarInProse"])
        #expect(MenuToggleSetting.allCases.filter { !$0.defaultValue } == [.showInvisibles])
    }

    @Test func spellingAndGrammarOnWritingTheRestOnEditor() {
        #expect(MenuToggleSetting.allCases.filter { $0.pane == .writing } == [.checkSpellingWhileTyping, .checkGrammar])
        #expect(MenuToggleSetting.allCases.allSatisfy { $0.pane == .editor || $0.pane == .writing })
    }

    @MainActor @Test func runnerCoalescesToTheNewest() async {
        var seen: [Int] = []
        var gate: CheckedContinuation<Void, Never>?
        let runner = LatestOnlyRunner<Int> { v in
            seen.append(v)
            if v == 1 { await withCheckedContinuation { gate = $0 } }
        }
        runner.submit(1)
        // Let the first one start and park.
        while gate == nil { await Task.yield() }
        runner.submit(2)
        runner.submit(3)
        runner.submit(4)
        #expect(runner.isBusy)
        gate?.resume()
        await runner.idle()
        #expect(seen == [1, 4])
        #expect(!runner.isBusy)
    }

    @MainActor @Test func runnerNeverOverlaps() async {
        var active = 0, maxActive = 0, count = 0
        let runner = LatestOnlyRunner<Int> { _ in
            active += 1; maxActive = max(maxActive, active)
            await Task.yield()
            count += 1
            active -= 1
        }
        for i in 0..<5 {
            runner.submit(i)
            await Task.yield()
        }
        await runner.idle()
        #expect(maxActive == 1)
        #expect(count >= 1 && count <= 5)
    }

    @MainActor @Test func idleReturnsAtOnceWhenNothingRuns() async {
        let runner = LatestOnlyRunner<Int> { _ in }
        #expect(!runner.isBusy)
        await runner.idle()
        runner.submit(7)
        await runner.idle()
        #expect(!runner.isBusy)
    }
}
