import AppKit
import CedricCore

/// In-process checks of the 0.1 gap features, run by Scripts/tools-check.sh
/// like the other DevChecks: real key events where a key does it (Tab,
/// ⇧Tab and the menus' key equivalents), menu items' actions otherwise.
///
///   CEDRIC_CHECK=indent|print
@MainActor
extension DevChecks {
    static func gapCheck(_ name: String, _ app: AppDelegate) -> Bool {
        switch name {
        case "indent": indent(app)
        case "print": printing(app)
        default: return false
        }
        return true
    }

    /// A key straight to the front window (keys that are no menu's
    /// shortcut, such as ⇧Tab).
    static func rawKey(_ chars: String, _ mods: NSEvent.ModifierFlags, code: UInt16) {
        guard let w = frontWindow else { return }
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            if let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime,
                                        windowNumber: w.windowNumber, context: nil, characters: chars,
                                        charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) {
                w.sendEvent(e)
            }
        }
    }

    static func backtab() { rawKey(String(UnicodeScalar(UInt8(NSBackTabCharacter))), [.shift], code: 48) }

    /// The main-menu item with this action (and represented object).
    static func menuItem(action: Selector, represented: AnyHashable? = nil) -> NSMenuItem? {
        var hit: NSMenuItem?
        func walk(_ m: NSMenu) {
            for i in m.items where hit == nil {
                if i.action == action, represented == nil || (i.representedObject as? AnyHashable) == represented { hit = i }
                if let s = i.submenu { walk(s) }
            }
        }
        NSApp.mainMenu.map(walk)
        return hit
    }

    /// Chooses a menu item (validated as AppKit does): for commands
    /// without a shortcut.
    @discardableResult
    static func choose(_ action: Selector, _ represented: AnyHashable? = nil) -> Bool {
        guard let item = menuItem(action: action, represented: represented) else {
            expect(false, "a menu item exists for \(action)"); return false
        }
        guard let app = NSApp.delegate as? AppDelegate else { return false }
        if !app.validateMenuItem(item) { return false }
        return NSApp.sendAction(action, to: app, from: item)
    }

    /// Saves the user's own values for these defaults keys; the returned
    /// closure puts them back exactly (removing keys that weren't set).
    static func keepDefaults(_ keys: [String]) -> () -> Void {
        let d = UserDefaults.standard
        let saved = keys.map { ($0, d.object(forKey: $0)) }
        return { for (k, v) in saved { if let v { d.set(v, forKey: k) } else { d.removeObject(forKey: k) } } }
    }

    // MARK: Indent and outdent

    static func indent(_ app: AppDelegate) {
        let src = "func f() {\n    a()\n    b()\n}\n"
        let tab = app.open(write("ind.swift", src))!
        let tabs = app.open(write("tabs.c", "int f() {\n\treturn 1;\n\tif (x) {\n\t\ty();\n\t}\n}\n"))!
        let restore = keepDefaults(["tabWidth", "indentWithTabs"])
        sized(tab)
        let tv = tab.textView
        func sel(_ loc: Int, _ len: Int = 0) { tv.setSelectedRange(NSRange(location: loc, length: len)) }
        run([
            sync {
                focus(tab)
                expect(tab.indentation == Indentation(usesTabs: false, width: 4), "a 4-space file is detected as such", "\(tab.indentation)")
                // Lines 2–3 selected, Tab.
                sel(11, 16)
                key("\t")
                expect(tab.text == "func f() {\n        a()\n        b()\n}\n", "Tab on two selected lines indents both", tab.text)
                expect(tv.selectedRange() == NSRange(location: 11, length: 24), "they stay selected", "\(tv.selectedRange())")
            },
            sync {
                backtab()
                expect(tab.text == src, "⇧Tab outdents them", tab.text)
            },
            sync {
                backtab()
                expect(tab.text == "func f() {\na()\nb()\n}\n", "⇧Tab again, to the margin", tab.text)
            },
            sync { key("z", [.command]) },
            sync {
                key("z", [.command])
                expect(tab.text == "func f() {\n        a()\n        b()\n}\n", "each ⌘Z undoes one shift", tab.text)
            },
            sync {
                key("z", [.command])
                expect(tab.text == src, "and back to the original", tab.text)
            },
            sync {
                sel(2)
                key("]", [.command])
                expect(tab.text == "    func f() {\n    a()\n    b()\n}\n", "⌘] indents the caret's line", tab.text)
                expect(tv.selectedRange().location == 6, "the caret moves with its text", "\(tv.selectedRange())")
                key("[", [.command])
                expect(tab.text == src, "⌘[ outdents it", tab.text)
                expect(tv.undoManager?.undoActionName == "Outdent", "undo is named", tv.undoManager?.undoActionName ?? "-")
            },
            sync {
                // No selection: Tab inserts spaces to the next stop.
                sel(13)
                key("\t")
                expect(tab.text == "func f() {\n      a()\n    b()\n}\n", "Tab at column 3 inserts 2 spaces (to the next stop)", tab.text)
                key("z", [.command])
            },
            sync {
                // Format › Indentation: tabs, width 2.
                choose(#selector(AppDelegate.indentUsingTabsMenu(_:)))
                choose(#selector(AppDelegate.tabWidthMenu(_:)), 2)
                expect(tab.indentation == Indentation(usesTabs: true, width: 2), "the tab's indentation is picked from the menu", "\(tab.indentation)")
                sel(11)
                key("\t")
                expect(tab.text.hasPrefix("func f() {\n\t    a()"), "Tab now inserts a tab", tab.text)
                let para = tv.textStorage?.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
                let two = ("  " as NSString).size(withAttributes: [.font: Settings.shared.font]).width
                expect(abs((para?.defaultTabInterval ?? 0) - two) < 0.01, "tabs are drawn 2 columns wide",
                       "\(para?.defaultTabInterval ?? 0) vs \(two)")
                let item = menuItem(action: #selector(AppDelegate.tabWidthMenu(_:)), represented: 2)!
                _ = app.validateMenuItem(item)
                expect(item.state == .on, "the menu shows Tab Width: 2 checked")
                key("z", [.command])
            },
            sync {
                choose(#selector(AppDelegate.convertIndentationToSpacesMenu(_:)))
                expect(tab.text == "func f() {\n    a()\n    b()\n}\n", "Convert to Spaces keeps the columns", tab.text)
                expect(tab.indentation == Indentation(usesTabs: false, width: 2), "and indents with spaces from then on")
            },
            sync {
                // A tab-indented file: Tab inserts a tab; Return after "{" indents with a tab.
                focus(tabs)
                expect(tabs.indentation.usesTabs, "a tab-indented file is detected as such", "\(tabs.indentation)")
                tabs.textView.setSelectedRange(NSRange(location: 9, length: 0))
                key("\r")
                expect(tabs.text.hasPrefix("int f() {\n\t\n"), "Return after { indents with a tab", tabs.text)
                key("\t")
                expect(tabs.text.hasPrefix("int f() {\n\t\t\n"), "and Tab inserts a tab", tabs.text)
            },
            snapshot("indent.png"),
            sync {
                // Settings' default applies to a new tab (put back after).
                Settings.shared.defaultIndentation = Indentation(usesTabs: false, width: 3)
                app.newTab(nil)
                let t = app.tabs.last!
                expect(t.indentation == Indentation(usesTabs: false, width: 3), "a new tab uses the default from Settings", "\(t.indentation)")
                restore()
            },
        ])
    }

    // MARK: Print

    static func printing(_ app: AppDelegate) {
        let long = String(repeating: "wrap me ", count: 40)
        let src = "first line\n\tindented\n" + long + "\nlast\n"
        let tab = app.open(write("print.txt", src))!
        sized(tab)
        let pdf = dir.appendingPathComponent("print.pdf")
        let restore = keepDefaults([PrintOptions.lineNumbersKey])
        run([
            sync {
                focus(tab)
                let item = menuItem("p", [.command])
                expect(item?.action == #selector(AppDelegate.printDocument(_:)), "⌘P is File › Print…", item?.title ?? "-")
                let setup = menuItem("p", [.command, .shift])
                expect(setup?.action == #selector(AppDelegate.pageSetup(_:)), "⇧⌘P is File › Page Setup…", setup?.title ?? "-")
                // ⌘P: the print panel comes up as a sheet on the tab (then cancelled).
                key("p", [.command])
            },
            { next in DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { next() } },
            sync {
                let sheet = tab.window?.attachedSheet
                expect(sheet != nil, "⌘P shows the print panel", "\(String(describing: tab.window?.sheets))")
                if let sheet { tab.window?.endSheet(sheet, returnCode: .cancel) }
            },
            { next in DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { next() } },
            sync {
                // To a PDF, without panels: with line numbers.
                let info = NSPrintInfo()
                info.jobDisposition = .save
                info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL.rawValue] = pdf
                let (op, view, _) = tab.makePrintOperation(lineNumbers: true, info: info)
                op.showsPrintPanel = false
                op.showsProgressPanel = false
                let ok = op.run()
                expect(ok, "printing to a PDF succeeds")
                let printed = view.textStorage?.string ?? ""
                expect(printed.hasPrefix("\t1\tfirst line\n\t2\t\tindented\n\t3\twrap"), "line numbers lead each line", printed.prefix(60).debugDescription)
                expect(!printed.contains("\t5\t"), "the empty line after the final newline isn't numbered")
                expect((view.textStorage?.attribute(.font, at: 4, effectiveRange: nil) as? NSFont)?.fontName == Settings.shared.font.fontName,
                       "in the editor's font", "\(String(describing: view.textStorage?.attribute(.font, at: 4, effectiveRange: nil)))")
                var fragments = 0
                if let lm = view.layoutManager {
                    lm.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: lm.numberOfGlyphs)) { _, _, _, _, _ in fragments += 1 }
                }
                expect(fragments > 4, "the long line wraps to the page width", "\(fragments) line fragments for 4 lines")
                let doc = CGPDFDocument(pdf as CFURL)
                expect((doc?.numberOfPages ?? 0) >= 1, "the PDF has a page", "\(doc?.numberOfPages ?? 0)")
                // The page is the paper's white, not the theme's background (dark).
                if let page = doc?.page(at: 1) {
                    let box = page.getBoxRect(.mediaBox)
                    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(box.width), pixelsHigh: Int(box.height), bitsPerSample: 8,
                                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                    NSGraphicsContext.saveGraphicsState()
                    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
                    NSGraphicsContext.current = ctx
                    NSColor.white.setFill()
                    box.fill()
                    ctx.cgContext.drawPDFPage(page)
                    NSGraphicsContext.restoreGraphicsState()
                    var dark = 0, total = 0
                    for y in stride(from: 0, to: rep.pixelsHigh, by: 7) {
                        for x in stride(from: 0, to: rep.pixelsWide, by: 7) {
                            total += 1
                            if let c = rep.colorAt(x: x, y: y), c.brightnessComponent < 0.5 { dark += 1 }
                        }
                    }
                    expect(total > 0 && dark * 20 < total, "the page is mostly white (text only, no theme background)", "\(dark)/\(total) dark samples")
                    expect(dark > 0, "and has text on it")
                    try? rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent("print-page1.png"))
                }
                // Without line numbers: the plain text.
                let (_, plain, _) = tab.makePrintOperation(lineNumbers: false, info: NSPrintInfo())
                expect(plain.textStorage?.string == src, "without line numbers, the text as it is")
                restore()
            },
        ])
    }
}
