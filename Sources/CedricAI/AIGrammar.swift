import Foundation
import CedricCore

/// "Check Grammar with Cedric": asks the chat engine for grammar mistakes in
/// prose and turns its answer into the same `GrammarResult`s the system
/// checker produces, so they become the usual green underlines, the owl's
/// "Fix it" bubble and Fix Grammar… steps. Nothing is shown that can't be
/// found word for word in the text, or that rewrites more than a few words.
public enum AIGrammar {
    public static let maxIssues = 6
    public static let maxFind = 80
    /// Words that may differ between `find` and `replacement`.
    public static let maxWordChange = 4

    public static func messages(text: String, model: String = "", server: Bool = false) -> [OwlChatMessage] {
        var user = "Prose:\n```\n\(text)\n```"
        if model.lowercased().contains("qwen3") { user += "\n/no_think" }
        return [.system(OwlPrompts.persona(server: server) + "\n\n" + OwlPrompts.grammarTask + "\n\n" + OwlPrompts.untrustedDocument), .user(user)]
    }

    /// Asks `engine` about `text` (prose, already masked), capped to its budget.
    public static func check(_ text: String, engine: any OwlChatEngine) async throws -> [GrammarResult] {
        let ns = text as NSString
        let capped = ns.length > engine.contextBudget ? ns.substring(to: engine.contextBudget) : text
        let turn = try await engine.turn(messages(text: capped, model: engine.scoreKey, server: engine.usesServer), tools: [], toolbox: nil, maxTokens: 500) { _ in }
        guard case .answer(let raw) = turn else { return [] }
        return parse(raw, text: capped as NSString)
    }

    /// The model's JSON → verified results (sentence = the paragraph the
    /// words are in; detail range relative to it).
    public static func parse(_ raw: String, text: NSString) -> [GrammarResult] {
        let trimmed = OwlChatRunner.stripThinking(raw)
        guard let start = trimmed.firstIndex(of: "{"), let end = trimmed.lastIndex(of: "}"),
              case .array(let list)? = OwlJSON.parse(String(trimmed[start...end]))?["issues"] else { return [] }
        var out: [GrammarResult] = []
        var used: [NSRange] = []
        for item in list where out.count < maxIssues {
            guard let find = item["find"]?.string, let rep = item["replacement"]?.string else { continue }
            let why = item["why"]?.string ?? ""
            guard verify(find: find, replacement: rep) else { continue }
            // First occurrence not already taken, on word boundaries.
            var search = NSRange(location: 0, length: text.length)
            var found: NSRange?
            while search.length > 0 {
                let r = text.range(of: find, options: [], range: search)
                guard r.location != NSNotFound else { break }
                if !used.contains(where: { NSIntersectionRange($0, r).length > 0 }), isWordBounded(r, in: text) { found = r; break }
                search = NSRange(location: NSMaxRange(r), length: text.length - NSMaxRange(r))
            }
            guard let r = found else { continue }
            used.append(r)
            let sentence = text.paragraphRange(for: r)
            out.append(GrammarResult(sentence: sentence, details: [GrammarDetail(
                range: NSRange(location: r.location - sentence.location, length: r.length),
                description: why.isEmpty ? String(localized: "Grammar suggestion from the AI.") : String(why.prefix(200)),
                corrections: [rep])]))
        }
        return out
    }

    /// A small, real change: one line, a few words, not just case or spacing.
    public static func verify(find: String, replacement: String) -> Bool {
        guard !find.isEmpty, find.count <= maxFind, replacement.count <= maxFind * 2,
              !find.contains("\n"), !replacement.contains("\n"), find != replacement else { return false }
        let a = find.split(whereSeparator: \.isWhitespace), b = replacement.split(whereSeparator: \.isWhitespace)
        guard a.count <= 8, b.count <= 10 else { return false }
        let changed = LineDiff.diff(a.map(String.init), b.map(String.init)).filter {
            if case .equal = $0 { return false }
            return true
        }.count
        return changed > 0 && changed <= maxWordChange * 2
    }

    static func isWordBounded(_ r: NSRange, in text: NSString) -> Bool {
        func isWord(_ c: unichar) -> Bool {
            guard let s = Unicode.Scalar(c) else { return false }
            return CharacterSet.alphanumerics.contains(s)
        }
        if r.location > 0, isWord(text.character(at: r.location - 1)), isWord(text.character(at: r.location)) { return false }
        let e = NSMaxRange(r)
        if e < text.length, isWord(text.character(at: e)), isWord(text.character(at: e - 1)) { return false }
        return true
    }
}
