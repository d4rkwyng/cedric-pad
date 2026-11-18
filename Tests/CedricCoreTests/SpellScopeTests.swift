import Foundation
import Testing
@testable import CedricCore

@Suite struct SpellScopeTests {
    func tokens(_ text: String, _ l: Language) -> (NSString, [Token], NSRange) {
        let ns = text as NSString
        var index = LineIndex()
        _ = index.replace(NSRange(location: 0, length: 0), newLength: ns.length, in: ns)
        let engine = HighlightEngine(language: l)
        return (ns, engine.tokens(forLines: 0..<index.lineCount, in: ns, index: index), NSRange(location: 0, length: ns.length))
    }

    func covered(_ word: String, in text: NSString, _ ranges: [NSRange], occurrence: Int = 0) -> Bool {
        var r = text.range(of: word)
        for _ in 0..<occurrence { r = text.range(of: word, range: NSRange(location: NSMaxRange(r), length: text.length - NSMaxRange(r))) }
        return ranges.contains { $0.location <= r.location && NSMaxRange(r) <= NSMaxRange($0) }
    }

    @Test func swiftChecksCommentsAndStringsNotIdentifiers() {
        let (ns, t, all) = tokens("let mispeled = \"a mispeled string\" // a mispeled comment\n", .swift)
        let scope = SpellScope.ranges(language: .swift, tokens: t, in: all)
        #expect(!covered("mispeled", in: ns, scope))              // the identifier
        #expect(covered("mispeled", in: ns, scope, occurrence: 1)) // in the string
        #expect(covered("mispeled", in: ns, scope, occurrence: 2)) // in the comment
        #expect(!covered("let", in: ns, scope))
    }

    @Test func markdownChecksProseNotCodeOrLinks() {
        let (ns, t, all) = tokens("A sentense with `codde` and [linkk](https://exmple.com) here.\n", .markdown)
        let scope = SpellScope.ranges(language: .markdown, tokens: t, in: all)
        #expect(covered("sentense", in: ns, scope))
        #expect(covered("here", in: ns, scope))
        #expect(!covered("codde", in: ns, scope))
        #expect(!covered("exmple", in: ns, scope))
    }

    @Test func dataFilesAreNeverChecked() {
        for (text, l) in [("{\"naem\": \"vlaue with wrods\"}\n", Language.json), ("naem: vlaue wrods\n", .yaml),
                          ("[sectoin]\nnaem = \"vlaue wrods\"\n", .ini), ("<naem attr=\"vlaue\">wrods here</naem>\n", .xml)] {
            let (_, t, all) = tokens(text, l)
            #expect(SpellScope.ranges(language: l, tokens: t, in: all).isEmpty, "\(l)")
            #expect(!SpellScope.checks(language: l, fileName: nil), "\(l)")
        }
        // CSV and TSV (their own language, or Plain Text by name) are tables of data.
        #expect(SpellScope.isData(.csv))
        #expect(!SpellScope.checks(language: .csv, fileName: "people.csv"))
        #expect(!SpellScope.checks(language: .csv, fileName: nil))
        #expect(!SpellScope.checks(language: .plain, fileName: "people.csv"))
        #expect(!SpellScope.checks(language: .plain, fileName: "Export.TSV"))
        #expect(SpellScope.checks(language: .plain, fileName: "notes.txt"))
        #expect(SpellScope.checks(language: .plain, fileName: nil))
        #expect(SpellScope.checks(language: .swift, fileName: "a.swift"))
        #expect(SpellScope.checks(language: .markdown, fileName: "README.md"))
    }

    @Test func plainTextIsAllProse() {
        let (_, t, all) = tokens("Just some wrods.\n", .plain)
        #expect(SpellScope.ranges(language: .plain, tokens: t, in: all) == [all])
    }

    @Test func fixableIsConservative() {
        let ns = "teh NASA b4 see https://exmple.com/teh mail me@exmple.com ok" as NSString
        func fixable(_ w: String, _ occurrence: Int = 0) -> Bool {
            var r = ns.range(of: w)
            if occurrence > 0 { r = ns.range(of: w, options: .backwards) }
            return SpellScope.isFixable(w, in: ns, at: r)
        }
        #expect(fixable("teh"))
        #expect(!fixable("NASA"))        // all caps
        #expect(!fixable("b4"))          // digits
        #expect(!fixable("teh", 1))      // in a URL
        #expect(!fixable("exmple", 1))   // in an address
    }

    @Test func combinedFixIsOneEdit() {
        let ns = "I beleive teh owl is verry wise." as NSString
        let fixes = [("teh", "the"), ("beleive", "believe"), ("verry", "very")].map { (ns.range(of: $0.0), $0.1) }
        let c = SpellScope.combinedFix(ns, fixes.map { (range: $0.0, replacement: $0.1) })!
        #expect(c.range == NSRange(location: 2, length: ns.range(of: "verry").location + 5 - 2))
        let fixed = ns.replacingCharacters(in: c.range, with: c.replacement)
        #expect(fixed == "I believe the owl is very wise.")
        #expect(SpellScope.combinedFix(ns, []) == nil)
    }
}
