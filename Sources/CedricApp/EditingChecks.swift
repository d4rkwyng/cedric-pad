import AppKit
import CedricCore

/// In-process checks of the editing extras (EditingFeatures.swift), run by
/// Scripts/tools-check.sh like the other DevChecks: real key events
/// through the menus' key equivalents and the text view, then the text,
/// the state and the drawn pixels are checked.
///
///   CEDRIC_CHECK=highlight|lineops|bookmarks|closedtab|autoedit|counts
@MainActor
extension DevChecks {
    static func editingCheck(_ name: String, _ app: AppDelegate) -> Bool {
        switch name {
        case "highlight": highlight(app)
        case "lineops": lineOps(app)
        case "bookmarks": bookmarks(app)
        case "closedtab": closedTab(app)
        case "autoedit": autoEdit(app)
        case "counts": counts(app)
        default: return gapCheck(name, app)
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

    // MARK: Bookmarks

    static let f2Key = String(UnicodeScalar(UInt16(NSF2FunctionKey))!)

    static func bookmarks(_ app: AppDelegate) {
        let lines = (1...12).map { $0 == 4 || $0 == 9 ? "todo \($0)" : "line \($0)" }
        let tab = app.open(write("marks.txt", lines.joined(separator: "\n") + "\n"))!
        sized(tab)
        func caretTo(line: Int) { tab.textView.setSelectedRange(NSRange(location: tab.lineIndex.starts[line] + 1, length: 0)) }
        var marks: [Int] { tab.editing.bookmarks.lines }
        run([
            sync {
                focus(tab)
                caretTo(line: 1)
                key(f2Key, [.command])
                caretTo(line: 5)
                key(f2Key, [.command])
                expect(marks == [1, 5], "⌘F2 bookmarks the caret's line", "\(marks)")
                tab.gutter.display()
            },
            sync {
                // The marker is drawn in the gutter, in the theme's caret colour.
                let g = tab.gutter
                let y = TypingCheck.glyphRects(tab.textView, NSRange(location: tab.lineIndex.starts[1], length: 1)).first.map {
                    g.convert(NSPoint(x: 0, y: $0.midY), from: tab.textView).y } ?? -1
                let rep = DevHooks.render(g, NSRect(x: 0, y: max(0, y - 2), width: 10, height: 4))
                let c = rep?.colorAt(x: 8, y: 4)
                expect(distance(c, tab.palette.caret) < 0.3, "a bookmark marker is drawn in the gutter",
                       "\(String(describing: c)) at y=\(y)")
                let none = DevHooks.render(g, NSRect(x: 0, y: max(0, y + 3 * 16 - 2), width: 10, height: 4))?.colorAt(x: 8, y: 4)
                expect(distance(none, tab.palette.gutterBackground) < 0.05, "no marker on a line without one", "\(String(describing: none))")
            },
            snapshot("bookmarks.png"),
            sync {
                caretTo(line: 0)
                key(f2Key)
                expect(tab.caretLine == 1, "F2 goes to the next bookmark", "line \(tab.caretLine)")
                key(f2Key)
                expect(tab.caretLine == 5, "F2 again: the one after", "line \(tab.caretLine)")
                key(f2Key)
                expect(tab.caretLine == 1, "F2 wraps to the first", "line \(tab.caretLine)")
                key(f2Key, [.shift])
                expect(tab.caretLine == 5, "⇧F2 goes back (wrapping)", "line \(tab.caretLine)")
            },
            sync {
                // A line typed above: the bookmarks stay on their text.
                tab.textView.setSelectedRange(NSRange(location: 0, length: 0))
                key("\r")
                expect(marks == [2, 6], "a new line above moves the bookmarks down with their lines", "\(marks)")
                expect(tab.text.components(separatedBy: "\n")[2] == "line 2", "still on \"line 2\"")
                key("z", [.command])
            },
            sync {
                expect(marks == [1, 5] || marks == [2, 6], "undo keeps them on lines", "\(marks)")
                // Delete a bookmarked line: its bookmark goes.
                tab.editing.bookmarks = Bookmarks([1, 5])
                caretTo(line: 1)
                key("k", [.command, .shift])
                expect(marks == [4], "deleting a bookmarked line drops its bookmark, the one below moves up", "\(marks)")
                // Move a bookmarked line: the bookmark goes with it.
                caretTo(line: 4)
                key(down, [.control, .command])
                expect(marks == [5], "⌃⌘↓ takes the bookmark along", "\(marks)")
            },
            sync {
                // Bookmark All Matches on the word under the caret ("todo").
                key(f2Key, [.command, .shift])
                expect(marks.isEmpty, "⇧⌘F2 clears the bookmarks", "\(marks)")
                let todo = (tab.text as NSString).range(of: "todo")
                tab.textView.setSelectedRange(NSRange(location: todo.location + 1, length: 0))
                key(f2Key, [.command, .option])
                let want = tab.text.components(separatedBy: "\n").enumerated().filter { $0.element.hasPrefix("todo") }.map(\.offset)
                expect(marks == want && want.count == 2, "⌥⌘F2 bookmarks every line with the word", "\(marks) want \(want)")
                // With the find bar open: its search (a regex here).
                tab.showFindBar(replace: false)
                tab.findBar.regexBox.state = .on
                tab.findBar.findField.stringValue = "line 1[01]"
                key(f2Key, [.command, .option])
                expect(marks.count == 4, "⌥⌘F2 with the find bar: every line matching its search too", "\(marks)")
                tab.hideFindBar()
            },
            sync {
                // A click on a line number toggles that line's bookmark.
                key(f2Key, [.command, .shift])
                let g = tab.gutter
                let r = TypingCheck.glyphRects(tab.textView, NSRange(location: tab.lineIndex.starts[2], length: 1)).first ?? .zero
                let p = g.convert(NSPoint(x: 0, y: r.midY), from: tab.textView)
                click(g, at: NSPoint(x: g.bounds.width - 10, y: p.y))
                expect(marks == [2], "a click in the gutter toggles a bookmark", "\(marks)")
                click(g, at: NSPoint(x: g.bounds.width - 10, y: p.y))
                expect(marks.isEmpty, "and a second click removes it", "\(marks)")
            },
        ])
    }

    // MARK: Hot close, Reopen Closed Tab

    static func closedTab(_ app: AppDelegate) {
        let file = app.open(write("kept.txt", "on disk\n"))!
        sized(file)
        var untitled: EditorWindowController!
        run([
            sync {
                // Exactly one ⇧⌘T in the menus (AppKit's own tab items included).
                var hits: [String] = []
                func walk(_ m: NSMenu) {
                    m.update()
                    for i in m.items {
                        if i.keyEquivalent.lowercased() == "t",
                           i.keyEquivalentModifierMask.union(i.keyEquivalent != i.keyEquivalent.lowercased() ? .shift : []) == [.command, .shift] {
                            hits.append(i.title)
                        }
                        if let s = i.submenu { walk(s) }
                    }
                }
                if let m = NSApp.mainMenu { walk(m) }
                expect(hits == ["Reopen Closed Tab"], "⇧⌘T is only Reopen Closed Tab", "\(hits)")
                app.newTab(nil)
                untitled = app.tabs.last
                focus(untitled)
                type("hot close")
                expect(untitled.doc.isDirty && untitled.text == "hot close", "typed into an untitled tab", untitled.text)
                key("w", [.command])
            },
            sync {
                expect(!app.tabs.contains { $0 === untitled }, "⌘W closes the unsaved tab")
                expect(NSApp.modalWindow == nil && NSApp.windows.allSatisfy { $0.attachedSheet == nil }, "without asking")
                expect(app.closedTabs.count == 1 && app.closedTabs.last?.hasBuffer == true, "it is remembered with its text",
                       "\(app.closedTabs.count)")
                focus(file)
                file.textView.setSelectedRange(NSRange(location: 7, length: 0))
                type(" and edited")
                key("w", [.command])
            },
            sync {
                expect(!app.tabs.contains { $0 === file }, "⌘W closes the edited file tab too")
                expect(app.closedTabs.count == 2, "both are remembered", "\(app.closedTabs.count)")
                key("t", [.command, .shift])
            },
            sync {
                let back = app.tabs.last
                expect(back?.doc.fileURL?.lastPathComponent == "kept.txt", "⇧⌘T reopens the newest closed tab", back?.doc.displayName ?? "-")
                expect(back?.text == "on disk and edited\n" && back?.doc.isDirty == true, "with its unsaved edit, still unsaved",
                       back?.text ?? "-")
                expect((try? String(contentsOf: back!.doc.fileURL!, encoding: .utf8)) == "on disk\n", "the file itself is untouched")
                key("t", [.command, .shift])
            },
            sync {
                let back = app.tabs.last
                expect(back?.doc.fileURL == nil && back?.text == "hot close" && back?.doc.isDirty == true,
                       "⇧⌘T again: the untitled tab and its text", back?.text ?? "-")
                expect(app.closedTabs.isEmpty, "nothing left to reopen")
                expect(key("t", [.command, .shift]) == false || app.tabs.count == 2, "⇧⌘T with nothing closed does nothing")
            },
            snapshot("reopened-tab.png"),
        ])
    }

    // MARK: Auto-indent, pairing, bracket match

    static func autoEdit(_ app: AppDelegate) {
        let tab = app.open(write("auto.swift", ""))!
        let prose = app.open(write("prose.txt", ""))!
        sized(tab)
        var t: String { tab.text }
        var caret: Int { tab.textView.selectedRange().location }
        run([
            sync {
                focus(tab)
                expect(tab.doc.language == .swift, "a Swift file", tab.doc.language.rawValue)
                type("if x {")
                expect(t == "if x {}" && caret == 6, "typing { adds } after the caret", "\(t.debugDescription) caret \(caret)")
            },
            sync {
                expect(tab.textView.bracketRanges == [NSRange(location: 5, length: 1), NSRange(location: 6, length: 1)],
                       "the bracket pair at the caret is matched", "\(tab.textView.bracketRanges)")
                key("\r")
                expect(t == "if x {\n    \n}" && caret == 11, "Return between { } indents and puts } on its own line",
                       "\(t.debugDescription) caret \(caret)")
            },
            snapshot("auto-indent.png"),
            sync {
                type("f(a)")
                expect(t == "if x {\n    f(a)\n}" && caret == 15, "( pairs, typing ) steps over it", "\(t.debugDescription) caret \(caret)")
                type(" \"hi\"")
                expect(t == "if x {\n    f(a) \"hi\"\n}", "quotes pair and step over", t.debugDescription)
                type("[")
                expect(t == "if x {\n    f(a) \"hi\"[]\n}", "[ pairs", t.debugDescription)
                key("\u{7f}")
                expect(t == "if x {\n    f(a) \"hi\"\n}", "Backspace in [|] deletes both", t.debugDescription)
            },
            sync {
                key("\r")
                expect(t == "if x {\n    f(a) \"hi\"\n    \n}", "Return keeps the line's indent", t.debugDescription)
                tab.textView.setSelectedRange((t as NSString).range(of: "hi"))
                type("(")
                expect(t.contains("\"(hi)\""), "( with a selection wraps it", t.debugDescription)
                expect(tab.textView.selectedRange() == NSRange(location: ((t as NSString).range(of: "hi")).location, length: 2),
                       "and keeps it selected", "\(tab.textView.selectedRange())")
            },
            sync {
                // Undo takes the typing back step by step, without leaving a stray closer.
                let before = t
                type("(")
                key("z", [.command])
                expect(t == before, "⌘Z undoes a pair in one step", t.debugDescription)
            },
            sync {
                // Prose: no pairing, Return keeps the indent.
                focus(prose)
                type("  (don't")
                key("\r")
                type("x")
                expect(prose.text == "  (don't\n  x", "plain text: no pairing; Return keeps the indent", prose.text.debugDescription)
            },
        ])
    }

    // MARK: Status bar counts

    static func counts(_ app: AppDelegate) {
        let tab = app.open(write("count.txt", "one two\nthree four\nfive\n"))!
        let mid = app.open(write("mid.txt", String(repeating: "lorem ipsum\n", count: 6_000)))!   // 72 K: counted after a pause
        let big = app.open(write("big.txt", String(repeating: "lorem ipsum dolor\n", count: 70_000)))! // 1.26 M: lines only
        sized(tab)
        var label: String { tab.statusBar.counts.stringValue }
        run([
            sync {
                focus(tab)
                tab.textView.setSelectedRange(NSRange(location: 0, length: 0))
                expect(label == "5 words · 3 lines · 24 characters", "the document's counts", label)
                tab.textView.setSelectedRange(NSRange(location: (tab.text as NSString).length, length: 0))
                type("six")
                expect(label == "6 words · 4 lines · 27 characters", "updated as you type", label)
                tab.textView.setSelectedRange((tab.text as NSString).range(of: "two\nthree"))
                expect(label == "Selected: 2 words · 2 lines · 9 characters", "a selection's counts", label)
                tab.textView.setSelectedRange(NSRange(location: 0, length: 3))
                expect(label == "Selected: 1 word · 1 line · 3 characters", "singular", label)
            },
            snapshot("counts.png"),
            sync {
                focus(mid)
                mid.textView.setSelectedRange(NSRange(location: 0, length: 0))
                type("x")
            },
            { next in DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { next() } },
            sync {
                let l = mid.statusBar.counts.stringValue
                expect(l == "12,000 words · 6,000 lines · 72,001 characters", "a 72 K document is counted after a pause", l)
                focus(big)
                big.textView.setSelectedRange(NSRange(location: 0, length: 0))
                let t0 = Date()
                type("x")
                let ms = Date().timeIntervalSince(t0) * 1000
                let l2 = big.statusBar.counts.stringValue
                expect(l2 == "70,000 lines", "over 1 M characters: lines only, no scan", l2)
                expect(ms < 50, "typing there stays fast", String(format: "%.1f ms", ms))
                big.textView.setSelectedRange(NSRange(location: 0, length: 20 * 18))
                let l3 = big.statusBar.counts.stringValue
                expect(l3 == "Selected: 60 words · 20 lines · 360 characters", "a small selection in a big document is counted", l3)
                for t in [tab, mid, big] { t.doc.markSaved() }
            },
        ])
    }
}
