import Foundation
import Testing
@testable import CedricCore

/// Pack 5: Markdown and CSV. Fires, near misses (code, comments), fix.
@Suite struct OwlMarkdownRulesTests {
    func find(_ id: String, _ text: String, language: String = "markdown", fileName: String = "README.md",
              facts: OwlDocumentFacts = OwlDocumentFacts()) -> OwlHint? {
        OwlLanguageRulesTests.check(text, language: language, fileName: fileName, facts: facts).first { $0.id == id }
    }

    func apply(_ h: OwlHint, to text: String) -> String {
        (text as NSString).replacingCharacters(in: h.range!, with: h.replacement!)
    }

    func range(_ h: OwlHint, in text: String) -> String { (text as NSString).substring(with: h.range!) }

    // MARK: Markdown

    @Test func unclosedCodeFence() throws {
        let text = "# Title\n\n```swift\nlet a = 1\n```\n\nText.\n\n~~~~\ncode\n~~~\nmore\n"
        let h = try #require(find(MarkdownRules.fenceID, text))
        #expect(h.kind == .warning && h.replacement == nil)
        #expect(range(h, in: text) == "~~~~")
        #expect(h.title.contains("line 9"))
        // Closed ones, longer closers, inline triple backticks, a quote's fence: quiet.
        for t in ["```\na\n```\n", "````\n```\nnot a closer inside\n````\n", "Use ```code``` inline.\n", "> ```\n> a\n> ```\n",
                  "~~~\na\n~~~~~\n", "- item\n\n    ```sh\n    x\n    ```\n", "<!--\n```\n-->\ntext\n", "```sh\r\nls\r\n```\r\n"] {
            #expect(find(MarkdownRules.fenceID, t) == nil, "\(t)")
        }
        // A window of a longer file can't tell: whole document only.
        #expect(find(MarkdownRules.fenceID, "```\nopen\n", facts: OwlDocumentFacts(isWholeDocument: false)) == nil)
    }

    @Test func brokenAnchorLink() throws {
        let text = "# Install\n\nSee [setup](#instal) and [use](#usage).\n\n## Usage\n"
        let h = try #require(find(MarkdownRules.anchorID, text))
        #expect(h.kind == .fix && h.title.contains("#install"))
        #expect(apply(h, to: text) == "# Install\n\nSee [setup](#install) and [use](#usage).\n\n## Usage\n")
        // Nothing close: a warning.
        let w = try #require(find(MarkdownRules.anchorID, "# Intro\n\n[x](#troubleshooting)\n"))
        #expect(w.kind == .warning && w.replacement == nil)
        let ok = [
            "# Getting Started!\n\n[go](#getting-started)\n",                  // GitHub slug
            "# Getting Started\n\n[go](#gettingstarted)\n",                    // another renderer's slug
            "# A\n# A\n\n[second](#a-1)\n",                                    // repeats
            "# Intro\n\n<a name=\"faq\"></a>\n[faq](#faq)\n",                  // explicit anchors
            "# Intro {#start}\n\n[s](#start)\n",
            "# Intro\n\n[top](#top) `[x](#nope)`\n",                           // #top, code
            "# Intro\n\n```\n[x](#nope)\n```\n",
            "# Intro\n\n<!-- [x](#nope) -->\n",
            "# {{ title }}\n\n[x](#nope)\n",                                   // templated
            "No headings at all.\n\n[x](#generated)\n",
            "Install\n=======\n\n[i](#install)\n",                             // setext
            "# Use `brew` [here](https://x)\n\n[u](#use-brew-here)\n",
        ]
        for t in ok { #expect(find(MarkdownRules.anchorID, t) == nil, "\(t)") }
    }

    @Test func brokenRelativeLink() throws {
        let probe = OwlFileProbe.set(["docs/guide.md", "img/logo.png", "page.md"])
        let facts = OwlDocumentFacts(fileExists: probe)
        let text = "# A\n\n![logo](img/logo.png) ![shot](img/shot.png)\n[guide](docs/guide.md#start)\n"
        let h = try #require(find(MarkdownRules.relativeLinkID, text, facts: facts))
        #expect(h.kind == .warning && h.replacement == nil)
        #expect(range(h, in: text) == "img/shot.png" && h.title.contains("image"))
        let link = try #require(find(MarkdownRules.relativeLinkID, "See [x](docs/gide.md).\n<img src=\"a b.png\">\n", facts: facts))
        #expect(link.title == "No file at “docs/gide.md”.")
        for t in ["[a](https://example.com/x.md) [m](mailto:a@b.c) [h](#here) [r](/root/abs.md)\n",
                  "[g](docs/guide.md) [p](page.html) [p2](page) ![l](<img/logo.png> \"Logo\")\n",
                  "`[x](missing.md)`\n", "```\n[x](missing.md)\n```\n", "<!-- [x](missing.md) -->\n",
                  "[x]({{ site.url }}/missing.md)\n", "[g](docs/guide.md?plain=1)\n"] {
            #expect(find(MarkdownRules.relativeLinkID, t, facts: facts) == nil, "\(t)")
        }
        // No folder (untitled), or the probe doesn't know yet: quiet.
        #expect(find(MarkdownRules.relativeLinkID, text) == nil)
        let unknown = OwlDocumentFacts(fileExists: OwlFileProbe { _ in nil })
        #expect(find(MarkdownRules.relativeLinkID, text, facts: unknown) == nil)
        // Encoded spaces are decoded; a reference definition counts.
        #expect(find(MarkdownRules.relativeLinkID, "[r]: notes%20old.md\n", facts: facts) != nil)
        // In an Obsidian vault or a Quartz site, a bare name is found anywhere: quiet.
        let vault = OwlDocumentFacts(fileExists: OwlFileProbe.set(["../.obsidian"]))
        #expect(find(MarkdownRules.relativeLinkID, "![](logo.png) [x](a/missing.md)\n", facts: vault)?.title == "No file at “a/missing.md”.")
        // GitHub's own pages and generated HTML aren't files here.
        #expect(find(MarkdownRules.relativeLinkID, "[i](../../issues/new) [api](../api/struct.Box.html)\n", facts: facts) == nil)
    }

    // MARK: CSV

    @Test func csvUnclosedQuote() throws {
        let text = "name,note\nann,\"fine\"\nbob,\"never closes\ncid,x\n"
        let h = try #require(find(DataRules.csvQuoteID, text, language: "csv", fileName: "a.csv"))
        #expect(h.kind == .warning && h.title.contains("line 3"))
        #expect(range(h, in: text) == "bob,\"never closes")
        for t in ["a,b\n\"x, y\",2\n\"multi\nline\",3\n", "a,b\n5\" pipe,2\n", "a,b\n\"say \"\"hi\"\"\",1\n"] {
            #expect(find(DataRules.csvQuoteID, t, language: "csv", fileName: "a.csv") == nil, "\(t)")
        }
    }

    @Test func csvRaggedRows() throws {
        let text = "a,b,c\n1,2,3\n4,5,6\n7,8,9,10\n11,12,13\n"
        let h = try #require(find(DataRules.csvRaggedID, text, language: "csv", fileName: "a.csv"))
        #expect(h.title == "Row on line 4 has 4 fields, not 3.")
        #expect(range(h, in: text) == "7,8,9,10")
        // TSV, by name.
        #expect(find(DataRules.csvRaggedID, "a\tb\n1\t2\n3\t4\n5\n6\t7\n", language: "csv", fileName: "a.tsv") != nil)
        for t in ["a,b,c\n1,2,3\n\"x,y\",2,3\n4,5,6\n",           // a quoted comma
                  "a,b\n1,2\n",                                     // too few rows
                  "a,b,c\n1,2,3\n\n4,5,6\n7,8,9\n",                 // blank lines
                  "# comment, here\na,b,c\n1,2,3\n4,5,6\n",          // comment line
                  "a,b\n1,2,3\n1\n1,2,3,4\n1,2\n",                  // mostly ragged: not a table
                  "a,b,c\n\"q\nr\",2,3\n4,5,6\n7,8,9\n"] {         // a field over two lines
            #expect(find(DataRules.csvRaggedID, t, language: "csv", fileName: "a.csv") == nil, "\(t)")
        }
        // A window with quotes may start inside a field: quiet; without quotes, rows are lines.
        let win = OwlDocumentFacts(isWholeDocument: false)
        #expect(find(DataRules.csvRaggedID, "x\"\n1,2,3\n4,5,6\n7,8,9,0\n1,2,3\n1,2,3\n", language: "csv", fileName: "a.csv", facts: win) == nil)
        #expect(find(DataRules.csvRaggedID, "9,9\n1,2,3\n4,5,6\n7,8,9,0\n1,2,3\n1,2,3\n", language: "csv", fileName: "a.csv", facts: win) != nil)
    }
}
