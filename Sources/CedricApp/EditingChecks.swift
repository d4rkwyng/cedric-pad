import AppKit
import CedricCore

/// In-process checks of the editing extras (EditingFeatures.swift), run by
/// Scripts/tools-check.sh like the other DevChecks: real key events
/// through the menus' key equivalents and the text view, then the text,
/// the state and the drawn pixels are checked.
///
///   CEDRIC_CHECK=highlight
@MainActor
extension DevChecks {
    static func editingCheck(_ name: String, _ app: AppDelegate) -> Bool {
        switch name {
        case "highlight": highlight(app)
        case "lineops": lineOps(app)
        default: return false
        }
        return true
    }

    /// The colour drawn at the top-left corner of `range`'s first segment
    /// (inside the highlight, clear of the glyph).
    static func cornerColor(_ tab: EditorWindowController, _ range: NSRange) -> NSColor? {
        let tv = tab.textView
        guard let rect = TypingCheck.glyphRects(tv, range).first else { return nil }
        let probe = NSRect(x: rect.minX, y: rect.minY, width: 4, height: 3)
        tv.displayIfNeeded()
        guard let rep = DevHooks.render(tv, probe) else { return nil }
        return rep.colorAt(x: 1, y: 1)?.usingColorSpace(.sRGB)
    }

    static func distance(_ a: NSColor?, _ hex: UInt32) -> Double {
        guard let a = a?.usingColorSpace(.sRGB), let b = NSColor(hex: hex).usingColorSpace(.sRGB) else { return 0 }
        return abs(Double(a.redComponent - b.redComponent)) + abs(Double(a.greenComponent - b.greenComponent))
            + abs(Double(a.blueComponent - b.blueComponent))
    }

    static func focus(_ tab: EditorWindowController) {
        tab.window?.makeKeyAndOrderFront(nil)
        tab.window?.makeFirstResponder(tab.textView)
    }

    // MARK: Highlight all, Mark All

    static func highlight(_ app: AppDelegate) {
        let src = "let alpha = 1\nlet beta = alpha + alphabet\nprint(alpha, beta)\nlet other = 2\n"
        let tab = app.open(write("occ.swift", src))!
        sized(tab)
        let ns = { tab.text as NSString }
        func at(_ s: String, _ n: Int = 0) -> NSRange {
            var r = NSRange(location: 0, length: 0), from = 0
            for _ in 0...n {
                r = ns().range(of: s, options: [], range: NSRange(location: from, length: ns().length - from))
                from = NSMaxRange(r)
            }
            return r
        }
        run([
            sync {
                focus(tab)
                // Caret inside "alpha" on line 1 (a click there: the selection change path).
                tab.textView.setSelectedRange(NSRange(location: at("alpha").location + 2, length: 0))
            },
            { next in DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { next() } },
            sync {
                let occ = tab.textView.occurrenceRanges
                expect(occ.count == 3, "the word under the caret: 3 whole-word occurrences (not \"alphabet\")", "\(occ)")
                let p = tab.palette
                let other = cornerColor(tab, at("alpha", 1))
                let plain = cornerColor(tab, at("other"))
                expect(distance(other, p.background) > 0.08, "an occurrence on another line is tinted",
                       "\(String(describing: other)) vs bg \(String(p.background, radix: 16))")
                expect(distance(plain, p.background) < 0.03, "a word that isn't an occurrence isn't tinted", "\(String(describing: plain))")
            },
            snapshot("highlight-occurrences.png"),
            sync {
                // Typing: the new word under the caret is highlighted after the pause.
                tab.textView.setSelectedRange(NSRange(location: ns().length, length: 0))
                type("beta")
            },
            { next in DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { next() } },
            sync {
                expect(tab.text.hasSuffix("\nbeta"), "typed with key events", tab.text)
                expect(tab.textView.occurrenceRanges.count == 3, "the typed word's occurrences are highlighted",
                       "\(tab.textView.occurrenceRanges)")
                // Mark All on "alpha" with ⌃⌘M.
                tab.textView.setSelectedRange(at("alpha"))
                key("m", [.control, .command])
            },
            { next in DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { next() } },
            sync {
                expect(tab.textView.markRanges.count == 3, "⌃⌘M marks every \"alpha\"", "\(tab.textView.markRanges)")
                expect(tab.statusBar.position.stringValue.contains("3 marked"), "the status bar counts the marks",
                       tab.statusBar.position.stringValue)
                tab.textView.setSelectedRange(NSRange(location: ns().length, length: 0))
                type(" alpha")
            },
            { next in DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { next() } },
            sync {
                expect(tab.textView.markRanges.count == 4, "a typed occurrence is marked too", "\(tab.textView.markRanges)")
                expect(tab.statusBar.position.stringValue.contains("4 marked"), "and counted", tab.statusBar.position.stringValue)
                let c = cornerColor(tab, at("alpha", 1))
                expect(distance(c, tab.palette.findMatch) < 0.25, "a mark is drawn in the theme's match colour",
                       "\(String(describing: c)) vs \(String(tab.palette.findMatch, radix: 16))")
            },
            snapshot("mark-all.png"),
            sync {
                key("m", [.control, .command, .shift])
                expect(tab.textView.markRanges.isEmpty && !tab.hasMarks, "⌃⇧⌘M clears the marks")
                expect(!tab.statusBar.position.stringValue.contains("marked"), "and the count", tab.statusBar.position.stringValue)
                // Turned off in the View menu: nothing is highlighted. (The
                // user's own setting is put back as it was.)
                let saved = UserDefaults.standard.object(forKey: "highlightOccurrences")
                defer { UserDefaults.standard.set(saved, forKey: "highlightOccurrences") }
                Settings.shared.highlightOccurrences = false
                tab.textView.setSelectedRange(NSRange(location: at("alpha").location + 1, length: 0))
                tab.refreshHighlights()
                expect(tab.textView.occurrenceRanges.isEmpty, "View › Highlight Occurrences off: no tint")
            },
        ])
    }

    // MARK: Line operations

    static let up = String(UnicodeScalar(UInt16(NSUpArrowFunctionKey))!)
    static let down = String(UnicodeScalar(UInt16(NSDownArrowFunctionKey))!)

    static func lineOps(_ app: AppDelegate) {
        let src = "func f() {\n    let a = 1\n    let b = 2\n}\n"
        let tab = app.open(write("lines.swift", src))!
        let json = app.open(write("data.json", "{\"a\": 1}\n"))!
        sized(tab)
        let pb = NSPasteboard.general
        let savedClipboard = pb.string(forType: .string)
        func caret(_ off: Int) { tab.textView.setSelectedRange(NSRange(location: off, length: 0)) }
        let lineA = 11 + 4 // inside "let a"
        run([
            sync {
                focus(tab)
                caret(lineA)
                key("d", [.command, .shift])
                expect(tab.text == "func f() {\n    let a = 1\n    let a = 1\n    let b = 2\n}\n", "⇧⌘D duplicates the line", tab.text)
                expect(tab.textView.selectedRange().location == lineA + 14, "the caret moves to the copy", "\(tab.textView.selectedRange())")
                expect(tab.textView.undoManager?.undoActionName == "Duplicate Line", "undo is named", tab.textView.undoManager?.undoActionName ?? "-")
            },
            sync {
                key("z", [.command])
                expect(tab.text == src, "one ⌘Z undoes it", tab.text)
                caret(lineA)
                key(down, [.control, .command])
                expect(tab.text == "func f() {\n    let b = 2\n    let a = 1\n}\n", "⌃⌘↓ moves the line down", tab.text)
            },
            sync {
                key(up, [.control, .command])
                expect(tab.text == src, "⌃⌘↑ moves it back up", tab.text)
                expect(tab.textView.selectedRange().location == lineA, "the caret stays on the moved line", "\(tab.textView.selectedRange())")
                caret(0)
                key(up, [.control, .command])
                expect(tab.text == src, "⌃⌘↑ on the first line changes nothing", tab.text)
            },
            sync {
                caret(lineA)
                key("k", [.command, .shift])
                expect(tab.text == "func f() {\n    let b = 2\n}\n", "⇧⌘K deletes the line", tab.text)
            },
            sync {
                key("z", [.command])
                caret(lineA)
                key("/", [.command])
                expect(tab.text == "func f() {\n    // let a = 1\n    let b = 2\n}\n", "⌘/ comments the line out", tab.text)
                expect(tab.textView.selectedRange().location == lineA + 3, "the caret moves with its text", "\(tab.textView.selectedRange())")
            },
            sync {
                // Two lines selected: mixed → both commented, then both back.
                tab.textView.setSelectedRange(NSRange(location: 11, length: 30))
                key("/", [.command])
                expect(tab.text == "func f() {\n    // // let a = 1\n    // let b = 2\n}\n", "⌘/ on mixed lines comments all", tab.text)
            },
            sync {
                key("/", [.command])
                expect(tab.text == "func f() {\n    // let a = 1\n    let b = 2\n}\n", "⌘/ again uncomments all", tab.text)
            },
            sync { key("z", [.command]) },
            sync { key("z", [.command]) },
            sync {
                key("z", [.command])
                expect(tab.text == src, "each ⌘Z undoes one step, back to the original", tab.text)
            },
            snapshot("line-ops.png"),
            sync {
                // ⌘X with no selection cuts the line.
                caret(lineA)
                key("x", [.command])
                expect(tab.text == "func f() {\n    let b = 2\n}\n", "⌘X with nothing selected cuts the line", tab.text)
                expect(pb.string(forType: .string) == "    let a = 1\n", "the line is on the clipboard", pb.string(forType: .string) ?? "-")
                key("v", [.command])
                expect(tab.text == src, "and ⌘V pastes it back as a line (at the caret's line start)", tab.text)
                // With a selection, ⌘X cuts only the selection.
                tab.textView.setSelectedRange(NSRange(location: 15, length: 3))
                key("x", [.command])
                expect(tab.text == "func f() {\n     a = 1\n    let b = 2\n}\n", "⌘X with a selection cuts the selection", tab.text)
                if let savedClipboard { pb.clearContents(); pb.setString(savedClipboard, forType: .string) }
            },
            sync {
                focus(json)
                json.textView.setSelectedRange(NSRange(location: 1, length: 0))
                key("/", [.command])
                expect(json.text == "{\"a\": 1}\n", "⌘/ does nothing in JSON (no comments)", json.text)
            },
        ])
    }
}
