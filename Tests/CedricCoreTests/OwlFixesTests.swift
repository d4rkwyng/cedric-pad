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

    // MARK: F-L2 doubled words

    @Test func doubledWordRunsCollapse() throws {
        let h = try #require(find(RulesHintProvider.duplicateWordID, "And that was the the the end.\n"))
        #expect(apply(h, to: "And that was the the the end.\n") == "And that was the end.\n")
        #expect(h.title == "“the the the”? A word typed twice. Fix it?")
        let two = try #require(find(RulesHintProvider.duplicateWordID, "the the the end and a a cat"))
        #expect(apply(two, to: "the the the end and a a cat") == "the end and a cat")
        // Runs of words meant more than once stay alone.
        #expect(find(RulesHintProvider.duplicateWordID, "Ha ha ha, very very funny.") == nil)
        #expect(find(RulesHintProvider.duplicateWordID, "Tra la la la, she sang.") == nil)
    }

    @Test func romanceArticlesTypedTwice() throws {
        let es = "Nos vemos por la la tarde en el parque."
        let h = try #require(find(RulesHintProvider.duplicateWordID, es))
        #expect(apply(h, to: es) == "Nos vemos por la tarde en el parque.")
        for s in ["Vamos a la la playa.", "Ci vediamo con la la mamma.", "Vou para la la casa."] {
            #expect(find(RulesHintProvider.duplicateWordID, s) != nil, "\(s)")
        }
        for s in ["El el perro.", "Los los niños juegan.", "Con il il gatto."] {
            #expect(find(RulesHintProvider.duplicateWordID, s) != nil, "\(s)")
        }
        // Singing stays alone.
        for s in ["She sang la la la all day.", "Tra la la!", "La la land is a film.", "And la la, off she went."] {
            #expect(find(RulesHintProvider.duplicateWordID, s) == nil, "\(s)")
        }
    }

    // MARK: F-M9 Show Me on a doubled word

    @Test func doubledWordFocusSelectsTheWords() throws {
        let text = "I went to the the shop and saw a a cat."
        let h = try #require(find(RulesHintProvider.duplicateWordID, text))
        let focus = try #require(RulesHintProvider.doubledWordFocus(text as NSString, hintRange: h.range!))
        #expect((text as NSString).substring(with: focus) == "the the")
        let run = "Then the the the end."
        let h2 = try #require(find(RulesHintProvider.duplicateWordID, run))
        let f2 = try #require(RulesHintProvider.doubledWordFocus(run as NSString, hintRange: h2.range!))
        #expect((run as NSString).substring(with: f2) == "the the the")
        // Across a line break.
        let nl = "It was the\nthe end of it."
        let h3 = try #require(find(RulesHintProvider.duplicateWordID, nl))
        let f3 = try #require(RulesHintProvider.doubledWordFocus(nl as NSString, hintRange: h3.range!))
        #expect((nl as NSString).substring(with: f3) == "the\nthe")
        #expect(RulesHintProvider.doubledWordFocus("no doubles" as NSString, hintRange: NSRange(location: 2, length: 3)) == nil)
    }

    // MARK: F-L1 the letter easter egg needs a letter

    @Test func letterNeedsLetterStructure() {
        #expect(!RulesHintProvider.isLetter("Dear diary,\nToday was long.\nI walked to town.\nThe end.\n"))
        #expect(!RulesHintProvider.isLetter("Dear Diary\n\nWent out.\nCame back.\n"))
        // A greeting and nothing else letter-like: not yet.
        #expect(!RulesHintProvider.isLetter("Dear Sam,\n\nI write\nto say\n"))
        #expect(RulesHintProvider.isLetter("Dear Sam,\n\nI write to say thanks.\nIt was lovely.\n\nBest regards,\nAlex\n"))
        #expect(RulesHintProvider.isLetter("Dear Mrs Patel,\n\nThank you for your letter.\nI agree.\n\nYours sincerely,\nJo\n"))
        // Address lines before the greeting.
        #expect(RulesHintProvider.isLetter("12 High Street\nLeeds LS1 4AB\n\n3 May 2026\n\nDear Sir or Madam,\n\nI write about my order.\n"))
        #expect(!RulesHintProvider.isLetter("Shopping\n\nDear me, what a list.\nmilk\neggs\n"))
    }

    // MARK: F-M6 JSON trailing comma, in plain words

    @Test func jsonTrailingCommaNamesItsLine() throws {
        let text = "{\n  \"name\": \"cedric\",\n  \"scripts\": {\n    \"build\": \"swift build\"\n  },\n}\n"
        let h = try #require(find(RulesHintProvider.jsonInvalidID, text, language: "json", fileName: "package.json"))
        #expect(h.title == "Extra comma at the end of line 5.")
        #expect((text as NSString).substring(with: h.range!) == ",")
        #expect(h.detail?.contains("parser") == false)
        let arr = "[\n  1,\n  2,\n]\n"
        let a = try #require(find(RulesHintProvider.jsonInvalidID, arr, language: "json", fileName: "a.json"))
        #expect(a.title == "Extra comma at the end of line 3.")
        // Other errors still name the line they're on.
        let other = "{\n  \"a\": 1\n  \"b\": 2\n}\n"
        let o = try #require(find(RulesHintProvider.jsonInvalidID, other, language: "json", fileName: "a.json"))
        #expect(o.title.contains("line 3"))
    }

    // MARK: F-M8 binary files

    @Test func binaryDetection() {
        let bytes = Data((0..<4).flatMap { _ in (0...255).map { UInt8($0) } })
        #expect(TextCodec.looksBinary(bytes))
        #expect(TextCodec.looksBinary(Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0x0D, 0x49, 0x48, 0x44, 0x52])))
        // Control characters without NULs (most of a sample).
        #expect(TextCodec.looksBinary(Data((0..<400).map { UInt8([1, 2, 3, 4, 5, 6, 0x41, 0x7F][$0 % 8]) })))
        // Text, in any encoding Cedric reads.
        #expect(!TextCodec.looksBinary(Data("Hello, world\n\tindented\r\n".utf8)))
        #expect(!TextCodec.looksBinary(Data()))
        #expect(!TextCodec.looksBinary(Data([0xFF, 0xFE]) + "héllo wörld".data(using: .utf16LittleEndian)!))
        #expect(!TextCodec.looksBinary(Data([0xFE, 0xFF]) + "héllo wörld".data(using: .utf16BigEndian)!))
        #expect(!TextCodec.looksBinary("plain ascii text, no BOM, long enough to tell".data(using: .utf16BigEndian)!))
        #expect(!TextCodec.looksBinary("plain ascii text, no BOM, long enough to tell".data(using: .utf16LittleEndian)!))
        #expect(!TextCodec.looksBinary("Caf\u{E9} na\u{EF}ve".data(using: .isoLatin1)!))
        #expect(!TextCodec.looksBinary("don’t – “quote”".data(using: .macOSRoman)!))
        // A form feed or an escape now and then (ANSI colours in a log) is still text.
        #expect(!TextCodec.looksBinary(Data(String(repeating: "\u{1B}[31mred\u{1B}[0m line\n\u{0C}", count: 30).utf8)))
        // Only the first 8 KB are read.
        #expect(!TextCodec.looksBinary(Data(String(repeating: "a", count: 9000).utf8) + Data([0, 0, 0])))
    }

    // MARK: F-L4 the bubble stays off the hinted lines

    @Test func bubbleAvoidsTheHintedLines() {
        let editor = CGRect(x: 0, y: 0, width: 360, height: 240)
        let owl = CGRect(x: 300, y: 2, width: 54, height: 54)
        let size = CGSize(width: 200, height: 90)
        // Lines 3-6 of a small window, right where the bubble would go (above him).
        let hinted = CGRect(x: 0, y: 60, width: 360, height: 70)
        let plain = OwlPlacement.bubble(owl: owl, size: size, in: editor)
        #expect(plain.frame.intersects(hinted)) // the finding
        let away = OwlPlacement.bubble(owl: owl, size: size, in: editor, avoid: hinted)
        #expect(!away.frame.intersects(hinted))
        #expect(editor.contains(away.frame))
        // Nothing to avoid, or no way round it: as before.
        #expect(OwlPlacement.bubble(owl: owl, size: size, in: editor, avoid: nil) == plain)
        let everything = CGRect(x: 0, y: 0, width: 360, height: 240)
        #expect(OwlPlacement.bubble(owl: owl, size: size, in: editor, avoid: everything) == plain)
    }

}

extension OwlFixesTests {
    @Test func noProseFixesInLogs() {
        let log = "10:00:01 INFO id id=4 the the cache\n10:00:02 INFO ok\n"
        #expect(find(RulesHintProvider.duplicateWordID, log, fileName: "server.log") == nil)
        #expect(find(RulesHintProvider.duplicateWordID, log, fileName: "notes.txt") != nil)
    }
}
