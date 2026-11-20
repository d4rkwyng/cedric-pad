import Foundation
import CedricCore

/// GBNF for the built-in engine's reply envelope, typed per tool: either
/// `{"answer":"…"}` or `{"tool":"<name>","args":{…}}` where `args` follows
/// that tool's JSON schema (`OwlToolSpec.parameters`): exactly its
/// argument names, required ones always present, in a fixed order
/// (required first, in the schema's order, then the optional ones
/// alphabetically), each of its type (integer, number, string, boolean,
/// or one of an `enum`). llama.cpp enforces it while decoding, so a small
/// model can't write `{"start":"40"}`, misspell a key or leave out `end`.
public enum OwlToolGrammar {
    /// The whole envelope grammar for the offered tools.
    public static func envelope(_ tools: [OwlToolSpec]) -> String {
        var rules: [String] = [
            "root ::= answer" + (tools.isEmpty ? "" : " | call"),
            #"answer ::= "{" ws "\"answer\"" ws ":" ws string ws "}""#,
        ]
        if !tools.isEmpty {
            let names = tools.map { "tool-" + ruleName($0.name.rawValue) }
            rules.append(#"call ::= "{" ws "\"tool\"" ws ":" ws ( "# + names.joined(separator: " | ") + " )")
            for (t, n) in zip(tools, names) {
                let argsRule = "args-" + ruleName(t.name.rawValue)
                rules.append("\(n) ::= \(literal(jsonString(t.name.rawValue))) ws \",\" ws \"\\\"args\\\"\" ws \":\" ws \(argsRule) ws \"}\"")
                rules.append("\(argsRule) ::= " + object(t.parameters))
            }
        }
        rules += shared
        return rules.joined(separator: "\n")
    }

    /// The primitives every rule uses. Integers have at most 6 digits,
    /// whitespace is bounded so a model can't stall in it.
    static let shared: [String] = [
        #"integer ::= "-"? [0-9] [0-9]? [0-9]? [0-9]? [0-9]? [0-9]?"#,
        #"number ::= integer ( "." [0-9] [0-9]? [0-9]? [0-9]? )?"#,
        #"boolean ::= "true" | "false""#,
        #"string ::= "\"" char* "\"""#,
        #"char ::= [^"\\\x00-\x1F] | "\\" ( ["\\/bfnrt] | "u" [0-9a-fA-F] [0-9a-fA-F] [0-9a-fA-F] [0-9a-fA-F] )"#,
        #"ws ::= [ \t\n]? [ \t\n]?"#,
    ]

    /// The `args` object for one JSON schema.
    static func object(_ schema: OwlJSON) -> String {
        let props = schema["properties"]?.object ?? [:]
        let required: [String] = {
            guard case .array(let a)? = schema["required"] else { return [] }
            return a.compactMap(\.string).filter { props[$0] != nil }
        }()
        let optional = props.keys.filter { !required.contains($0) }.sorted()
        func pair(_ key: String) -> String {
            "\(literal(jsonString(key))) ws \":\" ws \(value(props[key]!))"
        }
        let sep = #" ws "," ws "#
        if !required.isEmpty {
            var body = required.map(pair).joined(separator: sep)
            for k in optional { body += " (" + sep + pair(k) + ")?" }
            return #""{" ws "# + body + #" ws "}""#
        }
        if optional.isEmpty { return #""{" ws "}""# }
        // No required key: any in-order subset of the optional ones.
        let alternatives = optional.indices.map { i -> String in
            pair(optional[i]) + optional[(i + 1)...].map { " (" + sep + pair($0) + ")?" }.joined()
        }
        return #""{" ws ( "# + alternatives.joined(separator: " | ") + #" )? ws "}""#
    }

    /// One argument's value rule.
    static func value(_ schema: OwlJSON) -> String {
        if case .array(let options)? = schema["enum"], !options.isEmpty {
            return "( " + options.map { literal($0.jsonString) }.joined(separator: " | ") + " )"
        }
        switch schema["type"]?.string {
        case "integer": return "integer"
        case "number": return "number"
        case "boolean": return "boolean"
        case "string":
            if let max = schema["maxLength"]?.int, max > 0 { return #""\"" char{0,"# + "\(max)" + #"} "\"""# }
            return "string"
        default: return "string"
        }
    }

    /// A GBNF rule name: letters, digits and dashes.
    static func ruleName(_ s: String) -> String {
        String(s.map { $0.isLetter || $0.isNumber ? $0 : "-" })
    }

    /// `s` (JSON text) as a GBNF string literal.
    static func literal(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func jsonString(_ s: String) -> String { OwlJSON.string(s).jsonString }
}
