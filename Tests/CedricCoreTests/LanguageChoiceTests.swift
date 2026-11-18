import Foundation
import Testing
@testable import CedricCore

@Suite struct LanguageChoiceTests {
    @Test func untitledSniffsWhileAuto() {
        var c = LanguageChoice()
        #expect(c.isAuto && c.language == .plain && c.displayTitle == "Plain Text")
        do { let r = c.textChanged("<html>", isUntitled: true); #expect(r) }
        #expect(c.language == .html && c.displayTitle == "HTML (auto)")
        // Still auto: a paste that is clearly something else switches it.
        do { let r = c.textChanged("{\"a\": 1}", isUntitled: true); #expect(r) }
        #expect(c.language == .json)
        // A half-typed line it can't place doesn't flap back to plain...
        do { let r = c.textChanged("hello", isUntitled: true); #expect(!r) }
        #expect(c.language == .json)
        // ...but emptying the tab does.
        do { let r = c.textChanged("  \n", isUntitled: true); #expect(r) }
        #expect(c.language == .plain)
    }

    @Test func manualPickLocksIt() {
        var c = LanguageChoice()
        c.textChanged("<html>", isUntitled: true)
        c.choose(.plain)
        #expect(c.isManual && c.displayTitle == "Plain Text")
        do { let r = c.textChanged("<!doctype html>\n<html><body><p>hi</p></body></html>", isUntitled: true); #expect(!r) }
        #expect(c.language == .plain)
        // Saving with an extension doesn't override the pick either.
        do { let r = c.saved(fileName: "page.html", content: "<html>"); #expect(!r) }
        #expect(c.language == .plain && c.isManual)
    }

    @Test func savedExtensionDecidesAndStopsSniffing() {
        var c = LanguageChoice()
        c.textChanged("<html>", isUntitled: true)
        do { let r = c.saved(fileName: "notes.md", content: "<html>"); #expect(r) }
        #expect(c.language == .markdown && c.source == .file && c.displayTitle == "Markdown")
        // A file tab no longer sniffs, untitled or not.
        do { let r = c.textChanged("#!/bin/sh\necho hi", isUntitled: false); #expect(!r) }
        do { let r = c.textChanged("#!/bin/sh\necho hi", isUntitled: true); #expect(!r) }
        #expect(c.language == .markdown)
        // Save As with another extension: that one decides.
        do { let r = c.saved(fileName: "notes.py", content: ""); #expect(r) }
        #expect(c.language == .python)
    }

    @Test func savedWithoutExtensionKeepsTheGuess() {
        var c = LanguageChoice()
        c.textChanged("#!/usr/bin/env python3\nprint(1)", isUntitled: true)
        #expect(c.language == .python)
        c.saved(fileName: "script", content: "#!/usr/bin/env python3\nprint(1)")
        #expect(c.language == .python && c.source == .file)
        do { let r = c.textChanged("<html>", isUntitled: true); #expect(!r) }
    }

    @Test func pasteFollowsTheSameRule() {
        // A paste is just a bigger text change: same gate.
        var auto = LanguageChoice()
        do { let r = auto.textChanged("import Foundation\n\nfunc greet() {\n    print(\"hi\")\n}\n", isUntitled: true); #expect(r) }
        #expect(auto.language == .swift)
        var manual = LanguageChoice()
        manual.choose(.markdown)
        do { let r = manual.textChanged("import Foundation\n\nfunc greet() {}\n", isUntitled: true); #expect(!r) }
        #expect(manual.language == .markdown)
    }

    @Test func openedFilesAreFileSourced() {
        let c = LanguageChoice.forFile(named: "a.swift", content: "<html>")
        #expect(c.language == .swift && c.source == .file && c.displayTitle == "Swift")
        let u = LanguageChoice.untitled(content: "<html>")
        #expect(u.isAuto && u.language == .html)
    }
}

/// Markdown from typed content (Derek, 2026-11-17: his four lines stayed Plain Text).
@Suite struct MarkdownSniffTests {
    @Test func ownersTypedMarkdown() {
        #expect(LanguageDetector.sniff("# Title\n## Sub Title\n**Test**\nTesting markdown\n") == .markdown)
        // Every prefix he typed after the second heading is Markdown too.
        #expect(LanguageDetector.sniff("# Title\n## Sub Title\n**Test**") == .markdown)
        var c = LanguageChoice()
        let r = c.textChanged("# Title\n## Sub Title\n**Test**\nTesting markdown\n", isUntitled: true)
        #expect(r && c.displayTitle == "Markdown (auto)")
    }

    @Test func otherMarkdownSignals() {
        #expect(LanguageDetector.sniff("Some notes\n\n- one\n- two\n\nSee [the docs](https://example.com).\n") == .markdown)
        #expect(LanguageDetector.sniff("> quoted\n\n1. first\n2. second\n") == .markdown)
        #expect(LanguageDetector.sniff("Text\n\n```\ncode\n```\n") == .markdown)
    }

    @Test func oneSignalIsNotEnough() {
        #expect(LanguageDetector.sniff("# just a heading\n") == .plain)
        #expect(LanguageDetector.sniff("- a dash line\nmore text\n") == .plain)
    }

    @Test func shellCommentsAreNotMarkdown() {
        let sh = "# build it\n# then test it\nset -e\nif [ -f Makefile ]; then\n  make\nfi\necho \"done $HOME\"\n"
        #expect(LanguageDetector.sniff(sh) == .shell)
    }

    @Test func yamlListsAreYAML() {
        let yaml = "# config\nname: cedric\nitems:\n  - one\n  - two\n  - three\nversion: 2\n"
        #expect(LanguageDetector.sniff(yaml) == .yaml)
    }
}
