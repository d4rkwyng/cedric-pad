import Foundation
import Testing
@testable import CedricCore

/// Style Check (0.4.0): filler words, redundancies and clichés in prose,
/// offline, off by default, never in code, one hint per phrase.
@Suite struct StyleCheckTests {
    static let on = StyleCheck.Settings()

    func hints(_ text: String, language: String = "markdown", file: String? = "a.md",
               settings: StyleCheck.Settings? = Self.on) -> [OwlHint] {
        let ctx = OwlContext(fileName: file, language: language, text: text, textStart: 0,
                             visibleRange: NSRange(location: 0, length: (text as NSString).length), selection: nil,
                             documentID: UUID(), editGeneration: 1)
        return RulesHintProvider().check(ctx, facts: OwlDocumentFacts(styleCheck: settings)).filter { StyleCheck.isStyleHint($0.id) }
    }

    func apply(_ h: OwlHint, _ text: String) -> String {
        (text as NSString).replacingCharacters(in: h.range!, with: h.replacement!)
    }

    @Test func fillersRedundanciesAndClichesEachWithTheirFix() throws {
        let text = "Basically, we planned it. The past history is very long.\n\nAt the end of the day it worked.\n"
        let hs = hints(text)
        #expect(hs.map(\.id) == ["rules.style.filler:basically", "rules.style.redundancy:past history",
                                 "rules.style.filler:very", "rules.style.cliche:at the end of the day"])
        #expect(apply(hs[0], text).hasPrefix("We planned it."))
        #expect(apply(hs[1], text).contains("The history is"))
        #expect(apply(hs[2], text).contains("is long."))
        #expect(hs[0].kind == .fix && hs[3].kind == .tip && hs[3].replacement == nil)
        #expect(hs[1].title == "“past history” says the same thing twice. Use “history”?")
        #expect(hs[3].detail?.isEmpty == false)
        #expect(StyleCheck.phrase(fromHintID: hs[1].id) == "past history")
        // Mid-sentence, "I think that" is cut without capitalising the next word.
        let mid = "Well, I think that we should go.\n"
        #expect(apply(try #require(hints(mid).first), mid) == "Well, we should go.\n")
        // A filler at the end of a sentence takes the space before it.
        let end = "It was hard really.\n"
        #expect(apply(try #require(hints(end).first), end) == "It was hard.\n")
    }

    @Test func neverInCodeLinksOrDataFiles() {
        let md = "Text.\n\n```\nlet very = basically\n```\n\nUse `really` here. See [docs](https://example.com/very/basically).\n\n    indented very code\n"
        #expect(hints(md).isEmpty)
        #expect(hints("This is very good prose that reads well, and it is really long enough.\n", language: "swift", file: "a.swift").isEmpty)
        #expect(hints("Basically the server was very slow today and we really did not like it at all.\n", language: "plain", file: "server.log").isEmpty)
        #expect(hints("x=1\ny=very\nz=really\nfoo(bar)\n", language: "plain", file: "notes.txt").isEmpty)
        // Plain Text prose is checked.
        let prose = "We were very happy with the trip. The weather was good and the food was great, and we will go back next year.\n"
        #expect(hints(prose, language: "plain", file: "trip.txt").map(\.id) == ["rules.style.filler:very"])
    }

    /// A .log name, and plain text that looks like a log, are not prose, so
    /// Style Check stays quiet. The same sentences in a note are still checked.
    @Test func skipsLogFilesAndLogLikePlainText() {
        let told = "The server was very slow today and we were really unhappy with it. The cache was very cold and the disk was really full.\n"
        #expect(hints(told, language: "plain", file: "server.log").isEmpty)
        #expect(hints(told, language: "plain", file: "notes.txt").contains { $0.id == "rules.style.filler:very" })
        let syslog = """
        Nov 20 08:14:01 host app: The server was very slow today and the cache was really cold.
        Nov 20 08:14:02 host app: We were very happy that it recovered after a long restart.
        Nov 20 08:14:03 host app: The disk was really full and the queue was very long today.
        """
        let tomcat = """
        [20/Nov/2026 08:14:01] INFO The cache was very cold and the disk was really full of old files.
        [20/Nov/2026 08:14:02] ERROR The server was very slow today and we were really stuck for a while.
        """
        // The level is a marker only together with a timestamp at the start of the line.
        let pipes = """
        2026-11-18 08:14:01 app | INFO | The server was very slow today and we were really unhappy with the wait.
        2026-11-18 08:14:02 app | WARN | The cache was very cold and the disk was really full of old files.
        """
        for sample in [syslog, tomcat, pipes] {
            let g = ProseDetector.signals(sample)
            #expect(g.logLines >= 2 && g.readsAsLog, "\(g)")
            #expect(hints(sample, language: "plain", file: "events.txt").isEmpty)
            #expect(hints(sample, language: "plain", file: nil).isEmpty)
        }
    }

    @Test func offByDefaultWithExceptionsAndExtraPhrases() {
        let text = "It is very clear that we must utilize the tools, very much so.\n"
        #expect(hints(text, settings: nil).isEmpty)
        #expect(OwlDocumentFacts().styleCheck == nil)
        let ignored = hints(text, settings: StyleCheck.Settings(exceptions: ["Very"]))
        #expect(!ignored.contains { $0.id.hasSuffix(":very") })
        let extra = hints(text, settings: StyleCheck.Settings(extra: ["utiliz*", "  must  "]))
        #expect(extra.contains { $0.id == "rules.style.filler:utilize" })
        #expect(extra.contains { $0.id == "rules.style.filler:must" })
        // Two of the same phrase: one hint, "and 1 more".
        #expect(hints(text).first { $0.id.hasSuffix(":very") }?.detail?.hasSuffix(" (and 1 more)") == true)
        // A language without a list flags only the user's phrases.
        #expect(hints(text, settings: StyleCheck.Settings(language: "xx")).isEmpty)
    }

    @Test func atMostFiveHintsAfterTheOtherChecks() {
        let text = "# A\n\nSee [b](#nowhere). It was very, really, just, actually, basically, literally and totally fine.\n"
        let all = RulesHintProvider().check(OwlContext(fileName: "a.md", language: "markdown", text: text, textStart: 0,
                                                       visibleRange: NSRange(location: 0, length: 10), selection: nil,
                                                       documentID: UUID(), editGeneration: 1),
                                            facts: OwlDocumentFacts(styleCheck: Self.on))
        let style = all.filter { StyleCheck.isStyleHint($0.id) }
        #expect(style.count == StyleCheck.maxHints)
        #expect(all.first?.id == "rules.md.broken-anchor")
        #expect(all.firstIndex { StyleCheck.isStyleHint($0.id) }! > all.firstIndex { $0.id == "rules.md.broken-anchor" }!)
    }

    @Test func theListsAreWellFormedAndCheckDocumentIncludesThem() {
        #expect(StyleCheck.lists["en"] != nil)
        for (code, list) in StyleCheck.lists {
            #expect(list.language == code)
            let phrases = list.entries.map(\.phrase)
            #expect(Set(phrases).count == phrases.count, "\(code): duplicate phrases")
            for e in list.entries {
                #expect(StyleCheck.normalize(e.phrase) == e.phrase.lowercased(), "\(e.phrase)")
                #expect((e.kind == .cliche) == (e.replacement == nil), "\(e.phrase)")
            }
        }
        #expect(Set(StyleCheck.english.entries.map(\.kind)) == Set(StyleCheck.Kind.allCases))
        let s = OwlDocumentSnapshot(text: "# A\n\nThe end result was fine.\n", generation: 1, fileName: "a.md", language: "markdown",
                                    facts: OwlDocumentFacts(styleCheck: Self.on))
        #expect(OwlChecks.listing(OwlChecks.run(s)).contains("3| style.redundancy:end result: "))
    }
}
