import Foundation
import Testing
@testable import CedricCore

/// Pack 1: shell. Each rule fires on its bug, stays quiet on near misses
/// (including the same text in a string, a comment or a here-document),
/// and its Fix it gives the right text.
@Suite struct OwlShellRulesTests {
    func find(_ id: String, _ text: String, fileName: String? = "a.sh", facts: OwlDocumentFacts = OwlDocumentFacts()) -> OwlHint? {
        OwlLanguageRulesTests.check(text, language: "shell", fileName: fileName, facts: facts).first { $0.id == id }
    }

    func apply(_ h: OwlHint, to text: String) -> String {
        (text as NSString).replacingCharacters(in: h.range!, with: h.replacement!)
    }

    @Test func crlfScriptAsksForLF() throws {
        let crlf = OwlDocumentFacts(lineEnding: .crlf)
        let h = try #require(find(ShellRules.crlfID, "#!/bin/bash\necho hi\n", facts: crlf))
        #expect(h.kind == .warning && h.replacement == nil && h.range == nil)
        #expect(RulesHintProvider.lineEndingFix(h) == .lf)
        // It replaces the general CRLF note for a script.
        let ids = OwlLanguageRulesTests.check("echo hi\n", language: "shell", fileName: "a.sh", facts: crlf).map(\.id)
        #expect(!ids.contains(RulesHintProvider.crlfID))
        // Not for LF, mixed endings (their own hint), or another language.
        #expect(find(ShellRules.crlfID, "echo hi\n") == nil)
        #expect(find(ShellRules.crlfID, "echo hi\n", facts: OwlDocumentFacts(lineEnding: .crlf, mixedLineEndings: true)) == nil)
        #expect(OwlLanguageRulesTests.check("echo hi\n", language: "batch", fileName: "a.bat", facts: crlf).contains { $0.id == RulesHintProvider.crlfID })
        #expect(RulesHintProvider.lineEndingFix(OwlHint(id: RulesHintProvider.crlfID, kind: .explain, title: "", source: "rules")) == nil)
    }

    @Test func spacesAroundAssignment() throws {
        let text = "#!/bin/sh\nNAME = \"web\"\nif true; then PORT =8080; fi\necho \"$NAME:${PORT}\"\n"
        let h = try #require(find(ShellRules.assignSpacesID, text))
        #expect(h.kind == .fix && h.title.contains("NAME"))
        #expect(apply(h, to: text) == "#!/bin/sh\nNAME=\"web\"\nif true; then PORT=8080; fi\necho \"$NAME:${PORT}\"\n")
        // Never used as $NAME: another language's code (Python, awk) in a here-document the window cut.
        #expect(find(ShellRules.assignSpacesID, "bad = 0\nfor k in x:\n    bad += 1\n") == nil)
        #expect(find(ShellRules.assignSpacesID, "PRE = {\"a\", \"b\"}\necho $PREFIX\n") == nil)
        // Near misses: tests, arithmetic, commands taking "=", strings, comments, here-docs.
        for t in ["[ \"$a\" = b ]\n", "[[ $a = b && c = d ]]\n", "(( a = 1 ))\n", "test $a = b\n", "echo a = b\n", "local a=1\n",
                  "NAME=web\n", "x == y\n", "echo \"NAME = x\"\n", "# NAME = x\n", "cat <<EOF\nNAME = x\nEOF\n",
                  "alias ll = 'ls -l'\n", "  p = os.path.join(root, x)\n", "  len = length(field[1]);\n", "case $a in\n  x) echo;;\nesac\n"] {
            #expect(find(ShellRules.assignSpacesID, t + "echo $NAME $a $x $p $len $ll\n") == nil, "\(t)")
        }
    }

    @Test func bracketsNeedSpaces() throws {
        let text = "if [$a = b ]; then :; fi\nwhile [[ -n \"$x\"]]; do :; done\n"
        let h = try #require(find(ShellRules.testBracketsID, text))
        #expect(apply(h, to: text) == "if [ $a = b ]; then :; fi\nwhile [[ -n \"$x\" ]]; do :; done\n")
        for t in ["if [ \"$a\" = b ]; then :; fi\n", "[[ -f x ]] && echo\n", "case $a in\n  [yY]) echo y;;\nesac\n",
                  "echo ${arr[0]}\n", "x=\"[$a = b]\"\n", "[[ \"$1\" =~ [^[:space:]](.*)? ]]\n", "# if [$a = b]\n", "a[1]=2\n", "ls [abc]*\n"] {
            #expect(find(ShellRules.testBracketsID, t) == nil, "\(t)")
        }
    }

    @Test func pastedQuotesAndDashes() throws {
        let text = "echo “hello”\nls –la\nrsync —delete a b\n"
        let h = try #require(find(ShellRules.pastedID, text))
        #expect(apply(h, to: text) == "echo \"hello\"\nls -la\nrsync --delete a b\n")
        for t in ["echo \"say “hi”\"\n", "# don’t – really\n", "echo don’t\n", "echo a–b\n", "cat <<EOF\n“x” –y\nEOF\n"] {
            #expect(find(ShellRules.pastedID, t) == nil, "\(t)")
        }
    }

    @Test func missingShebangInASavedScript() throws {
        let h = try #require(find(ShellRules.shebangID, "echo hi\n"))
        #expect(h.replacement == "#!/bin/sh\n" && h.range == NSRange(location: 0, length: 0))
        #expect(find(ShellRules.shebangID, "if [[ -n $1 ]]; then echo; fi\n")?.replacement == "#!/bin/bash\n")
        #expect(find(ShellRules.shebangID, "echo hi\n", fileName: "a.zsh")?.replacement == "#!/bin/zsh\n")
        // Not: already there, unsaved, untitled, a dotfile or sourced library, a window, empty, a shellcheck directive.
        #expect(find(ShellRules.shebangID, "#!/bin/sh\necho hi\n") == nil)
        #expect(find(ShellRules.shebangID, "echo hi\n", facts: OwlDocumentFacts(unsavedSince: Date())) == nil)
        #expect(find(ShellRules.shebangID, "echo hi\n", fileName: nil) == nil)
        #expect(find(ShellRules.shebangID, "export A=1\n", fileName: ".bashrc") == nil)
        #expect(find(ShellRules.shebangID, "# Sourced by setup.sh\nA=1\n") == nil)
        #expect(find(ShellRules.shebangID, "echo hi\n", facts: OwlDocumentFacts(isWholeDocument: false)) == nil)
        #expect(find(ShellRules.shebangID, "\n\n") == nil)
        #expect(find(ShellRules.shebangID, "# shellcheck shell=bash\nA=1\n") == nil)
        #expect(find(ShellRules.shebangID, "# Helpers.\nlock() {\n  :\n}\n") == nil)
        #expect(find(ShellRules.shebangID, "function lock {\n  :\n}\n") == nil)
        #expect(find(ShellRules.shebangID, "# Settings.\nARCH=avr\nexport SCRIPT='a\nb'\n") == nil)
        #expect(find(ShellRules.shebangID, "ARCH=avr\necho $ARCH\n") != nil)
        // A fragment for another script: settings and tests, no arguments, no exit.
        #expect(find(ShellRules.shebangID, "case ${target} in\n  arm*) ARCH=arm ;;\nesac\n") == nil)
    }

    @Test func cdWithoutExitBeforeADelete() throws {
        let text = "#!/bin/sh\ncd build\nrm -rf *\n"
        let h = try #require(find(ShellRules.cdID, text))
        #expect(h.kind == .warning && h.title.contains("rm"))
        #expect(apply(h, to: text) == "#!/bin/sh\ncd build || exit 1\nrm -rf *\n")
        let same = "cd \"$dir\"; rm -f *.o\n"
        #expect(apply(try #require(find(ShellRules.cdID, same)), to: same) == "cd \"$dir\" || exit 1; rm -f *.o\n")
        for t in ["cd build || exit\nrm -rf *\n", "cd build && rm -rf *\n", "set -e\ncd build\nrm -rf *\n",
                  "#!/bin/bash -e\ncd build\nrm -rf *\n", "set -euo pipefail\ncd build\nrm -rf *\n", "if cd build; then rm -rf *; fi\n",
                  "cd build\nrm -rf /tmp/x\n", "cd build\nrm -rf \"$OUT\"\n", "cd\nrm -rf x\n", "cd build\nls\n",
                  "echo \"cd build\"\nrm -rf x\n", "# cd build\nrm -rf x\n", "x=$(cd a; pwd)\nrm -rf x\n",
                  "cd a\ncd b || exit\nrm -rf x\n"] {
            #expect(find(ShellRules.cdID, t) == nil, "\(t)")
        }
        // Whole document only: a window can't see `set -e` above it.
        #expect(find(ShellRules.cdID, text, facts: OwlDocumentFacts(isWholeDocument: false)) == nil)
    }

    @Test func unquotedVariablesInRmMvCp() throws {
        let text = "rm -rf $DIR/out\nmv ${SRC} $DEST/*.txt\n"
        let h = try #require(find(ShellRules.unquotedID, text))
        #expect(h.kind == .fix && h.title.contains("$DIR"))
        // Generated autoconf/libtool scripts are left alone.
        #expect(find(ShellRules.unquotedID, text, fileName: "configure") == nil)
        #expect(find(ShellRules.unquotedID, text, fileName: "config.status") == nil)
        #expect(find(ShellRules.unquotedID, "test \"$ac_cv_x\" = y && " + text, fileName: "config-host") == nil)
        #expect(apply(h, to: text) == "rm -rf \"$DIR/out\"\nmv \"${SRC}\" \"$DEST\"/*.txt\n")
        #expect(apply(try #require(find(ShellRules.unquotedID, "sudo cp $1 /tmp\n")), to: "sudo cp $1 /tmp\n") == "sudo cp \"$1\" /tmp\n")
        for t in ["rm -rf \"$DIR/out\"\n", "echo $DIR\n", "rm -f \"${a}\" '$b'\n", "rm -f $# $?\n", "# rm $x\n",
                  "cat <<EOF\nrm $x\nEOF\n", "echo \"rm $x\"\n", "rm -rf /tmp/x\n", "rm -f ${#a}\n"] {
            #expect(find(ShellRules.unquotedID, t) == nil, "\(t)")
        }
        // zsh doesn't split unquoted variables.
        #expect(find(ShellRules.unquotedID, text, fileName: "a.zsh") == nil)
        #expect(find(ShellRules.unquotedID, "#!/bin/zsh\n" + text, fileName: "tool") == nil)
    }
}
