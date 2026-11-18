import AppKit

/// CEDRIC_CHECK=closenotice: closing a file tab with unsaved edits says,
/// once per launch, that the file wasn't written, with Save Now.
@MainActor
extension DevChecks {
    static func closeNoticeCheck(_ app: AppDelegate) {
        let aURL = write("notice-a.txt", "a\n"), bURL = write("notice-b.txt", "b\n"), cURL = write("notice-c.txt", "c\n")
        let a = app.open(aURL)!
        sized(a)
        var b: EditorWindowController!
        var bID: UUID!
        func disk(_ u: URL) -> String { (try? String(contentsOf: u, encoding: .utf8)) ?? "-" }
        run([
            sync {
                b = app.open(bURL)!
                bID = b.doc.id
                focus(b)
                b.textView.setSelectedRange(NSRange(location: 1, length: 0))
                type(" edited")
                key("w", [.command])
            },
            sync {
                expect(!app.tabs.contains { $0 === b }, "⌘W closes the edited tab without asking")
                expect(NSApp.windows.allSatisfy { $0.attachedSheet == nil } && NSApp.modalWindow == nil, "no sheet or dialog")
                let bar = app.tabs.first?.noticeBar
                expect(bar?.isHidden == false && bar?.label.stringValue.contains("notice-b.txt") == true
                       && bar?.label.stringValue.contains("⇧⌘T") == true, "the tab in front says the file wasn't saved",
                       bar?.label.stringValue ?? "no bar")
                expect(disk(bURL) == "b\n", "the file is untouched")
            },
            snapshot("close-notice.png"),
            sync {
                app.tabs.first?.noticeBar?.button("Save Now")?.performClick(nil)
            },
            sync {
                expect(disk(bURL) == "b edited\n", "Save Now writes the closed tab's text to the file", disk(bURL))
                expect(!app.tabs.contains { $0.doc.id == bID }, "and the tab stays closed")
                expect(app.tabs.first?.noticeBar?.isHidden == true, "the notice goes")
                let c = app.open(cURL)!
                focus(c)
                type("x")
                key("w", [.command])
            },
            sync {
                expect(app.tabs.allSatisfy { $0.noticeBar?.isHidden != false }, "only once per launch")
                expect(app.closedTabs.last?.hasBuffer == true, "the next close still keeps the text for ⇧⌘T")
            },
        ])
    }
}
