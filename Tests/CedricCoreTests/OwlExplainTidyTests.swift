import Foundation
import Testing
@testable import CedricCore

/// Pack 8: explain & tidy. The regex explainer, the decoders, Find TODOs,
/// .editorconfig and the first style rules.
@Suite struct OwlExplainTidyTests {
    func find(_ id: String, _ text: String, language: String, fileName: String,
              facts: OwlDocumentFacts = OwlDocumentFacts()) -> OwlHint? {
        OwlLanguageRulesTests.check(text, language: language, fileName: fileName, facts: facts).first { $0.id == id }
    }

    func apply(_ h: OwlHint, to text: String) -> String {
        (text as NSString).replacingCharacters(in: h.range!, with: h.replacement!)
    }

    // MARK: Explain Regex

    @Test func regexBreakdown() {
        let e = RegexExplain.explain(#"^(\d{3})-?(?<word>\w+)[^a-z_]*$"#)
        #expect(e.warnings.isEmpty)
        let tokens = e.parts.map(\.token)
        #expect(tokens == ["^", "(", "\\d", "{3}", ")", "-", "?", "(?<word>", "\\w", "+", ")", "[^a-z_]", "*", "$"])
        #expect(e.parts[1].meaning == "group 1 (captured)" && e.parts[7].meaning.contains("named “word”"))
        #expect(e.parts[2].depth == 1 && e.parts[3].depth == 2 && e.parts[3].meaning == "exactly 3 times")
        #expect(e.parts[11].meaning == "one character that is not: “a” to “z”, “_”")
        #expect(e.text.contains("\\d  a digit (0–9)"))
        // A JS literal's flags; lazy and possessive; lookaround; backrefs.
        let js = RegexExplain.explain("/(?=a)b+?c{2,}\\1/gi")
        #expect(js.pattern == "(?=a)b+?c{2,}\\1")
        #expect(js.parts.contains { $0.token == "+?" && $0.meaning.contains("lazy") })
        #expect(js.parts.contains { $0.token == "{2,}" && $0.meaning == "2 or more times" })
        #expect(js.parts.contains { $0.token == "\\1" && $0.meaning.contains("group 1") })
        #expect(js.parts.last?.meaning.contains("ignore case") == true)
        // Catastrophic nesting is warned about; unclosed groups and sets too.
        #expect(!RegexExplain.explain("(a+)+$").warnings.isEmpty)
        #expect(!RegexExplain.explain("(\\w*\\s?)*x").warnings.isEmpty)
        #expect(RegexExplain.explain("(ab)+").warnings.isEmpty)
        #expect(!RegexExplain.explain("(ab").warnings.isEmpty && !RegexExplain.explain("[ab").warnings.isEmpty)
    }

    @Test func whichSelectionsLookLikeARegex() {
        for r in [#"^\d+$"#, "/ab+c/i", #"[A-Z]\w*"#, #"(foo|bar)\.txt"#] { #expect(RegexExplain.looksLikeRegex(r), "\(r)") }
        for t in ["hello world", "a+b", "Price: $5", "(see above)", "line one\nline two", "[unclosed"] {
            #expect(!RegexExplain.looksLikeRegex(t), "\(t)")
        }
    }

    // MARK: Decode Selection

    static func b64url(_ s: String) -> String {
        Data(s.utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    @Test func decodesAJWTWithoutCheckingIt() throws {
        let now = Date(timeIntervalSince1970: 1_763_560_000)
        let token = Self.b64url(#"{"alg":"HS256","typ":"JWT"}"#) + "." + Self.b64url(#"{"sub":"42","exp":1763556400}"#) + ".c2lnbmF0dXJl"
        let r = try #require(Decode.decode("Bearer " + token, now: now, timeZone: TimeZone(identifier: "UTC")!))
        #expect(r.kind == .jwt && r.title == "JWT (expired)")
        #expect(r.body.contains("\"alg\" : \"HS256\"") && r.body.contains("\"sub\" : \"42\""))
        #expect(r.body.contains("Expires:") && r.body.contains("signature is not checked"))
        #expect(!r.body.contains("c2lnbmF0dXJl"))
        // Not a JWT: two parts, or a header that isn't JSON.
        #expect(Decode.decode("eyJhbGciOi.eyJzdWIi", now: now)?.kind != .jwt)
        #expect(Decode.decode("a.b.c", now: now) == nil)
    }

    @Test func decodesBase64AndTimestamps() throws {
        let now = Date(timeIntervalSince1970: 1_763_560_000)
        let utc = TimeZone(identifier: "UTC")!
        let b = try #require(Decode.decode("SGVsbG8sIE93bGluayE=", now: now, timeZone: utc))
        #expect(b.kind == .base64 && b.body == "Hello, Owlink!")
        #expect(try #require(Decode.decode(Self.b64url("a?b>c~~"), now: now))?.body == "a?b>c~~")
        let t = try #require(Decode.decode("1763560000", now: now, timeZone: utc))
        #expect(t.kind == .timestamp && t.body.contains("UTC: 2025-11-19T13:46:40Z"))
        let ms = try #require(Decode.decode("1763560000123", now: now, timeZone: utc))
        #expect(ms.title.contains("milliseconds") && ms.body.contains(".123Z"))
        // Words, numbers that aren't times, binary: nothing.
        for s in ["password", "12345", "99999999999", "Hello World", "AAAAAAAA", "/////w=="] {
            #expect(Decode.decode(s, now: now) == nil, "\(s)")
        }
    }

    // MARK: Find TODOs

    @Test func findTodosInCommentsOnly() {
        let swift = "let todo = \"TODO: not this\"\n// TODO: fix the cache\n/* FIXME(derek): later */\nlet XXX = 1\n"
        let items = Todos.find(swift, language: "swift")
        #expect(items.map(\.line) == [2, 3])
        #expect(items[0].tag == "TODO" && items[0].text == "fix the cache")
        #expect(items[1].tag == "FIXME" && items[1].text == "later")
        let sh = "echo TODO\n# HACK: works around #12\n"
        #expect(Todos.find(sh, language: "shell").map(\.tag) == ["HACK"])
        let yaml = "key: TODO\n# TODO: real one\n"
        #expect(Todos.find(yaml, language: "yaml").map(\.line) == [2])
        let md = "# Notes\n\nTODO: write the intro\n- FIXME the list\nThe word TODO in a sentence.\n"
        #expect(Todos.find(md, language: "markdown").map(\.line) == [3, 4])
        #expect(Todos.find("nothing here\n", language: "plain").isEmpty)
    }

    // MARK: .editorconfig

    @Test func editorConfigParsesAndMatchesGlobs() {
        let root = EditorConfig.parse("root = true\n\n[*]\nindent_style = space\nindent_size = 4\ninsert_final_newline = true\n\n[*.{md,txt}]\ntrim_trailing_whitespace = false\n\n[Makefile]\nindent_style = tab\n\n[lib/**.js]\nindent_size = 2\n")
        #expect(root.root && root.sections.count == 4)
        let md = EditorConfig.values(for: ["docs/a.md"], configs: [root])
        #expect(md == EditorConfig.Values(indentStyle: .space, indentSize: 4, insertFinalNewline: true, trimTrailingWhitespace: false))
        #expect(EditorConfig.values(for: ["Makefile"], configs: [root]).indentStyle == .tab)
        #expect(EditorConfig.values(for: ["lib/x/y.js"], configs: [root]).indentSize == 2)
        #expect(EditorConfig.values(for: ["src/y.js"], configs: [root]).indentSize == 4)
        // A nearer file wins; {1..3}, [!x] and ? globs.
        let near = EditorConfig.parse("[*.py]\nindent_size = 2\n")
        #expect(EditorConfig.values(for: ["pkg/m.py", "m.py"], configs: [root, near]).indentSize == 2)
        #expect(EditorConfig.matches(glob: "v{1..3}.txt", path: "v2.txt") && !EditorConfig.matches(glob: "v{1..3}.txt", path: "v4.txt"))
        #expect(EditorConfig.matches(glob: "[!a]?.c", path: "x/bz.c") && !EditorConfig.matches(glob: "[!a]?.c", path: "az.c"))
        #expect(EditorConfig.matches(glob: "/top.txt", path: "top.txt") && !EditorConfig.matches(glob: "/top.txt", path: "a/top.txt"))
        // indent_size = tab uses tab_width.
        let tab = EditorConfig.parse("[*]\nindent_size = tab\ntab_width = 8\n")
        #expect(EditorConfig.values(for: ["a"], configs: [tab]).width == 8)
    }

    @Test func whitespaceRulesFollowEditorConfig() throws {
        let trailing = "a  \nb  \nc  \nd  \ne  \n"
        #expect(find(RulesHintProvider.trailingID, trailing, language: "plain", fileName: "a.txt") != nil)
        let noTrim = OwlDocumentFacts(editorConfig: EditorConfig.Values(trimTrailingWhitespace: false))
        #expect(find(RulesHintProvider.trailingID, trailing, language: "plain", fileName: "a.txt", facts: noTrim) == nil)
        // Final newline: off when the config says false; asked for in any saved file when true.
        #expect(find(RulesHintProvider.finalNewlineID, "x = 1", language: "python", fileName: "a.py",
                     facts: OwlDocumentFacts(editorConfig: EditorConfig.Values(insertFinalNewline: false))) == nil)
        #expect(find(RulesHintProvider.finalNewlineID, "Notes", language: "plain", fileName: "a.txt") == nil)
        #expect(find(RulesHintProvider.finalNewlineID, "Notes", language: "plain", fileName: "a.txt",
                     facts: OwlDocumentFacts(editorConfig: EditorConfig.Values(insertFinalNewline: true))) != nil)
        // Mixed indentation goes to the configured side, at its width.
        let mixed = "def f():\n\tif x:\n\t\treturn 1\n    return 2\n"
        let tabs = OwlDocumentFacts(editorConfig: EditorConfig.Values(indentStyle: .tab, indentSize: 4))
        let m = try #require(find(RulesHintProvider.mixedIndentID, mixed, language: "python", fileName: "a.py", facts: tabs))
        #expect(m.title.contains("tabs") && apply(m, to: mixed) == "def f():\n\tif x:\n\t\treturn 1\n\treturn 2\n")
    }

    @Test func indentStyleAgainstEditorConfig() throws {
        let text = "function f() {\n\tif (a) {\n\t\treturn 1;\n\t}\n}\n"
        let spaces = OwlDocumentFacts(editorConfig: EditorConfig.Values(indentStyle: .space, indentSize: 2))
        let h = try #require(find(RulesHintProvider.editorConfigIndentID, text, language: "javascript", fileName: "a.js", facts: spaces))
        #expect(h.title == ".editorconfig says spaces; this file uses tabs. Convert?")
        #expect(apply(h, to: text) == "function f() {\n  if (a) {\n    return 1;\n  }\n}\n")
        let toTabs = OwlDocumentFacts(editorConfig: EditorConfig.Values(indentStyle: .tab, indentSize: 2))
        let t = try #require(find(RulesHintProvider.editorConfigIndentID, "a {\n  b;\n    c;\n  d;\n}\n", language: "css", fileName: "a.css", facts: toTabs))
        #expect(t.replacement == "\tb;\n\t\tc;\n\td;")
        // Quiet: no config, already the configured style, a mix (the mixed-indent rule's), a Makefile, fewer than 3 lines.
        #expect(find(RulesHintProvider.editorConfigIndentID, text, language: "javascript", fileName: "a.js") == nil)
        #expect(find(RulesHintProvider.editorConfigIndentID, text, language: "javascript", fileName: "a.js",
                     facts: OwlDocumentFacts(editorConfig: EditorConfig.Values(indentStyle: .tab))) == nil)
        #expect(find(RulesHintProvider.editorConfigIndentID, text + "  x\n", language: "javascript", fileName: "a.js", facts: spaces) == nil)
        #expect(find(RulesHintProvider.editorConfigIndentID, "all:\n\tcc a.c\n\tcc b.c\n\tld\n", language: "plain", fileName: "Makefile", facts: spaces) == nil)
        #expect(find(RulesHintProvider.editorConfigIndentID, "a\n\tb\n\tc\n", language: "plain", fileName: "a.txt", facts: spaces) == nil)
    }

    /// Review 0.3.0 M3: YAML can't indent with tabs, so a tab
    /// .editorconfig never offers to convert it; data files are left alone.
    @Test func editorConfigNeverOffersTabsForYAMLOrDataFiles() {
        let toTabs = OwlDocumentFacts(editorConfig: EditorConfig.Values(indentStyle: .tab, indentSize: 2))
        let workflow = "on: push\njobs:\n  build:\n    runs-on: macos-15\n    steps:\n      - run: make\n"
        #expect(find(RulesHintProvider.editorConfigIndentID, workflow, language: "yaml", fileName: "ci.yml", facts: toTabs) == nil)
        #expect(find(RulesHintProvider.editorConfigIndentID, workflow, language: "plain", fileName: "ci.yaml", facts: toTabs) == nil)
        // Mixed indentation in YAML with a tab config: not "Convert to tabs" either.
        let mixed = "a:\n  b: 1\n\tc: 2\n  d: 3\n"
        #expect(find(RulesHintProvider.mixedIndentID, mixed, language: "yaml", fileName: "a.yml", facts: toTabs).map { !$0.title.contains("tabs?") } ?? true)
        #expect(find(RulesHintProvider.mixedIndentID, mixed, language: "plain", fileName: "a.yaml", facts: toTabs).map { !$0.title.contains("tabs?") } ?? true)
        // INI / .env: whitespace is the data.
        #expect(find(RulesHintProvider.editorConfigIndentID, "[a]\n  x = 1\n  y = 2\n  z = 3\n", language: "ini", fileName: "a.ini", facts: toTabs) == nil)
        // The same file under a JavaScript name still gets the offer (the guard is YAML's, not every file's).
        #expect(find(RulesHintProvider.editorConfigIndentID, "f(\n  a,\n  b,\n  c\n)\n", language: "javascript", fileName: "a.js", facts: toTabs) != nil)
    }

    // MARK: Style tier

    static let style = OwlDocumentFacts(styleTips: true)

    @Test func styleRulesNeedTheSetting() {
        let samples: [(String, String, String, String)] = [
            (PythonRules.bareExceptID, "try:\n    x()\nexcept:\n    pass\n", "python", "a.py"),
            (PythonRules.boolCompareID, "if ok == True:\n    pass\n", "python", "a.py"),
            (ShellRules.backticksID, "d=`date`\n", "shell", "a.sh"),
            (MarkdownRules.imageAltID, "![](img/logo.png)\n", "markdown", "a.md"),
        ]
        for (id, text, lang, name) in samples {
            #expect(find(id, text, language: lang, fileName: name) == nil, "\(id) off by default")
            let h = find(id, text, language: lang, fileName: name, facts: Self.style)
            #expect(h != nil && h!.title.count <= 60, "\(id)")
        }
    }

    @Test func bareExcept() throws {
        let text = "try:\n    run()\nexcept :\n    log()\ntry:\n    a()\nexcept:\n    pass\n"
        let h = try #require(find(PythonRules.bareExceptID, text, language: "python", fileName: "a.py", facts: Self.style))
        #expect(apply(h, to: text) == "try:\n    run()\nexcept Exception:\n    log()\ntry:\n    a()\nexcept Exception:\n    pass\n")
        for t in ["except Exception:\n", "except (A, B):\n", "# except:\n", "s = 'except:'\n", "except ValueError as e:\n"] {
            #expect(find(PythonRules.bareExceptID, t, language: "python", fileName: "a.py", facts: Self.style) == nil, "\(t)")
        }
    }

    @Test func boolCompare() throws {
        let text = "if ok == True:\n    a()\nwhile self.done != True:\n    b()\nelif flag == False:\n    c()\n"
        let h = try #require(find(PythonRules.boolCompareID, text, language: "python", fileName: "a.py", facts: Self.style))
        #expect(apply(h, to: text) == "if ok:\n    a()\nwhile not self.done:\n    b()\nelif not flag:\n    c()\n")
        for t in ["if ok is True:\n", "x = a == True\n", "if f(a) == True:\n", "# if ok == True:\n", "if ok == True and b:\n",
                  "assert ok == True\n"] {
            #expect(find(PythonRules.boolCompareID, t, language: "python", fileName: "a.py", facts: Self.style) == nil, "\(t)")
        }
    }

    @Test func shellBackticks() throws {
        let text = "now=`date +%s`\necho \"took `expr $b - $a` s\"\n"
        let h = try #require(find(ShellRules.backticksID, text, language: "shell", fileName: "a.sh", facts: Self.style))
        #expect(apply(h, to: text) == "now=$(date +%s)\necho \"took $(expr $b - $a) s\"\n")
        for t in ["echo 'a `b` c'\n", "# run `make`\n", "x=$(date)\n", "cat <<EOF\n`x`\nEOF\n", "echo \"\\`literal\\`\"\n", "msg=\"one\ntwo `x` three\"\n"] {
            #expect(find(ShellRules.backticksID, t, language: "shell", fileName: "a.sh", facts: Self.style) == nil, "\(t)")
        }
    }

    @Test func imageWithoutAltText() throws {
        let text = "Logo: ![](img/owl-logo.png)\n![shot](a.png) `![](code.png)`\n"
        let h = try #require(find(MarkdownRules.imageAltID, text, language: "markdown", fileName: "a.md", facts: Self.style))
        #expect(apply(h, to: text) == "Logo: ![owl logo](img/owl-logo.png)\n![shot](a.png) `![](code.png)`\n")
        for t in ["![a cat](cat.png)\n", "```\n![](x.png)\n```\n", "<!-- ![](x.png) -->\n", "[](link)\n"] {
            #expect(find(MarkdownRules.imageAltID, t, language: "markdown", fileName: "a.md", facts: Self.style) == nil, "\(t)")
        }
    }
}
