import AppKit
import CedricCore

// Format › Markdown: bold, italic, strikethrough, inline code and link
// (MarkdownFormat in CedricCore). Each is one undo step, and only for
// Markdown tabs.

extension EditorWindowController {
    var markdownEditable: Bool { doc.language == .markdown && textView.isEditable && !textView.hasMarkedText() }

    func toggleMarkdown(_ style: MarkdownFormat.Style) {
        guard markdownEditable else { NSSound.beep(); return }
        let e = MarkdownFormat.toggle(style, in: textView.string as NSString, selection: textView.selectedRange())
        let names: [MarkdownFormat.Style: String] = [.bold: String(localized: "Bold"), .italic: String(localized: "Italic"),
                                                     .strikethrough: String(localized: "Strikethrough"), .code: String(localized: "Inline Code")]
        apply(e, actionName: names[style] ?? "")
    }

    /// ⌘↩: checks or unchecks the task boxes on the selected lines.
    func toggleCheckboxes() {
        guard markdownEditable,
              let e = MarkdownLists.toggleTasks(in: textView.string as NSString, selection: textView.selectedRange()) else { NSSound.beep(); return }
        apply(e, actionName: String(localized: "Toggle Checkbox"))
    }

    /// Format › Markdown › Format Table: lines up the table at the caret
    /// (not in fenced code).
    func formatTable() {
        let sel = textView.selectedRange()
        guard markdownEditable, textView.inFence?(sel.location) != true,
              let e = MarkdownTable.format(in: textView.string as NSString, selection: sel) else { NSSound.beep(); return }
        apply(e, actionName: String(localized: "Format Table"))
    }

    func markdownLink() {
        guard markdownEditable else { NSSound.beep(); return }
        let clip = NSPasteboard.general.string(forType: .string)
        apply(MarkdownFormat.link(in: textView.string as NSString, selection: textView.selectedRange(), clipboard: clip),
              actionName: String(localized: "Link"))
    }
}

extension AppDelegate {
    @objc func markdownBoldMenu(_ sender: Any?) { currentTab?.toggleMarkdown(.bold) }
    @objc func markdownItalicMenu(_ sender: Any?) { currentTab?.toggleMarkdown(.italic) }
    @objc func markdownStrikethroughMenu(_ sender: Any?) { currentTab?.toggleMarkdown(.strikethrough) }
    @objc func markdownCodeMenu(_ sender: Any?) { currentTab?.toggleMarkdown(.code) }
    @objc func markdownLinkMenu(_ sender: Any?) { currentTab?.markdownLink() }
    @objc func toggleCheckboxMenu(_ sender: Any?) { currentTab?.toggleCheckboxes() }
    @objc func formatTableMenu(_ sender: Any?) { currentTab?.formatTable() }

    static let markdownActions: Set<Selector> = [
        #selector(markdownBoldMenu(_:)), #selector(markdownItalicMenu(_:)), #selector(markdownStrikethroughMenu(_:)),
        #selector(markdownCodeMenu(_:)), #selector(markdownLinkMenu(_:)), #selector(toggleCheckboxMenu(_:)),
        #selector(formatTableMenu(_:)),
    ]

    func validateMarkdownItem(_ item: NSMenuItem) -> Bool? {
        guard let action = item.action, Self.markdownActions.contains(action) else { return nil }
        guard let tab = currentTab else { return false }
        return tab.doc.language == .markdown && tab.textView.isEditable
    }
}

/// Format › Markdown, built with the main menu.
@MainActor
func markdownMenu() -> NSMenuItem {
    submenu(String(localized: "Markdown"), [
        item(String(localized: "Bold"), #selector(AppDelegate.markdownBoldMenu(_:)), "b"),
        item(String(localized: "Italic"), #selector(AppDelegate.markdownItalicMenu(_:)), "i"),
        item(String(localized: "Strikethrough"), #selector(AppDelegate.markdownStrikethroughMenu(_:)), "x", [.command, .shift]),
        item(String(localized: "Inline Code"), #selector(AppDelegate.markdownCodeMenu(_:)), "`", [.control]),
        item(String(localized: "Link"), #selector(AppDelegate.markdownLinkMenu(_:)), "k"),
        .separator(),
        item(String(localized: "Toggle Checkbox"), #selector(AppDelegate.toggleCheckboxMenu(_:)), "\r"),
        item(String(localized: "Format Table"), #selector(AppDelegate.formatTableMenu(_:))),
    ])
}

// Pasted and dropped images in Markdown: copied into an "images" folder
// next to the document (a file already inside the document's folder is
// linked where it is) and inserted as ![](images/name.png).

extension EditorWindowController {
    func insertImages(_ files: [URL], bitmap: Data?, at range: NSRange) {
        guard textView.isEditable else { NSSound.beep(); return }
        guard let docURL = doc.fileURL else { askToSaveForImages(files, bitmap: bitmap, at: range); return }
        let dir = docURL.deletingLastPathComponent()
        let images = dir.appendingPathComponent("images", isDirectory: true)
        let fm = FileManager.default
        var paths: [String] = []
        func copyTarget(_ name: String) throws -> URL {
            // An "images" that is a link out of the document's folder is refused.
            guard SafePaths.isInside(images, dir) else {
                throw NSError(domain: "Cedric", code: 3, userInfo: [NSLocalizedDescriptionKey:
                    String(localized: "The “images” folder next to this document points outside its folder, so pasted images aren’t saved there.")])
            }
            try fm.createDirectory(at: images, withIntermediateDirectories: true)
            return images.appendingPathComponent(MarkdownPaste.uniqueName(name) { fm.fileExists(atPath: images.appendingPathComponent($0).path) })
        }
        do {
            for f in files {
                if let rel = MarkdownPaste.relativePath(of: f, from: dir) { paths.append(rel); continue }
                // Only a regular file is copied (not a folder named x.png).
                guard SafePaths.isRegularFile(f) else { NSSound.beep(); continue }
                let target = try copyTarget(f.lastPathComponent)
                try fm.copyItem(at: f, to: target)
                paths.append(MarkdownPaste.relativePath(of: target, from: dir) ?? "images/" + target.lastPathComponent)
            }
            if let bitmap {
                guard let png = NSBitmapImageRep(data: bitmap)?.representation(using: .png, properties: [:]) else { NSSound.beep(); return }
                let f = DateFormatter()
                f.locale = Locale(identifier: "en_US_POSIX")
                f.dateFormat = "yyyyMMdd-HHmmss"
                let target = try copyTarget("image-\(f.string(from: Date())).png")
                try png.write(to: target, options: .atomic)
                paths.append(MarkdownPaste.relativePath(of: target, from: dir) ?? "images/" + target.lastPathComponent)
            }
        } catch {
            showError(error)
            if paths.isEmpty { return }
        }
        guard !paths.isEmpty else { return }
        let len = (textView.string as NSString).length
        let r = NSRange(location: min(range.location, len), length: min(range.length, len - min(range.location, len)))
        let s = MarkdownPaste.imageLinks(paths)
        apply(TextEdit(range: r, replacement: s, selection: NSRange(location: r.location + (s as NSString).length, length: 0)),
              actionName: String(localized: "Insert Image"))
    }

    /// An untitled tab has no folder for the image: say so, and offer Save As.
    private func askToSaveForImages(_ files: [URL], bitmap: Data?, at range: NSRange) {
        guard let window else { NSSound.beep(); return }
        let alert = NSAlert()
        alert.messageText = String(localized: "Save this document first")
        alert.informativeText = String(localized: "Images are copied into an “images” folder next to the document, so it needs a folder. Nothing was inserted.")
        alert.addButton(withTitle: String(localized: "Save As…"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.saveAs(), self.doc.fileURL != nil else { return }
                self.insertImages(files, bitmap: bitmap, at: range)
            }
        }
    }
}
