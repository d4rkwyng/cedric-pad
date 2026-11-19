import Foundation
import Testing
@testable import CedricCore

/// Pack 4: configuration files. Fires, near misses, fix.
@Suite struct OwlConfigRulesTests {
    func find(_ id: String, _ text: String, language: String, fileName: String?, facts: OwlDocumentFacts = OwlDocumentFacts()) -> OwlHint? {
        OwlLanguageRulesTests.check(text, language: language, fileName: fileName, facts: facts).first { $0.id == id }
    }

    func apply(_ h: OwlHint, to text: String) -> String {
        (text as NSString).replacingCharacters(in: h.range!, with: h.replacement!)
    }

    func yaml(_ id: String, _ text: String, fileName: String = "a.yml", facts: OwlDocumentFacts = OwlDocumentFacts()) -> OwlHint? {
        find(id, text, language: "yaml", fileName: fileName, facts: facts)
    }

    @Test func duplicateYAMLKeys() throws {
        let text = "services:\n  web:\n    image: nginx\n    ports: [\"80:80\"]\n    image: caddy\n"
        let h = try #require(yaml(ConfigRules.yamlDuplicateID, text))
        #expect(h.kind == .warning && h.title.contains("image") && h.detail?.contains("line 5") == true)
        #expect((text as NSString).substring(with: h.range!) == "image")
        let list = "steps:\n- name: a\n  run: x\n  name: b\n"
        #expect(yaml(ConfigRules.yamlDuplicateID, list) != nil)
        #expect(yaml(ConfigRules.yamlDuplicateID, "a: 1\n\"a\": 2\n") != nil)
        for t in ["a:\n  x: 1\nb:\n  x: 2\n", "steps:\n- name: a\n- name: b\n", "a: |\n  b: 1\n  b: 2\nc: 3\n",
                  "a: 1\n# a: 2\n", "x: 1\n---\nx: 2\n", "jobs:\n  - name: a\n    with:\n      v: 1\n  - name: b\n    with:\n      v: 2\n",
                  "base: &b\n  x: 1\nfoo:\n  <<: *b\n  <<: *b\n", "{{- if .A }}\nimage: a\n{{- else }}\nimage: b\n{{- end }}\n",
                  "a: >\n  text\n  a: 2\n", "m: {a: 1,\n  a: 2}\n", "url: http://x\nurl2: http://x\n"] {
            #expect(yaml(ConfigRules.yamlDuplicateID, t) == nil, "\(t)")
        }
        #expect(yaml(ConfigRules.yamlDuplicateID, text, facts: OwlDocumentFacts(isWholeDocument: false)) == nil)
    }

    @Test func yamlVersionsReadAsNumbers() throws {
        let text = "jobs:\n  test:\n    strategy:\n      matrix:\n        python-version: [\"3.9\", 3.10, 3.11]\n    steps:\n      - uses: actions/setup-node\n        with:\n          node-version: 20.10\n"
        let h = try #require(yaml(ConfigRules.yamlVersionID, text))
        #expect(h.kind == .fix && h.title == "Version 3.10 reads as the number 3.1. Quote it?")
        #expect(apply(h, to: text) == text.replacingOccurrences(of: ", 3.10,", with: ", \"3.10\",").replacingOccurrences(of: "20.10", with: "\"20.10\""))
        let list = "python:\n  - 3.8\n  - 3.10\n"
        #expect(apply(try #require(yaml(ConfigRules.yamlVersionID, list)), to: list) == "python:\n  - 3.8\n  - \"3.10\"\n")
        for t in ["python-version: \"3.10\"\n", "python-version: 3.11\n", "price: 1.50\n", "port: 8080\n", "version: 3.0\n",
                  "# python-version: 3.10\n", "description: |\n  version: 3.10\n", "version: 1.20\n"] {
            let name = t.hasPrefix("version: 1.20") ? "Chart.yaml" : "a.yml"
            #expect(yaml(ConfigRules.yamlVersionID, t, fileName: name) == nil, "\(t)")
        }
    }

    @Test func duplicateJSONKeys() throws {
        let text = "{\n  \"name\": \"a\",\n  \"deps\": {\"x\": 1, \"y\": 2},\n  \"name\": \"b\"\n}\n"
        let h = try #require(find(ConfigRules.jsonDuplicateID, text, language: "json", fileName: "package.json"))
        #expect(h.title.contains("\"name\"") && h.detail?.contains("line 2") == true)
        #expect((text as NSString).substring(with: h.range!) == "\"name\"")
        for t in ["{\"a\": {\"x\": 1}, \"b\": {\"x\": 1}}\n", "[{\"a\": 1}, {\"a\": 2}]\n", "{\"a\": \"a\", \"b\": [\"a\", \"a\"]}\n",
                  "{\n  // \"a\": 1\n  \"a\": 2\n}\n", "{\"a\": \"x\\\"a\\\": 1\"}\n"] {
            #expect(find(ConfigRules.jsonDuplicateID, t, language: "json", fileName: "a.json") == nil, "\(t)")
        }
        #expect(find(ConfigRules.jsonDuplicateID, text, language: "json", fileName: "a.json", facts: OwlDocumentFacts(isWholeDocument: false)) == nil)
    }

    @Test func xmlPlistAndSVGThatDontParse() throws {
        let plist = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n<plist version=\"1.0\">\n<dict>\n  <key>A</key>\n  <string>x</string>\n</plist>\n"
        let h = try #require(find(ConfigRules.xmlInvalidID, plist, language: "xml", fileName: "Info.plist"))
        #expect(h.kind == .warning && h.title.hasPrefix("This plist doesn’t parse (line 7)"))
        #expect(h.detail?.contains("closing tag") == true)
        #expect((plist as NSString).substring(with: h.range!) == "</plist>")
        let svg = "<svg xmlns=\"http://www.w3.org/2000/svg\"><text>a&nbsp;b</text></svg>\n"
        #expect(find(ConfigRules.xmlInvalidID, svg, language: "html", fileName: "icon.svg")?.title.hasPrefix("This SVG") == true)
        // Valid XML but not a plist.
        let notPlist = "<plist version=\"1.0\"><dict><key>A</key></dict></plist>\n"
        #expect(find(ConfigRules.xmlInvalidID, notPlist, language: "xml", fileName: "a.plist")?.title == "This plist is valid XML but not a valid plist.")
        let good = plist.replacingOccurrences(of: "</plist>", with: "</dict>\n</plist>")
        for (t, name, lang) in [(good, "Info.plist", "xml"), ("<a><b/></a>\n", "a.xml", "xml"), ("<p>a&nbsp;b</p>\n", "a.html", "html"),
                                ("<a>{{ x }}</b>\n", "t.xml", "xml")] {
            #expect(find(ConfigRules.xmlInvalidID, t, language: lang, fileName: name) == nil, "\(name)")
        }
        // Not while typing, nor on a window.
        #expect(find(ConfigRules.xmlInvalidID, plist, language: "xml", fileName: "a.plist", facts: OwlDocumentFacts(unsavedSince: Date())) == nil)
        #expect(find(ConfigRules.xmlInvalidID, plist, language: "xml", fileName: "a.plist", facts: OwlDocumentFacts(isWholeDocument: false)) == nil)
    }

    @Test func tomlDuplicatesAndBareStrings() throws {
        let text = "[server]\nhost = \"a\"\n[db]\nname = \"x\"\n[server]\nport = 1\n"
        let h = try #require(find(ConfigRules.tomlDuplicateID, text, language: "ini", fileName: "config.toml"))
        #expect(h.title == "“[server]” is defined twice." && (text as NSString).substring(with: h.range!) == "[server]")
        #expect(find(ConfigRules.tomlDuplicateID, "a = 1\nb = 2\na = 3\n", language: "ini", fileName: "a.toml")?.title.contains("“a”") == true)
        for t in ["[[fruit]]\nname = \"a\"\n[fruit.physical]\nc = 1\n[[fruit]]\nname = \"b\"\n[fruit.physical]\nc = 2\n",
                  "[a]\nx = 1\n[b]\nx = 1\n", "s = \"\"\"\n[a]\n[a]\n\"\"\"\n", "# [a]\n[a]\n", "x = [\n  1,\n]\ny = 1\n"] {
            #expect(find(ConfigRules.tomlDuplicateID, t, language: "ini", fileName: "a.toml") == nil, "\(t)")
        }
        let bare = "[tool]\nname = web\nmode = dev # comment\nok = \"x\"\n"
        let b = try #require(find(ConfigRules.tomlBareID, bare, language: "ini", fileName: "pyproject.toml"))
        #expect(apply(b, to: bare) == "[tool]\nname = \"web\"\nmode = \"dev\" # comment\nok = \"x\"\n")
        for t in ["a = 1\nb = 1_000\nc = 3.14\nd = -inf\ne = true\nf = 1979-05-27T07:32:00Z\ng = 07:32:00\nh = 0xFF\n",
                  "a = [1, 2]\nb = { x = 1 }\nc = 'lit'\n", "s = \"\"\"\nk = v\n\"\"\"\n", "arr = [\n  word,\n]\n"] {
            #expect(find(ConfigRules.tomlBareID, t, language: "ini", fileName: "a.toml") == nil, "\(t)")
        }
        // INI allows bare values: not a TOML file, no hint.
        #expect(find(ConfigRules.tomlBareID, "name = web\n", language: "ini", fileName: "setup.cfg") == nil)
    }

    @Test func envSpacesAndDuplicateKeys() throws {
        let text = "PORT = 8080\nexport HOST= example.com\nDEBUG=1\n"
        let h = try #require(find(ConfigRules.envSpacesID, text, language: "ini", fileName: ".env"))
        #expect(apply(h, to: text) == "PORT=8080\nexport HOST=example.com\nDEBUG=1\n")
        for t in ["A=1\nB=\"a = b\"\n", "# A = 1\n", "MSG=\"line one\nB = two\"\n", "A=\n"] {
            #expect(find(ConfigRules.envSpacesID, t, language: "ini", fileName: ".env.local") == nil, "\(t)")
        }
        let dup = "A=1\nB=2\nexport A=3\n"
        let d = try #require(find(ConfigRules.envDuplicateID, dup, language: "ini", fileName: "prod.env"))
        #expect(d.title == "A is set twice." && d.range == NSRange(location: 15, length: 1))
        #expect(find(ConfigRules.envDuplicateID, "A=1\n# A=2\nAB=3\n", language: "ini", fileName: ".env") == nil)
        #expect(find(ConfigRules.envDuplicateID, dup, language: "ini", fileName: "a.ini") == nil)
    }
}
