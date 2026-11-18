import AppKit
import CedricCore

/// In-process checks of Markdown editing, run by Scripts/tools-check.sh
/// like the other DevChecks, with real key events (Return, Tab, ⇧Tab and
/// the menus' key equivalents) and typed text.
///
///   CEDRIC_CHECK=mdlists
@MainActor
extension DevChecks {
    static func markdownCheck(_ name: String, _ app: AppDelegate) -> Bool {
        switch name {
        case "mdlists": markdownLists(app)
        default: return false
        }
        return true
    }

    /// Puts the caret at the end of the text.
    static func caretAtEnd(_ tab: EditorWindowController) {
        tab.textView.setSelectedRange(NSRange(location: (tab.text as NSString).length, length: 0))
    }

    static func markdownLists(_ app: AppDelegate) {
        let tab = app.open(write("lists.md", "# Shopping\n\n- eggs"))!
        let fence = app.open(write("fence.md", "```\n- in code"))!
        sized(tab)
        let tv = tab.textView
        run([
            sync {
                focus(tab)
                caretAtEnd(tab)
                key("\r")
                type("milk")
                expect(tab.text == "# Shopping\n\n- eggs\n- milk", "Return continues a bullet list", tab.text)
                key("\t")
                expect(tab.text == "# Shopping\n\n- eggs\n  - milk", "Tab indents the item under the one above", tab.text)
                backtab()
                expect(tab.text == "# Shopping\n\n- eggs\n- milk", "⇧Tab outdents it", tab.text)
                key("\r")
            },
            sync {
                key("\r")
                expect(tab.text == "# Shopping\n\n- eggs\n- milk\n", "Return on the empty item ends the list", tab.text)
                type("1. one")
                key("\r")
                type("two")
                key("\r")
                type("[ ] three")
            },
            sync {
                key("\r")
                expect(tab.text.hasSuffix("1. one\n2. two\n3. [ ] three\n4. [ ] "), "ordered items count up; a task item continues unchecked", tab.text)
            },
            sync {
                key("z", [.command])
                expect(tab.text.hasSuffix("3. [ ] three"), "one ⌘Z undoes one continuation", tab.text)
                // Return in the middle of the list renumbers what follows.
                let ns = tab.text as NSString
                guard ns.range(of: "one").location != NSNotFound else { return }
                let at = ns.range(of: "one").location + 3
                tv.setSelectedRange(NSRange(location: at, length: 0))
                key("\r")
                type("new")
                expect(tab.text.hasSuffix("1. one\n2. new\n3. two\n4. [ ] three"), "an inserted item renumbers the rest", tab.text)
            },
            sync {
                key("\t")
                expect(tab.text.hasSuffix("1. one\n   1. new\n2. two\n3. [ ] three"), "Tab nests it and renumbers both levels", tab.text)
            },
            sync {
                key("z", [.command])
                expect(tab.text.hasSuffix("1. one\n2. new\n3. two\n4. [ ] three"), "one ⌘Z undoes the indent and renumbering", tab.text)
            },
            sync {
                // Inside a fence, Return is plain.
                focus(fence)
                caretAtEnd(fence)
                key("\r")
                expect(fence.text == "```\n- in code\n", "inside fenced code Return doesn't continue the list", fence.text)
                key("\t")
                expect(fence.text.hasPrefix("```\n- in code\n") && fence.text != "```\n- in code\n", "and Tab types its usual indent", fence.text)
            },
            snapshot("mdlists.png"),
        ])
    }
}
