import Foundation
import Testing
@testable import CedricCore

/// Pack 3: JavaScript and TypeScript. Fires, near misses, fix.
@Suite struct OwlJSRulesTests {
    func find(_ id: String, _ text: String, language: String = "javascript") -> OwlHint? {
        OwlLanguageRulesTests.check(text, language: language, fileName: language == "typescript" ? "a.ts" : "a.js").first { $0.id == id }
    }

    func apply(_ h: OwlHint, to text: String) -> String {
        (text as NSString).replacingCharacters(in: h.range!, with: h.replacement!)
    }

    @Test func debuggerLeftIn() throws {
        let text = "function f() {\n    debugger;\n    if (x) { debugger }\n    return 1\n}\n"
        let h = try #require(find(JSRules.debuggerID, text))
        #expect(h.kind == .fix)
        #expect(apply(h, to: text) == "function f() {\n    if (x) { }\n    return 1\n}\n")
        #expect(find(JSRules.debuggerID, "let a = 1;\ndebugger", language: "typescript") != nil)
        for t in ["// debugger;\n", "const s = \"debugger;\";\n", "obj.debugger;\n", "const o = { debugger: true };\n",
                  "/* debugger */\n", "const r = /debugger/;\n", "debuggerEnabled = true;\n"] {
            #expect(find(JSRules.debuggerID, t) == nil, "\(t)")
        }
    }

    @Test func comparingWithNaN() throws {
        let text = "if (x === NaN) {}\nconst bad = value.n !== Number.NaN;\nif (NaN == y) {}\n"
        let h = try #require(find(JSRules.nanID, text))
        #expect(apply(h, to: text) == "if (Number.isNaN(x)) {}\nconst bad = !Number.isNaN(value.n);\nif (Number.isNaN(y)) {}\n")
        // Something complex on the other side: a warning, Show Me.
        let w = try #require(find(JSRules.nanID, "if (a + b === NaN) {}\n"))
        #expect(w.kind == .warning && w.replacement == nil)
        for t in ["if (Number.isNaN(x)) {}\n", "// x === NaN\n", "const s = \"x === NaN\";\n", "x = NaN;\n", "const t = `${x === NaN}`;\n",
                  "obj.NaN === 1\n"] {
            #expect(find(JSRules.nanID, t) == nil, "\(t)")
        }
    }

    @Test func typeofTypos() throws {
        let text = "if (typeof x === \"undefnied\") {}\nif ('fucntion' !== typeof cb) {}\n"
        let h = try #require(find(JSRules.typeofID, text, language: "typescript"))
        #expect(h.title.contains("undefined"))
        #expect(apply(h, to: text) == "if (typeof x === \"undefined\") {}\nif ('function' !== typeof cb) {}\n")
        // No near name: a warning.
        let w = try #require(find(JSRules.typeofID, "if (typeof a == 'array') {}\n"))
        #expect(w.kind == .warning && w.replacement == nil)
        for t in ["if (typeof x === \"undefined\") {}\n", "if (typeof f === 'function' && typeof n == \"bigint\") {}\n",
                  "// typeof x === \"strng\"\n", "const s = 'typeof x === \"strng\"';\n", "type T = typeof x;\n", "if (typeof x === t) {}\n",
                  "if (x === \"strng\") {}\n"] {
            #expect(find(JSRules.typeofID, t) == nil, "\(t)")
        }
    }
}
