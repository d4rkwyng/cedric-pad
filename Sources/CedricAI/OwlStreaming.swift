import Foundation
import CedricCore

// Streaming helpers for Ask Cedric, pure and unit-tested: UTF-8 pieces
// from llama.cpp, Server-Sent Events from LM Studio / Ollama, OpenAI
// delta chunks (text and tool-call fragments), and the built-in engine's
// JSON envelope, whose "answer" string is shown while it is generated.

/// Bytes in, whole characters out: a token can end in the middle of a
/// multi-byte UTF-8 character; the rest waits for the next piece.
public struct UTF8StreamDecoder: Sendable {
    private var pending: [UInt8] = []
    public init() {}

    public mutating func append(_ bytes: [UInt8]) -> String {
        pending += bytes
        // The longest prefix that ends on a character boundary.
        var cut = pending.count
        var i = pending.count - 1
        var back = 0
        while i >= 0, back < 4 {
            let b = pending[i]
            if b & 0b1100_0000 == 0b1000_0000 { i -= 1; back += 1; continue }   // continuation byte
            let need = b & 0b1000_0000 == 0 ? 1 : b & 0b1110_0000 == 0b1100_0000 ? 2 : b & 0b1111_0000 == 0b1110_0000 ? 3 : 4
            if pending.count - i < need { cut = i }
            break
        }
        let out = String(decoding: pending[0..<cut], as: UTF8.self)
        pending.removeFirst(cut)
        return out
    }

    public mutating func flush() -> String {
        defer { pending = [] }
        return String(decoding: pending, as: UTF8.self)
    }
}

/// Server-Sent Events: feed lines, get each `data:` payload ("[DONE]" ends).
public struct SSEParser: Sendable {
    public init() {}
    /// The payload of a `data:` line, nil for anything else.
    public static func payload(_ line: String) -> String? {
        guard line.hasPrefix("data:") else { return nil }
        return String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
    }
}

/// Accumulates OpenAI-style streamed chat chunks: `delta.content` text and
/// `delta.tool_calls` fragments (an index, then the id and name once, and
/// the arguments in pieces).
public struct OpenAIStreamAccumulator: Sendable {
    public private(set) var content = ""
    private var calls: [Int: (id: String, name: String, args: String)] = [:]
    public private(set) var finished = false
    public init() {}

    /// Takes one chunk's JSON; returns the new text in it.
    @discardableResult
    public mutating func add(_ json: String) -> String {
        if json == "[DONE]" { finished = true; return "" }
        guard let obj = OwlJSON.parse(json), let choice = obj["choices"].flatMap({ c -> OwlJSON? in
            if case .array(let a) = c { return a.first }
            return nil
        }) else { return "" }
        if choice["finish_reason"]?.string != nil { finished = true }
        // Ollama's native /api/chat isn't used; a non-stream body here is "message".
        let delta = choice["delta"] ?? choice["message"]
        var new = ""
        if case .string(let t)? = delta?["content"] { new = t; content += t }
        if case .array(let parts)? = delta?["tool_calls"] {
            for (n, p) in parts.enumerated() {
                let i = p["index"]?.int ?? n
                var c = calls[i] ?? ("", "", "")
                if let id = p["id"]?.string, !id.isEmpty { c.id = id }
                if let f = p["function"] {
                    if let name = f["name"]?.string, !name.isEmpty, c.name != name { c.name += name }
                    if case .string(let a)? = f["arguments"] { c.args += a }
                    else if let a = f["arguments"], case .object = a { c.args = a.jsonString }
                }
                calls[i] = c
            }
        }
        return new
    }

    /// The tool calls, arguments parsed (unparseable arguments: empty).
    public var toolCalls: [OwlToolCall] {
        calls.keys.sorted().compactMap { k in
            let c = calls[k]!
            guard !c.name.isEmpty else { return nil }
            let args = c.args.isEmpty ? OwlJSON.object([:]) : (OwlJSON.parse(c.args) ?? .object([:]))
            return OwlToolCall(id: c.id.isEmpty ? "call_\(k)" : c.id, name: c.name, arguments: args)
        }
    }
}

/// The built-in engine's reply envelope, `{"answer":"…"}` or
/// `{"tool":"name","args":{…}}`, parsed as it streams: `answerSoFar`
/// is the decoded answer text generated so far.
public struct EnvelopeStreamParser: Sendable {
    public private(set) var raw = ""
    private var emitted = 0
    public init() {}

    /// Adds generated text; returns the newly decoded part of the answer.
    public mutating func add(_ piece: String) -> String {
        raw += piece
        let answer = Self.partialAnswer(raw)
        guard answer.count > emitted else { return "" }
        let new = String(answer.dropFirst(emitted))
        emitted = answer.count
        return new
    }

    /// The decoded content of the "answer" string so far (an escape cut
    /// in half waits), or "" when the reply isn't an answer.
    public static func partialAnswer(_ raw: String) -> String {
        guard let key = raw.range(of: "\"answer\"") else { return "" }
        var rest = raw[key.upperBound...].drop { $0 == " " || $0 == ":" || $0 == "\n" || $0 == "\t" }
        guard rest.first == "\"" else { return "" }
        rest = rest.dropFirst()
        var out = ""
        var it = rest.makeIterator()
        while let c = it.next() {
            if c == "\"" { break }
            if c == "\\" {
                guard let e = it.next() else { break }
                switch e {
                case "n": out.append("\n")
                case "t": out.append("\t")
                case "r": break
                case "u":
                    var hex = ""
                    for _ in 0..<4 { if let h = it.next() { hex.append(h) } }
                    guard hex.count == 4 else { return out }
                    if let v = UInt32(hex, radix: 16), let s = Unicode.Scalar(v) { out.unicodeScalars.append(s) }
                default: out.append(e)
                }
                continue
            }
            out.append(c)
        }
        return out
    }

    /// The finished envelope: an answer or one tool call.
    public static func parse(_ raw: String) -> OwlTurn? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let start = trimmed.firstIndex(of: "{"), let end = trimmed.lastIndex(of: "}"),
              let obj = OwlJSON.parse(String(trimmed[start...end])) else { return nil }
        if let a = obj["answer"]?.string { return .answer(a) }
        if let t = obj["tool"]?.string ?? obj["name"]?.string {
            return .toolCalls([OwlToolCall(id: "call_0", name: t, arguments: obj["args"] ?? obj["arguments"] ?? .object([:]))])
        }
        return nil
    }

    /// GBNF: either an answer string or one call to one of `tools` with a
    /// flat JSON object of arguments (strings, numbers, booleans).
    public static func grammar(tools: [OwlToolName]) -> String {
        let names = tools.map { "\"\\\"\($0.rawValue)\\\"\"" }.joined(separator: " | ")
        return #"""
        root ::= answer | call
        answer ::= "{" ws "\"answer\"" ws ":" ws string ws "}"
        call ::= "{" ws "\"tool\"" ws ":" ws toolname ws "," ws "\"args\"" ws ":" ws args ws "}"
        toolname ::= \#(names)
        args ::= "{" ws ( pair ( ws "," ws pair )* )? ws "}"
        pair ::= string ws ":" ws value
        value ::= string | number | "true" | "false"
        number ::= "-"? [0-9] [0-9]? [0-9]? [0-9]? [0-9]? [0-9]?
        string ::= "\"" char* "\""
        char ::= [^"\\\x00-\x1F] | "\\" ( ["\\/bfnrt] | "u" [0-9a-fA-F] [0-9a-fA-F] [0-9a-fA-F] [0-9a-fA-F] )
        ws ::= [ \t\n]? [ \t\n]?
        """#
    }
}
