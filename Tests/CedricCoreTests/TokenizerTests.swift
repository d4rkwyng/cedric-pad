import Foundation
import Testing
@testable import CedricCore

/// The text of each token on each line, as (text, kind) pairs.
func spans(_ text: String, _ language: Language) -> [[(String, TokenKind)]] {
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { Array($0.utf16) }
    return zip(lines, tokenizeLines(text, with: Languages.tokenizer(for: language))).map { units, tokens in
        tokens.map { (String(decoding: units[$0.start..<$0.end], as: UTF16.self), $0.kind) }
    }
}

func kinds(_ text: String, _ language: Language) -> [String: TokenKind] {
    var out: [String: TokenKind] = [:]
    for line in spans(text, language) { for (s, k) in line where out[s] == nil { out[s] = k } }
    return out
}

@Suite struct TokenizerTests {
    @Test func swiftBasics() {
        let k = kinds(#"""
        import Foundation
        @MainActor final class Foo: Bar {
            let x = 0x1F + 3.5e-2 // note
            func go() -> String { return "hi \(x)" }
            var y: Int? = nil
        }
        """#, .swift)
        #expect(k["import"] == .keyword)
        #expect(k["@MainActor"] == .attribute)
        #expect(k["Foo"] == .type)
        #expect(k["0x1F"] == .number)
        #expect(k["3.5e-2"] == .number)
        #expect(k["// note"] == .comment)
        #expect(k["go"] == .function)
        #expect(k["\"hi \\(x)\""] == .string)
        #expect(k["nil"] == .constant)
        #expect(k["Int"] == .type)
    }

    @Test func swiftNestedBlockCommentSpansLines() {
        let s = spans("a /* one /* two */\nstill */ let b", .swift)
        #expect(s[0].map(\.1) == [.comment])
        #expect(s[1].first?.0 == "still */")
        #expect(s[1].first?.1 == .comment)
        #expect(s[1].last?.0 == "let")
    }

    @Test func swiftMultilineString() {
        let s = spans("let s = \"\"\"\nbody \"quoted\"\n\"\"\"\nlet t = 1", .swift)
        #expect(s[1].map(\.1) == [.string])
        #expect(s[1][0].0 == "body \"quoted\"")
        #expect(s[2].map(\.0) == ["\"\"\""])
        #expect(s[3].map(\.1) == [.keyword, .number])
    }

    @Test func memberNamedLikeKeywordIsNotKeyword() {
        let k = kinds("x.default = 1", .swift)
        #expect(k["default"] == nil)
    }

    @Test func python() {
        let s = spans("@decorator\ndef f(x):\n    '''doc\n    more'''\n    return None  # c", .python)
        #expect(s[0].map(\.1) == [.attribute])
        #expect(s[1].map(\.0) == ["def", "f"])
        #expect(s[1].map(\.1) == [.keyword, .function])
        #expect(s[2].map(\.1) == [.string])
        #expect(s[3].map(\.1) == [.string])
        #expect(s[4].map(\.1) == [.keyword, .constant, .comment])
    }

    @Test func javascriptTemplateLiteralAcrossLines() {
        let s = spans("const a = `x\n${y}`; let $b = null", .javascript)
        #expect(s[0].map(\.1) == [.keyword, .string])
        #expect(s[1].first?.0 == "${y}`")
        #expect(kinds("let $b = null", .javascript)["null"] == .constant)
    }

    @Test func typescriptTypes() {
        let k = kinds("interface P { name: string; n: number }", .typescript)
        #expect(k["interface"] == .keyword)
        #expect(k["P"] == .type)
        #expect(k["string"] == .type)
    }

    @Test func json() {
        let s = spans(#"{"key": "value", "n": -1.5e3, "ok": true, "z": null}"#, .json)
        #expect(s[0].map(\.1) == [.key, .string, .key, .number, .key, .constant, .key, .constant])
        #expect(s[0][3].0 == "-1.5e3")
    }

    @Test func jsonEscapedQuoteInString() {
        let s = spans(#"["a\"b", 1]"#, .json)
        #expect(s[0].map(\.0) == [#""a\"b""#, "1"])
    }

    @Test func yaml() {
        let s = spans("---\nname: demo # c\nlist:\n  - 42\n  - \"q\"\nflag: true\nref: *anchor", .yaml)
        #expect(s[0].map(\.1) == [.punctuation])
        #expect(s[1].map(\.1) == [.key, .comment])
        #expect(s[3].map(\.1) == [.punctuation, .number])
        #expect(s[4].map(\.1) == [.punctuation, .string])
        #expect(s[5].map(\.1) == [.key, .constant])
        #expect(s[6].map(\.1) == [.key, .variable])
    }

    @Test func yamlURLValueIsNotAKey() {
        let s = spans("url: http://example.com:8080/x", .yaml)
        #expect(s[0].map(\.0) == ["url"])
    }

    @Test func markdown() {
        let s = spans("# Title\nSome *em* and **strong** and `code` and [a](b).\n```swift\nlet x = 1\n```\n- item\n> quote", .markdown)
        #expect(s[0].map(\.1) == [.heading])
        #expect(s[1].map(\.1) == [.emphasis, .strong, .code, .link])
        #expect(s[2].map(\.1) == [.code])
        #expect(s[3].map(\.1) == [.code])   // inside the fence: all code, no Swift keywords
        #expect(s[4].map(\.1) == [.code])
        #expect(s[5].map(\.1) == [.punctuation])
        #expect(s[6].map(\.1) == [.punctuation])
    }

    @Test func markdownSnakeCaseIsNotEmphasis() {
        #expect(spans("call some_function_name here", .markdown)[0].isEmpty)
    }

    @Test func htmlWithEmbeddedScriptAndStyle() {
        let s = spans("<!-- c\n--><p class=\"x\">a &amp; b</p>\n<script>\nlet a = 1;\n</script>\n<style> p { color: red; }</style>", .html)
        #expect(s[0].map(\.1) == [.comment])
        #expect(s[1].map(\.1) == [.comment, .tag, .attribute, .string, .tag, .constant, .tag])
        #expect(s[3].map(\.1) == [.keyword, .number])
        #expect(s[4].map(\.0) == ["</script>"])
        let style = s[5]
        #expect(style.contains { $0.0 == "color" && $0.1 == .key })
        #expect(style.contains { $0.0 == "p" && $0.1 == .tag })
    }

    @Test func css() {
        let s = spans("/* a */ .btn, h1 {\n  margin: -4px 1.5em;\n  color: #fff !important;\n}\n@media screen {", .css)
        #expect(s[0].map(\.0) == ["/* a */", ".btn", "h1"])
        #expect(s[1].map(\.1) == [.key, .number, .number])
        #expect(s[2].map(\.1) == [.key, .number, .keyword])
        #expect(s[4].first?.1 == .keyword)
    }

    @Test func shell() {
        let s = spans("#!/bin/sh\nif [ -n \"$HOME\" ]; then echo ${X} a#b; fi # done", .shell)
        #expect(s[0].map(\.1) == [.comment])
        let k = Dictionary(s[1].map { ($0.0, $0.1) }, uniquingKeysWith: { a, _ in a })
        #expect(k["if"] == .keyword)
        #expect(k["\"$HOME\""] == .string)
        #expect(k["${X}"] == .variable)
        #expect(k["# done"] == .comment)
        #expect(k["#b; fi # done"] == nil) // a#b is a word, not a comment
    }

    @Test func cPreprocessorAndTypes() {
        let k = kinds("#include <stdio.h>\nstatic const uint8_t x = 'a'; /* c */\nint main(void) { return NULL; }", .c)
        #expect(k["#include"] == .preprocessor)
        #expect(k["static"] == .keyword)
        #expect(k["uint8_t"] == .type)
        #expect(k["'a'"] == .string)
        #expect(k["main"] == .function)
        #expect(k["NULL"] == .constant)
    }

    @Test func ruby() {
        let k = kinds("class Foo < Bar\n  def ok?(x) = @val || :sym\nend", .ruby)
        #expect(k["class"] == .keyword)
        #expect(k["Foo"] == .type)
        #expect(k["ok?"] == .function)
        #expect(k["@val"] == .variable)
        #expect(k[":sym"] == .constant)
        #expect(k["end"] == .keyword)
    }

    @Test func plainHasNoTokens() {
        #expect(spans("let x = 1 // nothing", .plain)[0].isEmpty)
    }

    @Test func unicodeOffsetsAreUTF16() {
        // "é" is one UTF-16 unit, "😀" two: the string token must start after them.
        let s = spans("let 😀é = \"x\"", .swift)
        #expect(s[0].map(\.0) == ["let", "\"x\""])
    }
}

@Suite struct JSONKeyColourTests {
    @Test func keysAndStringValuesDiffer() {
        // Tokens: a key is a string followed by a colon, a value isn't.
        let ns = "{\"name\": \"value\", \"list\": [\"a\"]}\n" as NSString
        var index = LineIndex()
        _ = index.replace(NSRange(location: 0, length: 0), newLength: ns.length, in: ns)
        let t = HighlightEngine(language: .json).tokens(forLines: 0..<index.lineCount, in: ns, index: index)
        let kinds = t.map { (ns.substring(with: NSRange(location: $0.start, length: $0.length)), $0.kind) }
        #expect(kinds.filter { $0.1 == .key }.map(\.0) == ["\"name\"", "\"list\""])
        #expect(kinds.filter { $0.1 == .string }.map(\.0) == ["\"value\"", "\"a\""])
        // And every theme draws them in different colours.
        for p in EditorPalettes.all { #expect(p.color(for: .key) != p.color(for: .string), "\(p.name)") }
    }
}
