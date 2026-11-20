import Foundation

// Ask Cedric (the owl's chat panel): the pure parts. A frozen snapshot of
// the document taken when the user asks, the context the model is shown,
// the quick actions, the owl's six read-only tools and the edit proposal
// that becomes a diff the user applies (or not). No AppKit, no engines:
// the engines are in CedricAI, the panel in the app.

// MARK: - JSON values

/// A JSON value that is Sendable and Equatable (tool arguments, schemas).
public enum OwlJSON: Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([OwlJSON])
    case object([String: OwlJSON])

    /// From JSONSerialization output.
    public init(any value: Any) {
        switch value {
        case let s as String: self = .string(s)
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { self = .bool(n.boolValue) } else { self = .number(n.doubleValue) }
        case let a as [Any]: self = .array(a.map { OwlJSON(any: $0) })
        case let d as [String: Any]: self = .object(d.mapValues { OwlJSON(any: $0) })
        default: self = .null
        }
    }

    /// For JSONSerialization.
    public var any: Any {
        switch self {
        case .string(let s): return s
        case .number(let n): return n.rounded() == n && abs(n) < 1e15 ? Int(n) as Any : n as Any
        case .bool(let b): return b
        case .null: return NSNull()
        case .array(let a): return a.map(\.any)
        case .object(let o): return o.mapValues(\.any)
        }
    }

    /// Parses JSON text; nil if it isn't JSON.
    public static func parse(_ text: String) -> OwlJSON? {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return nil }
        return OwlJSON(any: obj)
    }

    /// Compact JSON, keys sorted (stable for tests and prompts).
    public var jsonString: String {
        if case .string(let s) = self {
            let d = (try? JSONSerialization.data(withJSONObject: [s], options: [])) ?? Data()
            let t = String(decoding: d, as: UTF8.self)
            return String(t.dropFirst().dropLast())
        }
        guard let d = try? JSONSerialization.data(withJSONObject: any, options: [.sortedKeys, .fragmentsAllowed]) else { return "null" }
        return String(decoding: d, as: UTF8.self)
    }

    public subscript(key: String) -> OwlJSON? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    public var string: String? {
        switch self {
        case .string(let s): return s
        case .number(let n): return n.rounded() == n ? String(Int(n)) : String(n)
        case .bool(let b): return b ? "true" : "false"
        default: return nil
        }
    }

    /// Integers, also from "12" (small models quote numbers).
    public var int: Int? {
        switch self {
        case .number(let n): return n.isFinite && abs(n) < 1e9 ? Int(n) : nil
        case .string(let s): return Int(s.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }

    public var bool: Bool? {
        switch self {
        case .bool(let b): return b
        case .string(let s): return s == "true" ? true : s == "false" ? false : nil
        case .number(let n): return n != 0
        default: return nil
        }
    }

    public var object: [String: OwlJSON]? {
        if case .object(let o) = self { return o }
        return nil
    }
}

// MARK: - The document, frozen

/// The document as it was when the user asked: every tool reads this, never
/// the live text view, so a call can't race typing, and a proposal can be
/// checked against it before it is applied.
public struct OwlDocumentSnapshot: Sendable {
    public let text: String
    /// The document's edit generation (change count) at the snapshot.
    public let generation: Int
    /// UTF-16 ranges in `text`.
    public let selection: NSRange
    public let visible: NSRange
    public let fileName: String?
    /// `Language.rawValue`.
    public let language: String
    public let lines: LineIndex

    public init(text: String, generation: Int, selection: NSRange = NSRange(location: 0, length: 0),
                visible: NSRange? = nil, fileName: String? = nil, language: String = "plain") {
        let ns = text as NSString
        self.text = text
        self.generation = generation
        func clamp(_ r: NSRange) -> NSRange {
            let s = min(max(0, r.location), ns.length)
            return NSRange(location: s, length: min(max(0, r.length), ns.length - s))
        }
        self.selection = clamp(selection)
        self.visible = clamp(visible ?? NSRange(location: 0, length: ns.length))
        self.fileName = fileName
        self.language = language
        self.lines = LineIndex(ns)
    }

    public var length: Int { (text as NSString).length }
    public var lineCount: Int { lines.lineCount }
    public var hasSelection: Bool { selection.length > 0 }

    /// 1-based line number of a UTF-16 offset.
    public func lineNumber(at offset: Int) -> Int { lines.line(containing: min(max(0, offset), length)) + 1 }

    /// The range of lines `first...last` (1-based, inclusive, clamped),
    /// without the last line's newline; nil if `first` is past the end.
    public func range(lines first: Int, _ last: Int) -> NSRange? {
        let n = lineCount
        let a = max(1, first), b = min(n, max(a, last))
        guard a <= n else { return nil }
        let start = lines.contentRange(ofLine: a - 1).location
        let end = NSMaxRange(lines.contentRange(ofLine: b - 1))
        return NSRange(location: start, length: end - start)
    }

    public func substring(_ r: NSRange) -> String { (text as NSString).substring(with: r) }

    /// The whole lines touching `r`, as a range (no trailing newline).
    public func lineSpan(_ r: NSRange) -> (range: NSRange, first: Int, last: Int) {
        let first = lineNumber(at: r.location)
        let endOffset = r.length > 0 ? NSMaxRange(r) - 1 : r.location
        var last = lineNumber(at: endOffset)
        // A selection that ends just after a newline doesn't take the next line.
        if r.length > 0, last > first, endOffset < length, (text as NSString).character(at: endOffset) == 10 {
            last = max(first, last - (lines.starts[last - 1] > endOffset ? 1 : 0))
        }
        let range = self.range(lines: first, last) ?? NSRange(location: 0, length: 0)
        return (range, first, last)
    }

    /// "12| text" for each line in `first...last`.
    public func numbered(lines first: Int, _ last: Int) -> String {
        guard let r = range(lines: first, last) else { return "" }
        let body = substring(r).components(separatedBy: "\n")
        return body.enumerated().map { "\(first + $0.offset)| \($0.element)" }.joined(separator: "\n")
    }
}

// MARK: - What the model is shown

public enum OwlChatScope: String, Sendable, CaseIterable {
    case selection, visible, wholeDocument

    public var title: String {
        switch self {
        case .selection: return String(localized: "Selection")
        case .visible: return String(localized: "Visible text")
        case .wholeDocument: return String(localized: "Whole document")
        }
    }
}

/// The text attached to a question: whole lines, numbered with their real
/// line numbers ("12| "), so answers and edits can cite them.
public struct OwlChatContext: Sendable, Equatable {
    public let scope: OwlChatScope
    /// Document range of the lines shown (no trailing newline).
    public let range: NSRange
    public let firstLine: Int
    public let lastLine: Int
    public let numbered: String
    /// Some lines were left out to fit the budget.
    public let truncated: Bool

    /// "Selection (12 lines)", for the chip.
    public var label: String {
        let n = lastLine - firstLine + 1
        let lines = n == 1 ? String(localized: "1 line") : String(localized: "\(n) lines")
        return "\(scope.title) (\(lines)\(truncated ? ", " + String(localized: "trimmed") : ""))"
    }

    /// The scopes that can be offered: Selection only with a selection,
    /// Whole document only when it fits `budget` (UTF-16 units).
    public static func scopes(for s: OwlDocumentSnapshot, budget: Int) -> [OwlChatScope] {
        var out: [OwlChatScope] = []
        if s.hasSelection { out.append(.selection) }
        out.append(.visible)
        if s.length + s.lineCount * 6 <= budget { out.append(.wholeDocument) }
        return out
    }

    /// Selection if there is one, else the visible text.
    public static func defaultScope(for s: OwlDocumentSnapshot) -> OwlChatScope { s.hasSelection ? .selection : .visible }

    /// The context for `scope`, at most `budget` UTF-16 units of numbered
    /// text (lines past it are dropped from the end, never split). nil
    /// when the scope isn't available (no selection; doesn't fit).
    public static func build(_ s: OwlDocumentSnapshot, scope: OwlChatScope, budget: Int) -> OwlChatContext? {
        let span: (range: NSRange, first: Int, last: Int)
        switch scope {
        case .selection:
            guard s.hasSelection else { return nil }
            span = s.lineSpan(s.selection)
        case .visible:
            span = s.lineSpan(s.visible)
        case .wholeDocument:
            guard scopes(for: s, budget: budget).contains(.wholeDocument) else { return nil }
            span = (s.range(lines: 1, s.lineCount) ?? NSRange(location: 0, length: 0), 1, s.lineCount)
        }
        var last = span.last
        var used = 0
        for line in span.first...span.last {
            let len = s.lines.contentRange(ofLine: line - 1).length + String(line).count + 3
            if used + len > budget, line > span.first { last = line - 1; break }
            used += len
        }
        let range = s.range(lines: span.first, last) ?? span.range
        return OwlChatContext(scope: scope, range: range, firstLine: span.first, lastLine: last,
                              numbered: s.numbered(lines: span.first, last), truncated: last < span.last)
    }
}

// MARK: - Quick actions

/// The panel's one-click questions. Each is a fixed, tested instruction
/// (OwlPrompts in CedricAI), which small models follow far better than
/// free text, and a small subset of the tools.
public enum OwlQuickAction: String, Sendable, CaseIterable {
    case explain, summarise, findProblems, rewrite, addComments
    /// Code: the selection, or the caret's line, explained.
    case explainLine
    /// Scripts: the offline scan (`ScriptSafety`), then the model's review.
    case scriptSafety

    public func title(prose: Bool) -> String {
        switch self {
        case .explainLine: return String(localized: "Explain Line")
        case .scriptSafety: return String(localized: "Check for Risks")
        case .explain: return String(localized: "Explain")
        case .summarise: return String(localized: "Summarise")
        case .findProblems: return String(localized: "Find Problems")
        case .rewrite: return prose ? String(localized: "Rewrite") : String(localized: "Simplify")
        case .addComments: return String(localized: "Add Comments")
        }
    }

    /// The answer is an edit (a proposal shown as a diff), not just words.
    public var proposesEdit: Bool { self == .rewrite || self == .addComments }

    /// Offered for this document: Summarise and Rewrite read prose; Explain
    /// Line and the script check are for code (the check only for scripts).
    public func isOffered(prose: Bool, language: Language) -> Bool {
        switch self {
        case .summarise: return prose
        case .addComments, .explainLine: return !prose
        case .scriptSafety: return !prose && ScriptSafety.isScript(language)
        default: return true
        }
    }

    /// The tools the model may use for this action.
    public var tools: [OwlToolName] {
        switch self {
        case .explain: return [.getLines, .searchDocument, .getOutline]
        case .summarise: return [.getOutline, .getLines, .documentStats]
        case .findProblems: return [.getLines, .searchDocument]
        case .rewrite: return [.getSelection, .getLines, .proposeEdit]
        case .addComments: return [.getLines, .proposeEdit]
        case .explainLine: return [.getLines, .searchDocument]
        case .scriptSafety: return [.getLines, .searchDocument]
        }
    }
}

// MARK: - Tools

public enum OwlToolName: String, Sendable, CaseIterable {
    case getSelection = "get_selection"
    case getLines = "get_lines"
    case searchDocument = "search_document"
    case getOutline = "get_outline"
    case documentStats = "document_stats"
    case proposeEdit = "propose_edit"
}

/// A tool as the model sees it: a name, one line of description and a
/// JSON schema for its arguments.
public struct OwlToolSpec: Sendable, Equatable {
    public let name: OwlToolName
    public let description: String
    /// A JSON-schema object: {"type":"object","properties":{…},"required":[…]}.
    public let parameters: OwlJSON
}

/// A call the model asked for.
public struct OwlToolCall: Sendable, Equatable {
    public var id: String
    public var name: String
    public var arguments: OwlJSON

    public init(id: String = "", name: String, arguments: OwlJSON = .object([:])) {
        self.id = id; self.name = name; self.arguments = arguments
    }
}

/// An edit the model proposed: shown as a diff, applied only by the user,
/// and only while the document is still what the model saw.
public struct OwlEditProposal: Sendable, Equatable {
    /// Document range (UTF-16) of the lines being replaced.
    public let range: NSRange
    public let original: String
    public let replacement: String
    public let reason: String
    public let firstLine: Int
    public let lastLine: Int
    /// The snapshot's edit generation.
    public let generation: Int

    public init(range: NSRange, original: String, replacement: String, reason: String,
                firstLine: Int, lastLine: Int, generation: Int) {
        self.range = range; self.original = original; self.replacement = replacement; self.reason = reason
        self.firstLine = firstLine; self.lastLine = lastLine; self.generation = generation
    }

    /// Lines `first...last` of the snapshot replaced by `text`; nil when
    /// the lines don't exist, the edit is empty or no change, or too big.
    public static func lines(_ first: Int, _ last: Int, with text: String, reason: String = "",
                             in s: OwlDocumentSnapshot) -> OwlEditProposal? {
        guard first >= 1, last >= first, first <= s.lineCount, last - first < OwlTools.maxEditLines,
              (text as NSString).length <= OwlTools.maxEditLength,
              let r = s.range(lines: first, min(last, s.lineCount)) else { return nil }
        let original = s.substring(r)
        var replacement = text
        // Models often end with a newline the range doesn't have.
        if replacement.hasSuffix("\n"), !original.hasSuffix("\n") { replacement.removeLast() }
        guard replacement != original else { return nil }
        return OwlEditProposal(range: r, original: original, replacement: replacement, reason: reason,
                               firstLine: first, lastLine: min(last, s.lineCount), generation: s.generation)
    }

    /// The edit can be applied to the live document: same generation and
    /// the same text still in its range. Otherwise it is stale ("Ask
    /// again").
    public func isCurrent(text: NSString, generation: Int) -> Bool {
        guard generation == self.generation, NSMaxRange(range) <= text.length else { return false }
        return text.substring(with: range) == original
    }

    /// The diff rows (LineDiff) between the original and the replacement.
    public var diffLines: [(kind: LineDiff.RowKind, text: String)] {
        let a = LineDiff.lines(original), b = LineDiff.lines(replacement)
        var out: [(LineDiff.RowKind, String)] = []
        for row in LineDiff.rows(LineDiff.diff(a, b)) {
            switch row.kind {
            case .same: out.append((.same, a[row.left!]))
            case .removed: out.append((.removed, a[row.left!]))
            case .added: out.append((.added, b[row.right!]))
            case .changed:
                out.append((.removed, a[row.left!]))
                out.append((.added, b[row.right!]))
            }
        }
        return out
    }

    /// "- old" / "+ new" / "  same", for the transcript's Markdown copy.
    public var unifiedText: String {
        diffLines.map { ($0.kind == .removed ? "- " : $0.kind == .added ? "+ " : "  ") + $0.text }.joined(separator: "\n")
    }
}

/// What a tool returned: text for the model, and possibly a proposal.
public struct OwlToolResult: Sendable, Equatable {
    public var text: String
    public var proposal: OwlEditProposal?
    /// One line for the transcript ("Looked at lines 40–80").
    public var summary: String
    public var ok: Bool

    public init(text: String, proposal: OwlEditProposal?, summary: String, ok: Bool) {
        self.text = text; self.proposal = proposal; self.summary = summary; self.ok = ok
    }
}

/// The owl's v1 tools. All read the frozen snapshot; none touches the
/// network, a shell or any file; `propose_edit` only proposes. Output is
/// capped so a tool can't flood a 4K-token context.
public enum OwlTools {
    public static let maxOutputBytes = 1500
    public static let maxLines = 120
    public static let maxMatches = 20
    public static let maxPatternLength = 200
    /// A model-written regular expression: shorter, and a time limit on the search.
    public static let maxRegexLength = 100
    public static let searchTimeLimit: TimeInterval = 0.5
    /// Tool rounds per question, then the model must answer.
    public static let maxRounds = 3
    /// Calls honoured per round (more are refused).
    public static let maxCallsPerRound = 4
    public static let maxEditLines = 400
    public static let maxEditLength = 32_768

    public static func spec(_ name: OwlToolName) -> OwlToolSpec {
        func obj(_ props: [String: OwlJSON], required: [String]) -> OwlJSON {
            .object(["type": .string("object"), "properties": .object(props), "required": .array(required.map { .string($0) })])
        }
        let int: OwlJSON = .object(["type": .string("integer")])
        let str: OwlJSON = .object(["type": .string("string")])
        switch name {
        case .getSelection:
            return OwlToolSpec(name: name, description: "The user's selected text, with line numbers.", parameters: obj([:], required: []))
        case .getLines:
            return OwlToolSpec(name: name, description: "Lines start to end of the document (1-based, at most 120), with line numbers.",
                               parameters: obj(["start": int, "end": int], required: ["start", "end"]))
        case .searchDocument:
            return OwlToolSpec(name: name, description: "Finds lines containing query (regex if regex is true); returns line numbers and text.",
                               parameters: obj(["query": .object(["type": .string("string"), "maxLength": .number(Double(maxPatternLength))]),
                                                "regex": .object(["type": .string("boolean")])], required: ["query"]))
        case .getOutline:
            return OwlToolSpec(name: name, description: "The document's headings or top-level structure, with line numbers.", parameters: obj([:], required: []))
        case .documentStats:
            return OwlToolSpec(name: name, description: "Words, lines, characters, language and file name of the document.", parameters: obj([:], required: []))
        case .proposeEdit:
            return OwlToolSpec(name: name, description: "Proposes replacing lines start to end with new_text. The user reviews and applies it.",
                               parameters: obj(["start": int, "end": int, "new_text": str, "reason": str], required: ["start", "end", "new_text"]))
        }
    }

    public static func specs(_ names: [OwlToolName]) -> [OwlToolSpec] { names.map(spec) }

    /// Caps `s` at `maxOutputBytes` of UTF-8 on a line boundary where possible.
    public static func cap(_ s: String, bytes: Int = maxOutputBytes) -> String {
        guard s.utf8.count > bytes else { return s }
        var out = ""
        var used = 0
        for line in s.components(separatedBy: "\n") {
            let n = line.utf8.count + 1
            if used + n > bytes - 20 {
                if out.isEmpty { out = String(decoding: Array(line.utf8.prefix(bytes - 20)), as: UTF8.self) }
                break
            }
            out += (out.isEmpty ? "" : "\n") + line
            used += n
        }
        return out + "\n[… cut]"
    }

    /// Runs `call` on the snapshot. Unknown tools, bad arguments and
    /// refusals come back as `ok: false` with a short reason the model
    /// can act on.
    public static func run(_ call: OwlToolCall, on s: OwlDocumentSnapshot, allowed: Set<OwlToolName> = Set(OwlToolName.allCases)) -> OwlToolResult {
        func fail(_ why: String) -> OwlToolResult { OwlToolResult(text: "error: " + why, proposal: nil, summary: why, ok: false) }
        guard let name = OwlToolName(rawValue: call.name) else { return fail("unknown tool \(call.name.prefix(40))") }
        guard allowed.contains(name) else { return fail("\(name.rawValue) is not available for this question") }
        let a = call.arguments
        switch name {
        case .getSelection:
            guard s.hasSelection else { return OwlToolResult(text: "(nothing selected)", proposal: nil, summary: String(localized: "Looked at the selection"), ok: true) }
            let span = s.lineSpan(s.selection)
            let text = s.substring(s.selection)
            let body = text.count <= 1500
                ? "Selected text (lines \(span.first)-\(span.last)):\n" + s.numbered(lines: span.first, span.last)
                : "Selected text (lines \(span.first)-\(span.last)), first part:\n" + s.numbered(lines: span.first, min(span.last, span.first + maxLines - 1))
            return OwlToolResult(text: cap(body), proposal: nil, summary: String(localized: "Looked at the selection"), ok: true)
        case .getLines:
            guard let start = a["start"]?.int else { return fail("get_lines needs start and end") }
            let end = a["end"]?.int ?? start
            guard start >= 1, start <= s.lineCount else { return fail("start must be 1...\(s.lineCount)") }
            let last = min(s.lineCount, max(start, min(end, start + maxLines - 1)))
            return OwlToolResult(text: cap(s.numbered(lines: start, last)), proposal: nil,
                                 summary: String(localized: "Looked at lines \(start)–\(last)"), ok: true)
        case .searchDocument:
            guard let q = a["query"]?.string, !q.isEmpty else { return fail("search_document needs a query") }
            guard q.count <= maxPatternLength else { return fail("query too long") }
            let regex = a["regex"]?.bool ?? false
            // The model writes the pattern, and a prompt injection in the
            // document can ask for a catastrophic one: shorter for a regex,
            // and the search stops at a time limit with an error the model
            // can act on (security review 0.2.1).
            guard !regex || q.count <= maxRegexLength else { return fail("regular expression too long (at most \(maxRegexLength) characters)") }
            let re: NSRegularExpression
            do {
                re = try NSRegularExpression(pattern: regex ? q : NSRegularExpression.escapedPattern(for: q), options: [.caseInsensitive])
            } catch { return fail("not a valid regular expression") }
            let ns = s.text as NSString
            var lines: [Int] = []
            var seen = Set<Int>()
            var total = 0
            let deadline = Date().addingTimeInterval(searchTimeLimit)
            var timedOut = false
            // .reportProgress: called now and then during a long match too,
            // so a pattern that backtracks forever can be stopped.
            re.enumerateMatches(in: s.text, options: [.reportProgress], range: NSRange(location: 0, length: ns.length)) { m, _, stop in
                if Date() > deadline { timedOut = true; stop.pointee = true; return }
                guard let m else { return }
                let line = s.lineNumber(at: m.range.location)
                if seen.insert(line).inserted {
                    total += 1
                    if lines.count < maxMatches { lines.append(line) }
                }
                if total > 999 { stop.pointee = true }
            }
            if timedOut { return fail("the search took too long and was stopped; use a plain query or a simpler regular expression") }
            let summary = String(localized: "Searched for “\(String(q.prefix(40)))”")
            guard !lines.isEmpty else { return OwlToolResult(text: "no matches", proposal: nil, summary: summary, ok: true) }
            var body = lines.map { l -> String in
                let r = s.lines.contentRange(ofLine: l - 1)
                let t = s.substring(NSRange(location: r.location, length: min(r.length, 200)))
                return "\(l)| \(t)"
            }.joined(separator: "\n")
            if total > lines.count { body += "\n(\(total - lines.count) more lines match)" }
            return OwlToolResult(text: cap(body), proposal: nil, summary: summary, ok: true)
        case .getOutline:
            return OwlToolResult(text: cap(outline(s)), proposal: nil, summary: String(localized: "Read the outline"), ok: true)
        case .documentStats:
            let c = TextStats.count(s.text as NSString, range: NSRange(location: 0, length: s.length))
            var body = "lines: \(s.lineCount)\ncharacters: \(c?.characters ?? s.length)\n"
            if let w = c?.words { body += "words: \(w)\n" }
            body += "language: \(Language(rawValue: s.language)?.displayName ?? s.language)\n"
            if let f = s.fileName { body += "file: \(f)\n" }
            if s.hasSelection { body += "selection: lines \(s.lineSpan(s.selection).first)-\(s.lineSpan(s.selection).last)\n" }
            return OwlToolResult(text: body, proposal: nil, summary: String(localized: "Counted the document"), ok: true)
        case .proposeEdit:
            guard let start = a["start"]?.int, let end = a["end"]?.int, let text = a["new_text"]?.string else {
                return fail("propose_edit needs start, end and new_text")
            }
            guard start >= 1, end >= start, start <= s.lineCount else { return fail("lines must be within 1...\(s.lineCount)") }
            guard end - start < maxEditLines else { return fail("too many lines in one edit") }
            guard let p = OwlEditProposal.lines(start, end, with: text, reason: a["reason"]?.string ?? "", in: s) else {
                return fail("the new text is the same as the old")
            }
            return OwlToolResult(text: "proposed: the user will review the change to lines \(p.firstLine)-\(p.lastLine). Now briefly say what you changed.",
                                 proposal: p, summary: String(localized: "Proposed a change to lines \(p.firstLine)–\(p.lastLine)"), ok: true)
        }
    }

    /// Markdown headings; JSON top-level keys; CSV header; else lines that
    /// start at column 0 and look like declarations (code), at most 60.
    static func outline(_ s: OwlDocumentSnapshot) -> String {
        if s.language == "markdown" || (s.fileName?.lowercased().hasSuffix(".md") ?? false) {
            let h = MarkdownOutline.headings(in: s.text, limit: 60)
            if !h.isEmpty { return h.map { "\($0.line + 1)| " + String(repeating: "#", count: $0.level) + " " + $0.title }.joined(separator: "\n") }
        }
        if s.language == "json", let obj = OwlJSON.parse(s.text)?.object {
            return "top-level keys: " + obj.keys.sorted().prefix(60).joined(separator: ", ")
        }
        if s.language == "csv" || s.language == "tsv" {
            return "header: " + s.substring(s.lines.contentRange(ofLine: 0))
        }
        let decl = try! NSRegularExpression(pattern: #"^(?:export\s+|public\s+|private\s+|static\s+|async\s+)*(?:func|function|def|class|struct|enum|protocol|extension|interface|type|fn|impl|module|sub|procedure|const|let|var)\b"#)
        var out: [String] = []
        let ns = s.text as NSString
        for i in 0..<s.lineCount where out.count < 60 {
            let r = s.lines.contentRange(ofLine: i)
            guard r.length > 0, r.length < 400 else { continue }
            let line = ns.substring(with: r)
            let isHeading = line.hasPrefix("#") && s.language != "python" && s.language != "shell"
            if isHeading || decl.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) != nil {
                out.append("\(i + 1)| \(line)")
            }
        }
        return out.isEmpty ? "(no outline: \(s.lineCount) lines)" : out.joined(separator: "\n")
    }
}

// MARK: - The conversation

/// One entry in a document's Ask Cedric history (kept in memory only).
public struct OwlChatEntry: Sendable, Equatable {
    /// `scan`: the offline script check's findings (no AI).
    public enum Role: String, Sendable { case user, owl, tool, note, scan }
    public var role: Role
    public var text: String
    public var proposal: OwlEditProposal?

    public init(role: Role, text: String, proposal: OwlEditProposal? = nil) {
        self.role = role; self.text = text; self.proposal = proposal
    }

    /// The history as Markdown (Copy as Markdown).
    public static func markdown(_ entries: [OwlChatEntry], fileName: String?) -> String {
        var out = "# Ask Cedric" + (fileName.map { " — \($0)" } ?? "") + "\n"
        for e in entries {
            switch e.role {
            case .user: out += "\n**You:** \(e.text)\n"
            case .owl:
                out += "\n**Cedric:** \(e.text)\n"
                if let p = e.proposal { out += "\n```diff\n\(p.unifiedText)\n```\n" }
            case .tool: out += "\n> _\(e.text)_\n"
            case .note: out += "\n_\(e.text)_\n"
            case .scan: out += "\n**Offline scan:**\n\(e.text)\n"
            }
        }
        return out
    }
}
