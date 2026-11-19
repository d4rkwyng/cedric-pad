import Foundation
import Testing
@testable import CedricAI
import CedricCore

@Suite struct AIGrammarTests {
    static var text: NSString { "We was late.\n\nThe trip took longer then I expected. Then we ate." as NSString }

    @Test func findingsBecomeGrammarIssuesAtTheirWords() {
        let raw = #"{"issues":[{"find":"We was","replacement":"We were","why":"Agreement."},{"find":"then I expected","replacement":"than I expected","why":"Comparison."}]}"#
        let results = AIGrammar.parse(raw, text: Self.text)
        #expect(results.count == 2)
        let issues = GrammarMap.issues(results, text: Self.text, offset: 100)
        #expect(issues.count == 2)
        #expect(issues[0].original == "We was" && issues[0].range.location == 100)
        #expect(issues[0].corrections == ["We were"])
        #expect(issues[1].original == "then I expected")
        #expect(issues[1].range.location == 100 + Self.text.range(of: "then I expected").location)
        #expect(issues[1].description == "Comparison.")
        let hint = GrammarMap.hint(issues[1], textStart: 100)
        #expect(GrammarMap.isGrammarHint(hint.id))
        #expect(hint.replacement == "than I expected")
    }

    @Test func unverifiableOrLargeChangesAreDropped() {
        let raw = """
        Sure! {"issues":[
          {"find":"not in the text","replacement":"x y","why":""},
          {"find":"We was","replacement":"We was","why":"same"},
          {"find":"We was late.","replacement":"Our whole team arrived very much later than planned yesterday evening.","why":"rewrite"},
          {"find":"hen","replacement":"when","why":"inside a word"},
          {"find":"line\\nbreak","replacement":"x","why":""}
        ]}
        """
        #expect(AIGrammar.parse(raw, text: Self.text).isEmpty)
        #expect(AIGrammar.parse("no json here", text: Self.text).isEmpty)
        #expect(AIGrammar.verify(find: "their going", replacement: "they're going"))
        #expect(!AIGrammar.verify(find: "a", replacement: "a"))
    }

    @Test func repeatedWordsMapToSuccessiveOccurrences() {
        let t = "it go there and it go back" as NSString
        let raw = #"{"issues":[{"find":"it go","replacement":"it goes","why":""},{"find":"it go","replacement":"it goes","why":""}]}"#
        let r = AIGrammar.parse(raw, text: t)
        #expect(r.count == 2)
        let issues = GrammarMap.issues(r, text: t)
        #expect(issues.map(\.range.location) == [0, 16])
    }

    @Test func fakeEngineAnswersTheGrammarTask() async throws {
        let r = try await AIGrammar.check("The trip took longer then I expected.", engine: FakeChatEngine(delay: 0.001))
        #expect(r.count == 1)
        #expect(r.first?.details.first?.corrections == ["than I expected"])
    }
}
