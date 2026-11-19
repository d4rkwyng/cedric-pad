import Foundation
import Testing
@testable import CedricCore

@Suite struct FoldingTests {
    func scanner(_ language: Language, _ text: String) -> FoldScanner {
        let ns = text as NSString
        let index = LineIndex(ns)
        let fences = FenceIndex()
        return FoldScanner(language: language, text: ns, index: index,
                           inFence: language == .markdown ? { fences.isInFence(ns, index: index, line: $0) } : nil)
    }

    func region(_ language: Language, _ text: String, _ line: Int) -> ClosedRange<Int>? {
        scanner(language, text).region(at: line).map { $0.header...$0.last }
    }

    @Test func kinds() {
        for l in [Language.swift, .javascript, .typescript, .c, .css, .json, .powershell] { #expect(l.foldKind == .brackets) }
        for l in [Language.python, .yaml, .shell] { #expect(l.foldKind == .indentation) }
        #expect(Language.ini.foldKind == .sections)
        #expect(Language.markdown.foldKind == .headings)
        for l in [Language.plain, .csv, .diff, .batch, .registry] {
            #expect(l.foldKind == .none)
            let s = scanner(l, "a {\n  b\n}\n# x\n  y\n")
            #expect(!s.startsRegion(0) && s.region(at: 0) == nil && s.allRegions().isEmpty)
        }
    }

    @Test func bracesIgnoreStringsAndComments() {
        let src = """
        func a() {
            let s = "{ not a brace"
            // { nor this
            /* { nor this */
            if x { y() }
        }
        let t = "}"
        """
        let s = scanner(.swift, src)
        #expect(s.startsRegion(0))
        #expect(!s.startsRegion(1) && !s.startsRegion(2) && !s.startsRegion(3) && !s.startsRegion(4))
        #expect(region(.swift, src, 0) == 0...4)
        // A brace in a string on its own isn't a region either.
        #expect(!scanner(.javascript, "let a = '{'\nlet b = `{`\nx\n").startsRegion(0))
        #expect(region(.javascript, "const r = `{`; f({\n  a: 1,\n})\n", 0) == 0...1)
    }

    @Test func elseChainsAndEmptyRegions() {
        let src = "if a {\n    one()\n} else {\n    two()\n    three()\n}\nfoo(\n)\n"
        #expect(region(.swift, src, 0) == 0...1)
        #expect(region(.swift, src, 2) == 2...4)
        // Closed on the next line: nothing to hide.
        #expect(scanner(.swift, src).startsRegion(6))
        #expect(region(.swift, src, 6) == nil)
        // Allman style: the brace line is the header.
        let allman = "void f()\n{\n    x();\n}\n"
        #expect(region(.c, allman, 0) == nil)
        #expect(region(.c, allman, 1) == 1...2)
    }

    @Test func jsonAndCSS() {
        let json = "{\n  \"a\": [\n    1,\n    2\n  ],\n  \"b{\": {\n    \"c\": 3\n  }\n}\n"
        #expect(region(.json, json, 0) == 0...7)
        #expect(region(.json, json, 1) == 1...3)
        #expect(region(.json, json, 5) == 5...6)
        let css = ".a {\n  color: red;\n}\n/* one\n   two\n*/\n.b { x: y }\n"
        #expect(region(.css, css, 0) == 0...1)
        #expect(region(.css, css, 3) == 3...5)
        #expect(!scanner(.css, css).startsRegion(6))
    }

    @Test func blockComments() {
        let src = "/**\n * Docs\n *\n * more\n */\nint x;\n/* a\n b */ int y;\nint z; /* c\n d */\n"
        let s = scanner(.c, src)
        #expect(s.startsRegion(0))
        #expect(!s.startsRegion(1) && !s.startsRegion(2))
        #expect(region(.c, src, 0) == 0...4) // the closing line holds nothing else: hidden too
        #expect(region(.c, src, 6) == nil) // code after the close: only line 6 left, nothing to hide
        #expect(region(.c, src, 8) == 8...9)
        // Swift's nested comments.
        let sw = "/* a\n /* b */\n c */\nlet x = 1\n"
        #expect(region(.swift, sw, 0) == 0...2)
    }

    @Test func pythonIndentation() {
        let src = """
        def f(x):
            # a comment

            if x:
                return 1
            s = \"\"\"
        text at column zero
        \"\"\"
            return 2

        class C:
            pass
        """
        let s = scanner(.python, src)
        #expect(region(.python, src, 0) == 0...8)
        #expect(region(.python, src, 3) == 3...4)
        #expect(!s.startsRegion(1) && !s.startsRegion(4))
        #expect(region(.python, src, 10) == 10...11)
        let all = s.allRegions().map { [$0.header, $0.last, $0.depth] }
        #expect(all == [[0, 8, 1], [3, 4, 2], [10, 11, 1]])
    }

    @Test func yamlAndShell() {
        let yaml = "a:\n  b: 1\n  text: |\n    line one\n\n    line two\nlist:\n- x\n- y\nz: 2\n"
        #expect(region(.yaml, yaml, 0) == 0...5)
        #expect(region(.yaml, yaml, 2) == 2...5)
        #expect(region(.yaml, yaml, 6) == 6...8)
        #expect(region(.yaml, yaml, 7) == nil)
        let sh = "if true; then\n  echo a\n  echo b\nfi\nf() {\n  x\n}\n"
        #expect(region(.shell, sh, 0) == 0...2)
        #expect(region(.shell, sh, 4) == 4...5)
    }

    @Test func iniSections() {
        let ini = "top=1\n[one]\na=1\nb=2\n\n[two]\nc=3\n"
        #expect(region(.ini, ini, 1) == 1...3)
        #expect(region(.ini, ini, 5) == 5...6)
        #expect(!scanner(.ini, ini).startsRegion(0))
        #expect(scanner(.ini, ini).allRegions().map(\.header) == [1, 5])
    }

    @Test func markdownHeadings() {
        let md = """
        # Title
        intro
        ## One
        text
        ```sh
        # not a heading
        ```

        ## Two
        ### Two.a
        body
        #hashtag
        # Next
        """
        let s = scanner(.markdown, md)
        #expect(!s.startsRegion(5) && !s.startsRegion(11))
        #expect(region(.markdown, md, 0) == 0...11)
        #expect(region(.markdown, md, 2) == 2...6) // the blank line before "## Two" stays
        #expect(region(.markdown, md, 8) == 8...11)
        #expect(region(.markdown, md, 9) == 9...11)
        #expect(region(.markdown, md, 12) == nil)
        let all = s.allRegions().map { [$0.header, $0.last, $0.depth] }
        #expect(all == [[0, 11, 1], [2, 6, 2], [8, 11, 2], [9, 11, 3]])
    }

    @Test func allRegionsMatchSingleRegions() {
        let src = """
        struct A {
            func f() {
                if x {
                    y()
                } else {
                    z()
                }
            }
            /*
             doc
             */
            var v = [
                1,
            ]
        }
        """
        let s = scanner(.swift, src)
        let all = s.allRegions()
        #expect(all.map { [$0.header, $0.last, $0.depth] } == [[0, 13, 1], [1, 6, 2], [2, 3, 3], [4, 5, 3], [8, 10, 2], [11, 12, 2]])
        for r in all { #expect(s.region(at: r.header) == FoldRegion(header: r.header, last: r.last)) }
        // The innermost region holding a line.
        #expect(s.enclosingRegion(of: 3).map(\.header) == 2)
        #expect(s.enclosingRegion(of: 7).map(\.header) == 0)
        #expect(s.enclosingRegion(of: 3, excluding: { $0.header == 2 }).map(\.header) == 1)
    }

    @Test func scanIsBounded() {
        var src = "x = [\n"
        src += String(repeating: "1,\n", count: FoldScanner.scanLimit + 2)
        src += "]\n"
        let s = scanner(.javascript, src)
        #expect(s.startsRegion(0))
        #expect(s.region(at: 0) == nil)
        let small = "x = [\n" + String(repeating: "1,\n", count: 1000) + "]\n"
        #expect(region(.javascript, small, 0) == 0...1000)
    }

    // MARK: FoldState

    @Test func stateFollowsEdits() {
        // "head {\n" (0…6), hidden "a\nb\n" (7…10), "}\n" from 11.
        var st = FoldState([NSRange(location: 7, length: 4)])
        #expect(st.isHidden(7) && st.isHidden(10) && !st.isHidden(6) && !st.isHidden(11))
        // Typing before: shifts.
        let o1 = st.adjust(oldRange: NSRange(location: 0, length: 0), newLength: 2, insertsNewline: false, oldLength: 13)
        #expect(!o1)
        #expect(st.folds == [NSRange(location: 9, length: 4)])
        // Typing at the end of the header line (before its newline): shifts.
        st.adjust(oldRange: NSRange(location: 8, length: 0), newLength: 1, insertsNewline: false, oldLength: 15)
        #expect(st.folds == [NSRange(location: 10, length: 4)])
        // After: unchanged.
        let o2 = st.adjust(oldRange: NSRange(location: 14, length: 1), newLength: 0, insertsNewline: false, oldLength: 16)
        #expect(!o2)
        #expect(st.folds == [NSRange(location: 10, length: 4)])
        // Return at the end of the header line opens it.
        var r = st
        let o3 = r.adjust(oldRange: NSRange(location: 9, length: 0), newLength: 1, insertsNewline: true, oldLength: 16)
        #expect(o3)
        #expect(r.isEmpty)
        // Deleting the header's newline opens it.
        r = st
        let o4 = r.adjust(oldRange: NSRange(location: 9, length: 1), newLength: 0, insertsNewline: false, oldLength: 16)
        #expect(o4)
        // An edit inside opens it.
        r = st
        let o5 = r.adjust(oldRange: NSRange(location: 11, length: 0), newLength: 1, insertsNewline: false, oldLength: 16)
        #expect(o5)
        #expect(r.isEmpty && r.hidden.isEmpty)
        // Appended at the end, where the fold runs to the end: opens.
        var end = FoldState([NSRange(location: 7, length: 3)])
        let o6 = end.adjust(oldRange: NSRange(location: 10, length: 0), newLength: 1, insertsNewline: false, oldLength: 10)
        #expect(o6)
    }

    @Test func nestedFoldsAndUnion() {
        var st = FoldState()
        st.add(NSRange(location: 20, length: 5))
        st.add(NSRange(location: 10, length: 30))
        st.add(NSRange(location: 50, length: 5))
        st.add(NSRange(location: 10, length: 30)) // no duplicate
        #expect(st.folds.count == 3)
        #expect(st.hidden == [NSRange(location: 10, length: 30), NSRange(location: 50, length: 5)])
        st.remove(NSRange(location: 10, length: 30))
        #expect(st.hidden == [NSRange(location: 20, length: 5), NSRange(location: 50, length: 5)])
        // An edit inside the inner fold opens it (and an outer one holding it).
        st.add(NSRange(location: 10, length: 30))
        st.adjust(oldRange: NSRange(location: 22, length: 0), newLength: 1, insertsNewline: false, oldLength: 60)
        #expect(st.folds == [NSRange(location: 51, length: 5)])
    }

    @Test func caretsSkipOrOpen() {
        // "head {\n" hidden "a\nb\n" (7..<11) "}\n"
        let st = FoldState([NSRange(location: 7, length: 4)])
        // → from the header end lands past the fold; ← from after it lands at the header end.
        #expect(st.navigationTarget(7, from: 6, length: 13, endsWithNewline: true) == 11)
        #expect(st.navigationTarget(10, from: 11, length: 13, endsWithNewline: true) == 6)
        #expect(st.navigationTarget(3, from: 2, length: 13, endsWithNewline: true) == 3)
        // A fold running to the end of a text without a final newline: back to the header.
        let end = FoldState([NSRange(location: 7, length: 3)])
        #expect(end.navigationTarget(10, from: 6, length: 10, endsWithNewline: false) == 6)
        // Programmatic moves open the folds they land in, not ones a selection covers.
        #expect(st.foldsToOpen(for: NSRange(location: 8, length: 1), length: 13, endsWithNewline: true) == [NSRange(location: 7, length: 4)])
        #expect(st.foldsToOpen(for: NSRange(location: 0, length: 13), length: 13, endsWithNewline: true).isEmpty)
        #expect(st.foldsToOpen(for: NSRange(location: 2, length: 7), length: 13, endsWithNewline: true) == [NSRange(location: 7, length: 4)])
        #expect(st.foldsToOpen(for: NSRange(location: 11, length: 0), length: 13, endsWithNewline: true).isEmpty)
    }
}
