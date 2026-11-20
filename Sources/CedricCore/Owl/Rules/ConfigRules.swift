import Foundation

/// Pack 4: configuration files. Sources: yamllint (key-duplicates), the
/// YAML 1.1/1.2 float rules (`3.10` is 3.1), dotenv-linter (SpaceCharacter,
/// DuplicatedKey), the TOML 1.0 spec (a table or key defined twice, values
/// must be typed), Foundation's XMLParser and PropertyListSerialization.
enum ConfigRules {
    static let yamlDuplicateID = "rules.yaml.duplicate-key"
    static let yamlVersionID = "rules.yaml.version-float"
    static let jsonDuplicateID = "rules.json.duplicate-key"
    static let xmlInvalidID = "rules.xml.invalid"
    static let tomlDuplicateID = "rules.toml.duplicate"
    static let tomlBareID = "rules.toml.bare-string"
    static let envSpacesID = "rules.env.spaces"
    static let envDuplicateID = "rules.env.duplicate-key"

    /// Text with template syntax ({{ }}, {% %}, <% %>): its branches and
    /// placeholders aren't the file's real structure.
    static func isTemplated(_ s: String) -> Bool {
        s.contains("{{") || s.contains("{%") || s.contains("<%")
    }

    // MARK: YAML

    /// A `key:` line of a YAML block mapping (or a `- item` line).
    struct YAMLEntry {
        var indent: Int            // column of the key (or of the item's value)
        var key: String?           // nil: a `- value` list item
        var keyRange: NSRange
        var value: String          // after `key:` (or `- `), comment removed, trimmed
        var valueRange: NSRange
        var startsItem: Bool       // the first key of a `- ` list item
        var line: Int
    }

    static let yamlKey = try! NSRegularExpression(pattern: #"\G("(?:[^"\\]|\\.)*"|'(?:[^']|'')*'|[^\s#"'\[\]{},&*!|>%@`?-][^#\n]*?|-[^\s#\n][^#\n]*?)[ \t]*:(?=[ \t]|$)"#)

    /// The entries of a YAML text, skipping comments, block scalars
    /// (`|`, `>`), multi-line flow collections and quoted scalars. A `---`
    /// line ends a document (an entry with indent -1 and no key).
    static func yamlEntries(_ s: NSString, lines: [NSRange]) -> [YAMLEntry] {
        var out: [YAMLEntry] = []
        var blockParent: Int?      // inside a block scalar under a key at this indent
        var flowDepth = 0
        for (index, r) in lines.enumerated() {
            var line = s.substring(with: r) as NSString
            if line.hasSuffix("\r") { line = line.substring(to: line.length - 1) as NSString }
            var indent = 0
            while indent < line.length, line.character(at: indent) == 32 { indent += 1 }
            let blank = indent == line.length || line.character(at: indent) == 35
            if let p = blockParent {
                if blank && indent == line.length || indent > p { continue }
                blockParent = nil
            }
            if flowDepth > 0 {
                flowDepth += flowBalance(line as String)
                continue
            }
            if blank { continue }
            if line.hasPrefix("---") || line.hasPrefix("...") {
                out.append(YAMLEntry(indent: -1, key: nil, keyRange: r, value: "", valueRange: r, startsItem: false, line: index))
                continue
            }
            if line.hasPrefix("%") { continue }   // a directive
            var col = indent
            var item = false
            while col < line.length, line.character(at: col) == 45, col + 1 == line.length || line.character(at: col + 1) == 32 {
                item = true
                col += 1
                while col < line.length, line.character(at: col) == 32 { col += 1 }
            }
            let rest = NSRange(location: col, length: line.length - col)
            var value = "", valueRange = NSRange(location: r.location + line.length, length: 0)
            var key: String?, keyRange = NSRange(location: r.location + col, length: 0)
            if let m = yamlKey.firstMatch(in: line as String, range: rest) {
                key = line.substring(with: m.range(at: 1))
                keyRange = NSRange(location: r.location + m.range(at: 1).location, length: m.range(at: 1).length)
                (value, valueRange) = scalarValue(line, from: NSMaxRange(m.range), base: r.location)
            } else if item {
                (value, valueRange) = scalarValue(line, from: col, base: r.location)
            } else {
                continue   // a continuation of a plain scalar, or something else
            }
            out.append(YAMLEntry(indent: key == nil ? indent : col, key: key, keyRange: keyRange, value: value, valueRange: valueRange,
                                 startsItem: item && key != nil, line: index))
            if value.hasPrefix("|") || value.hasPrefix(">") {
                blockParent = key == nil ? indent : col
                if item, key != nil { blockParent = col }
            } else if value.hasPrefix("[") || value.hasPrefix("{") {
                flowDepth = max(0, flowBalance(value))
            } else if value.hasPrefix("\"") && !closedQuote(value, 34) || value.hasPrefix("'") && !closedQuote(value, 39) {
                // A quoted scalar over several lines: not worth following; stop here.
                break
            }
        }
        return out
    }

    /// Opened minus closed brackets of a flow collection, outside quotes.
    static func flowBalance(_ s: String) -> Int {
        var d = 0, q: Character?
        for c in s {
            if let open = q { if c == open { q = nil }; continue }
            switch c {
            case "\"", "'": q = c
            case "[", "{": d += 1
            case "]", "}": d -= 1
            case "#": return d
            default: break
            }
        }
        return d
    }

    static func closedQuote(_ s: String, _ q: unichar) -> Bool {
        let ns = s as NSString
        var i = 1
        while i < ns.length {
            let c = ns.character(at: i)
            if q == 34, c == 92 { i += 2; continue }
            if c == q {
                if q == 39, i + 1 < ns.length, ns.character(at: i + 1) == 39 { i += 2; continue }
                return true
            }
            i += 1
        }
        return false
    }

    /// The value from `from` to a ` #` comment, trimmed, and its range.
    static func scalarValue(_ line: NSString, from: Int, base: Int) -> (String, NSRange) {
        var a = from
        while a < line.length, line.character(at: a) == 32 || line.character(at: a) == 9 { a += 1 }
        var e = a, q: unichar = 0
        while e < line.length {
            let c = line.character(at: e)
            if q != 0 { if c == q { q = 0 }; e += 1; continue }
            if e == a, c == 34 || c == 39 { q = c }
            if c == 35, e > a, line.character(at: e - 1) == 32 || line.character(at: e - 1) == 9 { break }
            e += 1
        }
        while e > a, line.character(at: e - 1) == 32 || line.character(at: e - 1) == 9 { e -= 1 }
        return (line.substring(with: NSRange(location: a, length: e - a)), NSRange(location: base + a, length: e - a))
    }

    /// The mapping each entry belongs to: for each entry with a key, the
    /// earlier entry with the same key in the same mapping, if any; and for
    /// each entry, the key of the mapping entry it sits under.
    static func yamlStructure(_ entries: [YAMLEntry]) -> (duplicates: [(first: YAMLEntry, again: YAMLEntry)], parent: [Int: String]) {
        struct Frame { var indent: Int; var keys: [String: YAMLEntry]; var last: String? }
        var stack: [Frame] = []
        var dups: [(YAMLEntry, YAMLEntry)] = []
        var parent: [Int: String] = [:]
        for (i, e) in entries.enumerated() {
            if e.indent < 0 { stack = []; continue }
            guard let key = e.key else {
                // `- value` at this column: deeper mappings are over.
                while let top = stack.last, top.indent > e.indent { stack.removeLast() }
                parent[i] = stack.last?.last
                continue
            }
            if e.startsItem {
                while let top = stack.last, top.indent >= e.indent { stack.removeLast() }
            } else {
                while let top = stack.last, top.indent > e.indent { stack.removeLast() }
            }
            if stack.last?.indent != e.indent { stack.append(Frame(indent: e.indent, keys: [:], last: nil)) }
            parent[i] = stack.dropLast().last?.last
            let norm = normalizedKey(key)
            if norm != "<<", let first = stack[stack.count - 1].keys[norm] { dups.append((first, e)) } else { stack[stack.count - 1].keys[norm] = e }
            stack[stack.count - 1].last = norm
        }
        return (dups, parent)
    }

    static func normalizedKey(_ k: String) -> String {
        if k.count >= 2, let f = k.first, f == "\"" || f == "'", k.last == f { return String(k.dropFirst().dropLast()) }
        return k
    }

    static let yamlDuplicateKey = LintRule(yamlDuplicateID, wholeDocument: true, applies: LintRule.languages(["yaml"])) { input in
        guard input.string.contains(":"), !isTemplated(input.string) else { return nil }
        let dups = input.yaml.structure.duplicates
        guard let d = dups.first, let key = d.again.key else { return nil }
        return LintFinding(kind: .warning, title: String(localized: "“\(String(key.prefix(24)))” is set twice in the same block."),
                           detail: String(localized: "The second one (line \(d.again.line + 1)) silently replaces the first (line \(d.first.line + 1)); some tools refuse the file instead.\(RulesHintProvider.andMore(dups.count))"),
                           range: d.again.keyRange)
    }

    /// Keys whose numbers are versions: `3.10` must stay "3.10".
    static let versionKeys: Set<String> = ["python", "node", "nodejs", "go", "golang", "ruby", "java", "jdk", "php", "rust", "elixir",
                                           "otp", "erlang", "dotnet", "flutter", "terraform", "deno", "bun", "perl", "julia", "r"]
    static let floatVersion = try! NSRegularExpression(pattern: #"^\d+\.\d*0$"#)

    static func isVersionKey(_ k: String?) -> Bool {
        guard let k = k?.lowercased() else { return false }
        return k.contains("version") || k.contains("versions") || versionKeys.contains(k)
    }

    static let yamlVersionFloat = LintRule(yamlVersionID, applies: { l, name in
        l == "yaml" && name?.lowercased() != "chart.yaml"
    }) { input in
        guard input.string.contains("0"), !isTemplated(input.string) else { return nil }
        let (entries, structure) = input.yaml
        let parents = structure.parent
        var edits: [(NSRange, String)] = []
        var example = ""
        func consider(_ v: String, _ r: NSRange) {
            guard v.contains("."), floatVersion.firstMatch(in: v, range: NSRange(location: 0, length: (v as NSString).length)) != nil,
                  v.hasSuffix("0"), (v as NSString).range(of: ".").location < (v as NSString).length - 2 else { return }
            if example.isEmpty { example = v }
            edits.append((r, "\"\(v)\""))
        }
        for (i, e) in entries.enumerated() where e.indent >= 0 {
            let key = e.key ?? parents[i]
            guard isVersionKey(key) || (e.key != nil && e.value.hasPrefix("[") && isVersionKey(e.key)) else { continue }
            if e.value.hasPrefix("[") {
                // A flow list on one line: [3.8, 3.9, 3.10]
                let v = e.value as NSString
                var k = 1, start = 1
                while k <= v.length {
                    if k == v.length || v.character(at: k) == 44 || v.character(at: k) == 93 {
                        let raw = v.substring(with: NSRange(location: start, length: k - start))
                        let lead = raw.prefix { $0 == " " }.utf16.count
                        let item = raw.trimmingCharacters(in: .whitespaces)
                        consider(item, NSRange(location: e.valueRange.location + start + lead, length: item.utf16.count))
                        start = k + 1
                        if k < v.length, v.character(at: k) == 93 { break }
                    }
                    k += 1
                }
            } else {
                consider(e.value, e.valueRange)
            }
        }
        guard let fix = RulesHintProvider.spanEdit(input.text, edits) else { return nil }
        var short = example
        while short.hasSuffix("0") { short.removeLast() }
        return LintFinding(kind: .fix, title: String(localized: "Version \(example) reads as the number \(short). Quote it?"),
                           detail: String(localized: "Unquoted, YAML makes \(example) a number, and the trailing zero goes: CI then installs \(short). In quotes it stays “\(example)”.\(RulesHintProvider.andMore(edits.count))"),
                           range: fix.range, replacement: fix.replacement)
    }

    // MARK: JSON duplicate keys

    /// The first key repeated in one object: (its first range, the repeat's range, how many repeats).
    static func jsonDuplicate(_ s: NSString) -> (first: NSRange, again: NSRange, count: Int)? {
        enum Frame { case object(keys: [String: NSRange], expectKey: Bool), array }
        var stack: [Frame] = []
        var found: (NSRange, NSRange)?, count = 0
        let n = s.length
        var i = 0
        while i < n {
            let c = s.character(at: i)
            switch c {
            case 123: stack.append(.object(keys: [:], expectKey: true))
            case 91: stack.append(.array)
            case 125, 93: if !stack.isEmpty { stack.removeLast() }
            case 44:
                if case .object(let keys, _)? = stack.last { stack[stack.count - 1] = .object(keys: keys, expectKey: true) }
            case 47 where i + 1 < n && s.character(at: i + 1) == 47:
                while i < n, s.character(at: i) != 10 { i += 1 }
                continue
            case 47 where i + 1 < n && s.character(at: i + 1) == 42:
                i += 2
                while i + 1 < n, !(s.character(at: i) == 42 && s.character(at: i + 1) == 47) { i += 1 }
                i += 2
                continue
            case 34:
                let start = i
                i += 1
                while i < n, s.character(at: i) != 34 { i += s.character(at: i) == 92 ? 2 : 1 }
                i += 1
                let r = NSRange(location: start, length: min(i, n) - start)
                if case .object(var keys, true)? = stack.last {
                    let k = s.substring(with: r)
                    if let first = keys[k] {
                        count += 1
                        if found == nil { found = (first, r) }
                    } else {
                        keys[k] = r
                    }
                    stack[stack.count - 1] = .object(keys: keys, expectKey: false)
                }
                continue
            default: break
            }
            i += 1
        }
        guard let f = found else { return nil }
        return (f.0, f.1, count)
    }

    static let jsonDuplicateKey = LintRule(jsonDuplicateID, wholeDocument: true, applies: LintRule.languages(["json"])) { input in
        guard input.string.contains("\":") || input.string.contains("\" :") else { return nil }
        guard let d = jsonDuplicate(input.text) else { return nil }
        let key = input.text.substring(with: d.again)
        return LintFinding(kind: .warning, title: String(localized: "\(String(key.prefix(28))) appears twice in one object."),
                           detail: String(localized: "Most readers keep only the last one, so the first (\(input.at(d.first.location))) is silently ignored.\(RulesHintProvider.andMore(d.count))"),
                           range: d.again)
    }

    // MARK: XML, plist and SVG that don't parse

    final class XMLErrorCatcher: NSObject, XMLParserDelegate {
        var error: Error?
        var line = 0
        func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
            if error == nil { error = parseError; line = parser.lineNumber }
        }
    }

    static func xmlProblem(_ s: String) -> (line: Int, message: String)? {
        guard let data = s.data(using: .utf8) else { return nil }
        let p = XMLParser(data: data)
        p.shouldResolveExternalEntities = false   // never loads a DTD or anything else
        let catcher = XMLErrorCatcher()
        p.delegate = catcher
        if p.parse() { return nil }
        let line = catcher.line > 0 ? catcher.line : p.lineNumber
        // The delegate's error is the specific one; parserError may be a generic 111.
        let code = ((catcher.error ?? p.parserError) as NSError?)?.code ?? 0
        let message: String
        switch XMLParser.ErrorCode(rawValue: code) {
        case .tagNameMismatchError?: message = String(localized: "a closing tag doesn’t match the tag it closes")
        case .prematureDocumentEndError?: message = String(localized: "it ends before every tag is closed")
        case .undeclaredEntityError?, .entityRefAtEOFError?, .entityRefLoopError?, .entityNotFinishedError?:
            message = String(localized: "an “&” starts an entity XML doesn’t know (write “&amp;” for a plain &)")
        case .lessThanSymbolInAttributeError?: message = String(localized: "a “<” inside an attribute value (write “&lt;”)")
        case .attributeNotStartedError?, .attributeNotFinishedError?, .attributeRedefinedError?:
            message = String(localized: "an attribute is unquoted, unfinished or repeated")
        case .extraContentError?: message = String(localized: "there is more after the root element closes")
        default: message = String(localized: "it isn’t well-formed XML")
        }
        return (line, message)
    }

    static let xmlInvalid = LintRule(xmlInvalidID, wholeDocument: true, applies: { l, name in
        l == "xml" || RulesHintProvider.ext(name) == "svg"
    }) { input in
        // While typing, a half-written tag is normal: only once saved.
        guard input.facts.unsavedSince == nil, input.string.contains("<") else { return nil }
        let t = input.string
        if isTemplated(t) || t.contains("<?php") { return nil }
        let plist = RulesHintProvider.ext(input.fileName) == "plist"
        let kind = plist ? "plist" : RulesHintProvider.ext(input.fileName) == "svg" ? "SVG" : "XML"
        if let p = xmlProblem(t) {
            let lineRange = p.line >= 1 && p.line <= input.lines.count ? input.lines[p.line - 1] : nil
            return LintFinding(kind: .warning, title: String(localized: "This \(kind) doesn’t parse (line \(p.line))."),
                               detail: String(localized: "The parser stopped: \(p.message). Apps reading the file will refuse it or read only part of it."),
                               range: lineRange)
        }
        if plist, let data = t.data(using: .utf8) {
            do { _ = try PropertyListSerialization.propertyList(from: data, format: nil) } catch {
                return LintFinding(kind: .warning, title: String(localized: "This plist is valid XML but not a valid plist."),
                                   detail: String(localized: "macOS can’t read it as a property list: a <key> without a value, or a tag a plist doesn’t allow."))
            }
        }
        return nil
    }

    // MARK: TOML

    static let isTOML = RulesHintProvider.isTOMLFile

    struct TOMLLine {
        enum Kind { case table(String), arrayTable(String), key(String, value: String, valueRange: NSRange) }
        var kind: Kind
        var range: NSRange   // the header or key, for Show Me
        var line: Int
    }

    static let tomlHeader = try! NSRegularExpression(pattern: #"^[ \t]*(\[\[?)[ \t]*([^\]#]+?)[ \t]*\]\]?[ \t]*(#.*)?$"#)
    static let tomlKey = try! NSRegularExpression(pattern: #"^[ \t]*((?:[A-Za-z0-9_-]+|"[^"\n]*"|'[^'\n]*')(?:[ \t]*\.[ \t]*(?:[A-Za-z0-9_-]+|"[^"\n]*"|'[^'\n]*'))*)[ \t]*=[ \t]*"#)

    /// Headers and `key = value` lines, skipping multi-line strings and arrays.
    static func tomlLines(_ s: NSString, lines: [NSRange]) -> [TOMLLine] {
        var out: [TOMLLine] = []
        var inString: String?    // """ or '''
        var arrayDepth = 0
        for (index, r) in lines.enumerated() {
            let line = s.substring(with: r)
            if let q = inString {
                if line.contains(q) { inString = nil }
                continue
            }
            if arrayDepth > 0 { arrayDepth = max(0, arrayDepth + flowBalance(line)); continue }
            let ns = line as NSString
            let all = NSRange(location: 0, length: ns.length)
            if let m = tomlHeader.firstMatch(in: line, range: all) {
                let name = ns.substring(with: m.range(at: 2)).replacingOccurrences(of: " ", with: "")
                let header = NSRange(location: r.location + m.range.location, length: m.range.length)
                out.append(TOMLLine(kind: ns.substring(with: m.range(at: 1)) == "[[" ? .arrayTable(name) : .table(name), range: header, line: index))
                continue
            }
            guard let m = tomlKey.firstMatch(in: line, range: all) else { continue }
            let key = ns.substring(with: m.range(at: 1)).replacingOccurrences(of: " ", with: "")
            let (value, vr) = scalarValue(ns, from: NSMaxRange(m.range), base: r.location)
            for q in ["\"\"\"", "'''"] where value.hasPrefix(q) {
                if !value.dropFirst(3).contains(q) { inString = q }
            }
            if value.hasPrefix("[") { arrayDepth = max(0, flowBalance(value)) }
            out.append(TOMLLine(kind: .key(key, value: value, valueRange: vr),
                                range: NSRange(location: r.location + m.range(at: 1).location, length: m.range(at: 1).length), line: index))
        }
        return out
    }

    static let tomlDuplicate = LintRule(tomlDuplicateID, wholeDocument: true, applies: isTOML) { input in
        guard !isTemplated(input.string) else { return nil }
        var tables: Set<String> = []
        var keys: Set<String> = []
        var current = ""
        var arrayCount: [String: Int] = [:]
        var dups: [(TOMLLine, String)] = []
        for l in input.shared("toml", { tomlLines(input.text, lines: input.lines) }) {
            switch l.kind {
            case .arrayTable(let name):
                // A new element: the tables and keys under the old one are gone.
                arrayCount[name, default: 0] += 1
                tables = tables.filter { !$0.hasPrefix(name + ".") }
                keys = keys.filter { !$0.hasPrefix(name + ".") && !$0.hasPrefix(name + "|") }
                current = name
            case .table(let name):
                if tables.contains(name) { dups.append((l, "[\(name)]")) }
                tables.insert(name)
                current = name
            case .key(let k, _, _):
                let full = current + "|" + k
                if keys.contains(full) { dups.append((l, k)) }
                keys.insert(full)
            }
        }
        guard let d = dups.first else { return nil }
        return LintFinding(kind: .warning, title: String(localized: "“\(String(d.1.prefix(30)))” is defined twice."),
                           detail: String(localized: "TOML doesn’t allow a table or a key twice (line \(d.0.line + 1)): the file won’t load.\(RulesHintProvider.andMore(dups.count))"),
                           range: d.0.range)
    }

    static let tomlNumber = try! NSRegularExpression(pattern: #"^[+-]?(\d[\d_]*(\.\d[\d_]*)?([eE][+-]?\d[\d_]*)?|0x[0-9a-fA-F_]+|0o[0-7_]+|0b[01_]+|inf|nan)$"#)
    static let tomlDate = try! NSRegularExpression(pattern: #"^\d{4}-\d{2}-\d{2}([Tt ]\d{2}:\d{2}(:\d{2}(\.\d+)?)?([Zz]|[+-]\d{2}:\d{2})?)?$|^\d{2}:\d{2}:\d{2}(\.\d+)?$"#)

    /// A TOML value that isn't any of TOML's types: a bare word.
    static func isBareString(_ v: String) -> Bool {
        guard let f = v.first else { return false }
        if "\"'[{".contains(f) || v == "true" || v == "false" { return false }
        let r = NSRange(location: 0, length: (v as NSString).length)
        return tomlNumber.firstMatch(in: v, range: r) == nil && tomlDate.firstMatch(in: v, range: r) == nil
    }

    static let tomlBareString = LintRule(tomlBareID, applies: isTOML) { input in
        guard !isTemplated(input.string) else { return nil }
        var edits: [(NSRange, String)] = []
        var example = ""
        for l in input.shared("toml", { tomlLines(input.text, lines: input.lines) }) {
            guard case .key(_, let value, let vr) = l.kind, isBareString(value) else { continue }
            if example.isEmpty { example = value }
            edits.append((vr, "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""))
        }
        guard let fix = RulesHintProvider.spanEdit(input.text, edits) else { return nil }
        return LintFinding(kind: .fix, title: String(localized: "TOML text needs quotes: “\(String(example.prefix(20)))”. Add them?"),
                           detail: String(localized: "A TOML value is a string in quotes, a number, true or false, a date, a list or a table; a bare word stops the file loading.\(RulesHintProvider.andMore(edits.count))"),
                           range: fix.range, replacement: fix.replacement)
    }

    // MARK: .env

    static let isEnv = RulesHintProvider.isEnvFile

    struct EnvLine { var key: String; var keyRange: NSRange; var eq: NSRange; var value: String; var line: Int }

    static let envAssignment = try! NSRegularExpression(pattern: #"^[ \t]*(?:export[ \t]+)?([A-Za-z_][A-Za-z0-9_.]*)([ \t]*=[ \t]*)(.*)$"#)

    /// `KEY=value` lines, skipping comments and the rest of a quoted value
    /// that runs over several lines.
    static func envLines(_ s: NSString, lines: [NSRange]) -> [EnvLine] {
        var out: [EnvLine] = []
        var open: unichar = 0
        for (index, r) in lines.enumerated() {
            let line = s.substring(with: r)
            let ns = line as NSString
            if open != 0 {
                if ns.range(of: String(utf16CodeUnits: [open], count: 1)).location != NSNotFound { open = 0 }
                continue
            }
            guard let m = envAssignment.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { continue }
            let value = ns.substring(with: m.range(at: 3))
            if let q = value.utf16.first, q == 34 || q == 39, !closedQuote(value, q) { open = q }
            out.append(EnvLine(key: ns.substring(with: m.range(at: 1)),
                               keyRange: NSRange(location: r.location + m.range(at: 1).location, length: m.range(at: 1).length),
                               eq: NSRange(location: r.location + m.range(at: 2).location, length: m.range(at: 2).length),
                               value: value, line: index))
        }
        return out
    }

    static let envSpaces = LintRule(envSpacesID, applies: isEnv) { input in
        guard input.string.contains(" =") || input.string.contains("= ") || input.string.contains("\t=") || input.string.contains("=\t") else { return nil }
        var edits: [(NSRange, String)] = []
        var example = ""
        for l in input.shared("env", { envLines(input.text, lines: input.lines) }) where l.eq.length > 1 && !l.value.trimmingCharacters(in: .whitespaces).isEmpty {
            if example.isEmpty { example = l.key }
            edits.append((l.eq, "="))
        }
        guard let fix = RulesHintProvider.spanEdit(input.text, edits) else { return nil }
        return LintFinding(kind: .fix, title: String(localized: "Spaces around “=” after \(String(example.prefix(24))). Remove them?"),
                           detail: String(localized: "“source .env” runs “KEY = value” as a command, and Docker keeps the spaces in the name or the value.\(RulesHintProvider.andMore(edits.count))"),
                           range: fix.range, replacement: fix.replacement)
    }

    static let envDuplicateKey = LintRule(envDuplicateID, wholeDocument: true, applies: isEnv) { input in
        var seen: [String: EnvLine] = [:]
        var dups: [(EnvLine, EnvLine)] = []
        for l in input.shared("env", { envLines(input.text, lines: input.lines) }) {
            if let first = seen[l.key] { dups.append((first, l)) } else { seen[l.key] = l }
        }
        guard let d = dups.first else { return nil }
        return LintFinding(kind: .warning, title: String(localized: "\(String(d.1.key.prefix(30))) is set twice."),
                           detail: String(localized: "Line \(d.1.line + 1) replaces line \(d.0.line + 1) (or is ignored, depending on the tool reading it).\(RulesHintProvider.andMore(dups.count))"),
                           range: d.1.keyRange)
    }
}

extension LintInput {
    /// The YAML entries and their structure, read once per query.
    var yaml: (entries: [ConfigRules.YAMLEntry], structure: (duplicates: [(first: ConfigRules.YAMLEntry, again: ConfigRules.YAMLEntry)], parent: [Int: String])) {
        shared("yaml") {
            let e = ConfigRules.yamlEntries(text, lines: lines)
            return (e, ConfigRules.yamlStructure(e))
        }
    }
}
