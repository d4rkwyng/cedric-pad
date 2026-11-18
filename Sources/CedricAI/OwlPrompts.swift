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
    You are Cedric, the small owl with a monocle who sits in the corner of the Cedric text \
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
    If nothing is clearly wrong, return {"hints":[]}.

    Reply with JSON only. Fields of each hint:
    - kind: "fix" (a bug with a fix), "warning" (a likely bug), "tip" or "explain"
    - title: names the specific problem in a few words
    - detail: one or two plain sentences on why it is wrong
    - find: a short snippet copied character for character from the code, or ""
    - replacement: the corrected snippet that replaces find, or "" if unsure
    - confidence: 0.0 to 1.0

    Example, for `while n > 0 { total += n }`:
    {"hints":[{"kind":"fix","title":"Infinite loop: n never decreases",\
    "detail":"The loop body never changes n, so the condition stays true.",\
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
        user += "Code:\n```\n\(text)\n```"
        if model.lowercased().contains("qwen3") { user += "\n/no_think" }
        return user
    }

    public static func messages(for task: Task, context: OwlContext, text: String, model: String) -> [ChatMessage] {
        [ChatMessage(role: "system", content: system(for: task)),
         ChatMessage(role: "user", content: user(for: context, text: text, model: model))]
    }
}
