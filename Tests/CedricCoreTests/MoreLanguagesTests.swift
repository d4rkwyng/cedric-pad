import Foundation
import Testing
@testable import CedricCore

@Suite struct MoreLanguagesTests {
    @Test func diff() {
        let s = spans("""
        diff --git a/x.swift b/x.swift
        index 83db48f..bf269f4 100644
        --- a/x.swift
        +++ b/x.swift
        @@ -1,3 +1,3 @@ func f() {
         context
        -old line
        +new line
        \\ No newline at end of file
        """, .diff)
        #expect(s[0].first?.1 == .comment && s[1].first?.1 == .comment)
        #expect(s[2].first! == ("--- a/x.swift", .heading) && s[3].first! == ("+++ b/x.swift", .heading))
        #expect(s[4].first! == ("@@ -1,3 +1,3 @@", .type))
        #expect(s[5].isEmpty)
        #expect(s[6].first! == ("-old line", .keyword) && s[7].first! == ("+new line", .function))
        #expect(s[8].first?.1 == .comment)
    }

    @Test func iniTomlEnv() {
        let k = kinds("""
        ; ini comment
        [server.main] # where
        host = "example.com"
        port: 8080
        debug = true
        trueish = trueish
        export API_URL=${BASE}/v1
        name = 'single' # trailing
        bare-flag
        """, .ini)
        #expect(k["; ini comment"] == .comment)
        #expect(k["[server.main]"] == .tag && k["# where"] == .comment)
        #expect(k["host"] == .key && k["\"example.com\""] == .string)
        #expect(k["port"] == .key && k["8080"] == .number)
        #expect(k["true"] == .constant)
        #expect(k["trueish"] == .key) // the key; the value word isn't a constant
        #expect(k["export"] == .keyword && k["API_URL"] == .key && k["${BASE}"] == .variable)
        #expect(k["'single'"] == .string && k["# trailing"] == .comment)
        #expect(k["bare-flag"] == nil)
    }

    @Test func sql() {
        let k = kinds("""
        SELECT id, COUNT(*) AS n FROM users u -- note
        WHERE u.name LIKE 'a%' AND created > 20 /* c */
        CREATE TABLE t (id INTEGER PRIMARY KEY, v varchar(10) DEFAULT NULL);
        """, .sql)
        #expect(k["SELECT"] == .keyword && k["FROM"] == .keyword && k["WHERE"] == .keyword && k["LIKE"] == .keyword)
        #expect(k["-- note"] == .comment && k["/* c */"] == .comment)
        #expect(k["'a%'"] == .string && k["20"] == .number)
        #expect(k["INTEGER"] == .type && k["varchar"] == .type && k["NULL"] == .constant)
        #expect(k["COUNT"] == .function)
    }

    @Test func xmlIsNotHTML() {
        let s = spans("""
        <?xml version="1.0"?>
        <root><script>not code</script><![CDATA[ raw <x>
        still raw ]]><item a="1"/><!-- c --></root>
        """, .xml)
        let k = Dictionary(s.flatMap { $0 }.map { ($0.0, $0.1) }, uniquingKeysWith: { a, _ in a })
        #expect(k["<?xml"] == .tag && k["version"] == .attribute && k["\"1.0\""] == .string)
        // No embedded JavaScript in XML: "not code" is plain text between tags.
        #expect(s[1].contains { $0.0.hasSuffix("<script>") && $0.1 == .tag })
        #expect(!s[1].contains { $0.0.contains("not") || $0.0 == "code" })
        #expect(k["<![CDATA[ raw <x>"] == .string && k["still raw ]]>"] == .string)
        #expect(k["<item"] == .tag && k["<!-- c -->"] == .comment)
        // HTML still colours its <script> as JavaScript.
        let h = kinds("<script>let a = 1</script>", .html)
        #expect(h["let"] == .keyword)
    }

    @Test func detection() {
        #expect(LanguageDetector.language(forFileName: "a.xml") == .xml)
        #expect(LanguageDetector.language(forFileName: "Info.plist") == .xml)
        #expect(LanguageDetector.language(forFileName: "icon.svg") == .html) // keeps its preview
        #expect(LanguageDetector.language(forFileName: "fix.patch") == .diff)
        #expect(LanguageDetector.language(forFileName: "q.sql") == .sql)
        #expect(LanguageDetector.language(forFileName: "Cargo.toml") == .ini)
        #expect(LanguageDetector.language(forFileName: ".env") == .ini)
        #expect(LanguageDetector.language(forFileName: ".env.local") == .ini)
        #expect(LanguageDetector.language(forFileName: "setup.cfg") == .ini)
        #expect(LanguageDetector.sniff("<?xml version=\"1.0\"?>\n<plist></plist>") == .xml)
        #expect(LanguageDetector.sniff("diff --git a/x b/x\n--- a/x\n+++ b/x\n") == .diff)
        #expect(LanguageDetector.sniff("--- a/x\n+++ b/x\n@@ -1 +1 @@\n") == .diff)
        #expect(LanguageDetector.sniff("--- just a rule\nhello\n") != .diff)
        #expect(Language.sql.commentSyntax == CommentSyntax(line: "--"))
        #expect(Language.xml.commentSyntax?.block?.start == "<!--")
        #expect(Language.diff.commentSyntax == nil && !AutoEdit.pairs(in: .diff))
    }
}
