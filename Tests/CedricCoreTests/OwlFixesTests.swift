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











}
