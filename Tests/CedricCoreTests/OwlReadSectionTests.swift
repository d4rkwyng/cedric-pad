import Foundation
import Testing
@testable import CedricCore

/// read_section (0.4.0): a Markdown section by its heading name, matched
/// loosely, with the headings when nothing matches, and capped output.
@Suite struct OwlReadSectionTests {
    static let doc = """
    # Guide

    Intro text.

    ## Installation

    Download it.

    ### From source

    Build it.

    ## Usage

    Open a file.

    """

    func snap(_ text: String = Self.doc, language: String = "markdown", file: String = "guide.md") -> OwlDocumentSnapshot {
        OwlDocumentSnapshot(text: text, generation: 1, fileName: file, language: language)
    }

    func read(_ heading: String, _ s: OwlDocumentSnapshot? = nil) -> OwlToolResult {
        OwlTools.run(OwlToolCall(name: "read_section", arguments: .object(["heading": .string(heading)])), on: s ?? snap())
    }

    @Test func readsTheSectionWithItsSubsectionsUpToTheNextSibling() {
        let r = read("Installation")
        #expect(r.ok)
        #expect(r.text.hasPrefix("Section (lines 5-11):\n5| ## Installation"))
        #expect(r.text.contains("11| Build it."))
        #expect(!r.text.contains("## Usage"))
        #expect(r.lines == 5...11)
        #expect(r.summary == "Read the section “Installation”")
    }

    @Test func aCloseMatchIsEnough() {
        for q in ["installation", "## Installation", "the Instalation section", "install", "INSTALLATION"] {
            #expect(read(q).text.hasPrefix("Section (lines 5-11)"), "\(q)")
        }
        #expect(read("source").text.hasPrefix("Section (lines 9-11)"))
        #expect(read("usage section").lines == 13...15)
    }

    @Test func noMatchListsTheHeadingsAndOtherDocumentsSaySo() {
        let r = read("Pricing")
        #expect(r.ok)
        #expect(r.text.hasPrefix("No heading matches “Pricing”. The headings are:\n1| # Guide\n5| ## Installation"))
        #expect(read("Intro", snap("Just text.\n")).text.hasPrefix("This document has no headings"))
        #expect(!read("main", snap("func main() {}\n", language: "swift", file: "a.swift")).ok)
        #expect(!OwlTools.run(OwlToolCall(name: "read_section"), on: snap()).ok)
    }

    @Test func aLongSectionIsCappedAndSaysWhereTheRestIs() {
        var text = "# Big\n\n"
        for i in 1...300 { text += "Line \(i) of the big section with some words.\n" }
        text += "# Next\n"
        let r = read("big", snap(text))
        #expect(r.text.utf8.count <= OwlTools.maxOutputBytes)
        #expect(r.text.contains("[… cut: the section goes on to line 302; call get_lines from line"))
        let shown = try! #require(r.lines)
        #expect(shown.lowerBound == 1 && shown.upperBound < 302)
        #expect(r.text.contains("\(shown.upperBound)| "))
    }

    @Test func offeredOnlyForMarkdownQuestionsAboutASection() {
        #expect(OwlTools.typedTools(question: "What does the Usage section say?", snapshot: snap()).contains(.readSection))
        #expect(OwlTools.typedTools(question: "Tell me about installation", snapshot: snap()).contains(.readSection))
        #expect(!OwlTools.typedTools(question: "What is 12 times 7?", snapshot: snap()).contains(.readSection))
        #expect(!OwlTools.typedTools(question: "What does the section say?", snapshot: snap("No headings.\n")).contains(.readSection))
        #expect(!OwlTools.typedTools(question: "Which section is main in?", snapshot: snap("func main() {}\n", language: "swift", file: "a.swift")).contains(.readSection))
    }
}
