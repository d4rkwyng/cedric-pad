import Foundation
import CoreGraphics
import Testing
@testable import CedricCore

/// Fixes from the build 7 owl test pass (F-H1 … F-L9): each finding as a
/// failing case first.
@Suite struct OwlFixesTests {
    let rules = RulesHintProvider()

    func check(_ text: String, language: String = "plain", fileName: String? = nil,
               facts: OwlDocumentFacts = OwlDocumentFacts()) -> [OwlHint] {
        let ctx = OwlContext(fileName: fileName, language: language, text: text, textStart: 0,
                             visibleRange: NSRange(location: 0, length: 0), selection: nil, documentID: UUID(), editGeneration: 0)
        return rules.check(ctx, facts: facts)
    }

    func find(_ id: String, _ text: String, language: String = "plain", fileName: String? = nil) -> OwlHint? {
        check(text, language: language, fileName: fileName).first { $0.id == id }
    }

    func apply(_ h: OwlHint, to text: String) -> String {
        (text as NSString).replacingCharacters(in: h.range!, with: h.replacement!)
    }

    static let serverLog = (0..<12).map { "2026-11-18T10:00:0\($0 % 10)Z INFO request id=\($0) path=/api/items status=200 dur=\($0)ms" }
        .joined(separator: "\n") + "\n"
    static let email = """
        Hi Sam,

        I was thinking about the trip agian and ofcourse we should go. It definately sounds like the best plan for the summer, \
        and I think the kids would love it. Let me know what you think when you have a minute.

        Thanks,
        Alex
        """

    // MARK: F-H1 the typo offer only in prose

    @Test func typoFixOnlyOffersInProse() {
        #expect(SpellScope.offersTypoFix(Self.email as NSString, language: .plain, fileName: "note.txt"))
        #expect(SpellScope.offersTypoFix(Self.email as NSString, language: .markdown, fileName: nil))
        // Logs, key=value lines, config: never, whatever the name.
        #expect(!SpellScope.offersTypoFix(Self.serverLog as NSString, language: .plain, fileName: "server.log"))
        #expect(!SpellScope.offersTypoFix(Self.serverLog as NSString, language: .plain, fileName: "server.txt"))
        #expect(!SpellScope.offersTypoFix(Self.serverLog as NSString, language: .plain, fileName: nil))
        let kv = (0..<10).map { "setting_\($0)=valeu\($0) # the defualt" }.joined(separator: "\n")
        #expect(!SpellScope.offersTypoFix(kv as NSString, language: .plain, fileName: "app.txt"))
        #expect(!SpellScope.offersTypoFix(Self.email as NSString, language: .plain, fileName: "app.conf"))
        #expect(!SpellScope.offersTypoFix(Self.email as NSString, language: .swift, fileName: "a.swift"))
    }

    // MARK: F-H2 / F-L8 whitespace fixes that would destroy data

    @Test func noTrailingTrimInPatchesLogsOrConfig() {
        let patch = "--- a/x.txt\n+++ b/x.txt\n@@ -1,6 +1,6 @@\n context one  \n context two \n-old line \n+new line \n context three  \n context four \n"
        #expect(find(RulesHintProvider.trailingID, patch, language: "diff", fileName: "fix.patch") == nil)
        #expect(find(RulesHintProvider.trailingID, patch, language: "diff", fileName: nil) == nil)
        // A patch opened as Plain Text by name.
        #expect(find(RulesHintProvider.trailingID, patch, language: "plain", fileName: "fix.diff") == nil)
        let log = (0..<8).map { "10:00:0\($0) INFO line \($0)  " }.joined(separator: "\n")
        #expect(find(RulesHintProvider.trailingID, log, language: "plain", fileName: "server.log") == nil)
        let env = (0..<6).map { "KEY_\($0)=value \n" }.joined()
        #expect(find(RulesHintProvider.trailingID, env, language: "ini", fileName: ".env") == nil)
        // Still offered in ordinary text and code.
        let text = "a  \nb\t\nc \nd   \ne \nf\n"
        #expect(find(RulesHintProvider.trailingID, text) != nil)
        #expect(find(RulesHintProvider.trailingID, text, language: "python", fileName: "a.py") != nil)
    }

    @Test func noIndentOrInvisibleFixesInPatches() {
        // Bytes in a patch are what it matches: a stray BOM or tabs vs
        // spaces in it are the change itself, never something to tidy.
        let patch = "@@ -1,4 +1,4 @@\n\tkeep\n    spaces\n    more\n-old\u{FEFF}line\n+new line\n"
        #expect(!check(patch).map(\.id).filter { [RulesHintProvider.mixedIndentID, RulesHintProvider.invisibleID].contains($0) }.isEmpty)
        let ids = check(patch, language: "diff", fileName: "a.patch").map(\.id)
        #expect(!ids.contains(RulesHintProvider.mixedIndentID))
        #expect(!ids.contains(RulesHintProvider.invisibleID))
        #expect(!ids.contains(RulesHintProvider.trailingID))
    }

    @Test func markdownTrimKeepsHardLineBreaks() throws {
        // "Roses  \nare red" is a hard break: kept. One space, a tab, or two
        // spaces before a blank line or the end are stray: trimmed.
        let md = "Roses are red,  \nviolets are blue. \nOne \nTwo\t\nThree \nFour  \n\nEnd  \n"
        let h = try #require(find(RulesHintProvider.trailingID, md, language: "markdown"))
        #expect(apply(h, to: md) == "Roses are red,  \nviolets are blue.\nOne\nTwo\nThree\nFour\n\nEnd\n")
        // Only hard breaks: nothing to trim.
        let poem = (0..<6).map { "line \($0)  " }.joined(separator: "\n") + "\nlast\n"
        #expect(find(RulesHintProvider.trailingID, poem, language: "markdown") == nil)
    }








}

extension OwlFixesTests {
    @Test func noProseFixesInLogs() {
        let log = "10:00:01 INFO id id=4 the the cache\n10:00:02 INFO ok\n"
        #expect(find(RulesHintProvider.duplicateWordID, log, fileName: "server.log") == nil)
        #expect(find(RulesHintProvider.duplicateWordID, log, fileName: "notes.txt") != nil)
    }
}
