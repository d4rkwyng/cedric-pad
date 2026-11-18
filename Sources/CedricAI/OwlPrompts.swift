import Foundation
import CedricCore

/// Every prompt the owl sends, in one place, shared by every engine (LM
/// Studio, Ollama, another Mac, Apple Intelligence, and the built-in engine
/// when it lands). One system prompt gives Cedric his persona; each task
/// adds its own instructions after it. Change the owl's voice here, not in
/// an engine.
public enum OwlPrompts {
    /// Who is speaking: Cedric, the owl in the corner of the editor.
    public static let persona = """
    You are Cedric, the small owl with a monocle who sits in the corner of the Cedric Pad text \
    editor on the user's Mac. You are quiet, precise and kind: you speak up only when you \
    are sure it helps, in plain words, never chatty, never preachy. What you are shown \
    never leaves this machine.
    """

    /// The tasks the owl can be given. Each is appended to `persona`.
    public enum Task: String, Sendable, CaseIterable {
        /// Look at the visible code and point out real problems (the owl's hints).
        case codeHints

        public var instructions: String {
            switch self {
            case .codeHints: return OwlPrompts.codeHints
            }
        }
    }

    static let codeHints = """
    Task: look at the code the user is viewing. Point out at most 2 real problems in it: \
    a bug, a likely mistake, or clearly confusing code with a small fix. \
    Do not comment on style, naming, missing docs or tests, or code you cannot see. \
    Only report a problem you can point to on a specific line. \
    If you are unsure, or nothing is clearly wrong, return {"hints":[]}.

    The code is shown with line numbers ("12| ") that are not part of the code.

    Reply with JSON only. Fields of each hint:
    - kind: "fix" (a bug with a fix), "warning" (a likely bug), "tip" or "explain"
    - category: "unclosed-tag", "brackets", "unused", "undefined", "json", "logic" or "other"
    - title: names the specific problem in a few words
    - detail: one or two plain sentences on why it is wrong
    - line: the line number the problem is on
    - find: the exact snippet from that line, copied character for character, without the line number
    - replacement: the corrected snippet that replaces find. Give one whenever the problem can be fixed; \
    change only what is needed and keep the rest of the snippet as it is. "" only if there is no safe fix.
    - confidence: 0.0 to 1.0

    Example, for line 4 `while n > 0 { total += n }`:
    {"hints":[{"kind":"fix","category":"logic","title":"Infinite loop: n never decreases",\
    "detail":"The loop body never changes n, so the condition stays true.","line":4,\
    "find":"total += n","replacement":"total += n; n -= 1","confidence":0.9}]}
    """

    /// The system prompt for a task: the persona, then the task.
    public static func system(for task: Task) -> String { persona + "\n\n" + task.instructions }

    /// The user turn for a code task: language, file name, the (capped)
    /// visible text. Qwen3 thinks by default; a hint costs too much with a
    /// scratchpad, so it gets `/no_think`.
    public static func user(for context: OwlContext, text: String, model: String) -> String {
        var user = "Language: \(context.language)\n"
        if let name = context.fileName { user += "File: \(name)\n" }
        user += "Code:\n```\n\(numbered(text))\n```"
        if model.lowercased().contains("qwen3") { user += "\n/no_think" }
        return user
    }

    /// "1| first line\n2| second line…": the model cites lines by these.
    public static func numbered(_ text: String) -> String {
        text.components(separatedBy: "\n").enumerated().map { "\($0.offset + 1)| \($0.element)" }.joined(separator: "\n")
    }

    public static func messages(for task: Task, context: OwlContext, text: String, model: String) -> [ChatMessage] {
        [ChatMessage(role: "system", content: system(for: task)),
         ChatMessage(role: "user", content: user(for: context, text: text, model: model))]
    }

    // MARK: Ask Cedric (the chat panel)

    static let chatTask = """
    Task: help the user with the document they are editing. Answer their question about the text \
    shown below, briefly: a few short sentences or a short list, plain text or simple Markdown. \
    The text is shown with line numbers ("12| ") that are not part of the text; cite lines by number. \
    Never make up content you cannot see. If you are not sure, say so.
    """

    /// The system prompt for a chat question.
    public static func chatSystem(toolsOn: Bool) -> String {
        var s = persona + "\n\n" + chatTask
        if toolsOn {
            s += "\n\nYou can call tools to read more of the document (it may be longer than what is shown) or to propose an edit. "
                + "Use a tool only when it helps; to change the text, call propose_edit — never paste the whole changed text in your answer. "
                + "After at most three tool calls, answer."
        }
        return s
    }

    /// The fixed instruction behind a quick action.
    public static func quickInstruction(_ action: OwlQuickAction, prose: Bool, toolsOn: Bool, context: OwlChatContext) -> String {
        let lines = "lines \(context.firstLine)-\(context.lastLine)"
        let what = prose ? "text" : "code"
        let edit = toolsOn
            ? "Call propose_edit with start \(context.firstLine), end \(context.lastLine) and the new text, then say in one sentence what you changed."
            : "Reply with only the new text for \(lines) in one ``` block, without line numbers, then one sentence on what you changed."
        switch action {
        case .explain:
            return "Explain what this \(what) (\(lines)) does or says, in plain words, in at most 5 sentences."
        case .summarise:
            return "Summarise this \(what) (\(lines)) in at most 5 short bullet points."
        case .findProblems:
            return prose
                ? "Find real problems in this text (\(lines)): mistakes, unclear sentences, contradictions. List at most 4, each with its line number. If there are none, say so."
                : "Find real bugs or likely mistakes in this code (\(lines)). List at most 4, each with its line number and a one-line fix. If there are none, say so."
        case .rewrite:
            return (prose
                ? "Rewrite \(lines) to be clearer and shorter, keeping the meaning and the author's voice. "
                : "Simplify the code in \(lines) without changing what it does. ") + edit
        case .addComments:
            return "Add short, useful comments to the code in \(lines) (in the language's comment syntax), changing nothing else. " + edit
        }
    }

    /// The first messages of a chat request: system, the last two turns
    /// of history, then the user turn with the context attached.
    public static func chatMessages(question: String, context: OwlChatContext, language: String, fileName: String?,
                                    history: [OwlChatEntry], toolsOn: Bool, model: String) -> [OwlChatMessage] {
        var out: [OwlChatMessage] = [.system(chatSystem(toolsOn: toolsOn))]
        // Older turns are dropped (small context): the last two questions and answers.
        var kept: [OwlChatEntry] = []
        var users = 0
        for e in history.reversed() where e.role == .user || e.role == .owl {
            if e.role == .user { users += 1; if users > 2 { break } }
            kept.insert(e, at: 0)
        }
        while kept.first?.role == .owl { kept.removeFirst() }
        for e in kept {
            let t = String(e.text.prefix(1200))
            out.append(e.role == .user ? .user(t) : .assistant(t))
        }
        var user = "Language: \(language)\n"
        if let fileName { user += "File: \(fileName)\n" }
        user += "Shown: \(context.scope.rawValue), lines \(context.firstLine)-\(context.lastLine)"
        if context.truncated { user += " (trimmed; use tools or ask for less)" }
        user += "\n```\n\(context.numbered)\n```\n\n\(question)"
        if model.lowercased().contains("qwen3") { user += "\n/no_think" }
        out.append(.user(user))
        return out
    }

    /// The built-in engine's tool protocol (a grammar enforces it).
    public static func envelopeInstructions(_ tools: [OwlToolSpec]) -> String {
        var s = "\n\nTools:\n"
        for t in tools {
            var params: [String] = []
            if case .object(let props)? = t.parameters["properties"] {
                for (k, v) in props.sorted(by: { $0.key < $1.key }) { params.append("\(k): \(v["type"]?.string ?? "string")") }
            }
            s += "- \(t.name.rawValue)(\(params.joined(separator: ", "))): \(t.description)\n"
        }
        s += """
        You were shown only some lines of the document. Call a tool first when the question needs lines \
        you were not shown (get_lines), a search (search_document), the headings or structure (get_outline), \
        counts or the file name (document_stats), the user's selection (get_selection) or a change to the \
        text (propose_edit). Otherwise answer directly.
        Reply with JSON only. To call a tool: {"tool":"get_lines","args":{"start":40,"end":44}}. \
        To answer: {"answer":"your answer"}.
        Examples: "What does line 80 say?" → {"tool":"get_lines","args":{"start":80,"end":80}}. \
        "Where is foo used?" → {"tool":"search_document","args":{"query":"foo"}}. \
        "What is 2 + 2?" → {"answer":"4"}.
        """
        return s
    }

    /// Grammar in prose, for the AI grammar check.
    public static let grammarTask = """
    Task: find grammar mistakes in the prose below: wrong verb forms, agreement, wrong word \
    (their/there/they're, its/it's, to/too, then/than), missing or doubled words, a/an. \
    Not spelling, not style, not punctuation preferences, not anything in code. At most 6.
    Reply with JSON only: {"issues":[{"find":"exact words from the text","replacement":"corrected words","why":"one short sentence"}]}
    "find" is copied character for character from one sentence: the smallest span (1-6 words) that needs to change. \
    If there are none, reply {"issues":[]}.
    """
}

