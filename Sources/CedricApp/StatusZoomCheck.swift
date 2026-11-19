import AppKit
import CedricCore

/// CEDRIC_CHECK=statuszoom (Scripts/tools-check.sh, 0.2.1): the status
/// bar's zoom is a pull-down (Zoom In, Zoom Out, Actual Size, 75–200 %)
/// that zooms the editor, and with the preview docked the editor's status
/// items stay under the editor column.
@MainActor
extension DevChecks {
    static func statusZoomCheck(_ app: AppDelegate) {
        let tab = app.open(write("zoom.md", "# Zoom\n\nText.\n"))!
        sized(tab)
        let bar = tab.statusBar
        let start = Settings.shared.fontSize
        func item(_ title: String) -> NSMenuItem? { bar.zoom.itemArray.dropFirst().first { $0.title == title } }
        /// Runs a pop-up item as a click does: its action up the responder chain.
        func choose(_ title: String) {
            guard let i = item(title), let a = i.action else { expect(false, "zoom item \(title)", "missing"); return }
            NSApp.sendAction(a, to: i.target, from: i)
        }
        run([
            sync {
                focus(tab)
                Settings.shared.fontSize = Settings.defaultFontSize
                let titles = bar.zoom.itemArray.dropFirst().map(\.title)
                expect(titles == ["Zoom In", "Zoom Out", "Actual Size", "", "75%", "90%", "100%", "110%", "125%", "150%", "200%"],
                       "the zoom is a pull-down with Zoom In / Out, Actual Size and 75–200 %", "\(titles)")
                expect(!bar.zoom.isHidden && bar.zoom.titleOfSelectedItem == "100%" && bar.zoom.stringValue == "100%", "titled 100%",
                       bar.zoom.titleOfSelectedItem ?? "-")
                let keys = ["Zoom In", "Zoom Out", "Actual Size"].map { item($0).map { "\($0.keyEquivalent)\($0.keyEquivalentModifierMask == .command)" } ?? "-" }
                expect(keys == ["=true", "-true", "0true"], "showing ⌘+ ⌘− ⌘0", "\(keys)")
                expect(item("100%")?.state == .on && item("110%")?.state == .off, "a tick on the current size")
                choose("125%")
                expect(Settings.shared.fontSize == Settings.defaultFontSize * 1.25 && bar.zoom.stringValue == "125%",
                       "125% zooms the editor", "\(Settings.shared.fontSize) \(bar.zoom.stringValue)")
                choose("Zoom In")
                expect(Settings.shared.fontSize == Settings.defaultFontSize * 1.25 + 1, "Zoom In", "\(Settings.shared.fontSize)")
                choose("Zoom Out"); choose("Zoom Out")
                expect(Settings.shared.fontSize == Settings.defaultFontSize * 1.25 - 1, "Zoom Out", "\(Settings.shared.fontSize)")
                choose("Actual Size")
                expect(Settings.shared.fontSize == Settings.defaultFontSize && bar.zoom.stringValue == "100%", "Actual Size")
                // ⌘= is the View menu's, once: the pop-up only shows the shortcut.
                let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: tab.window?.windowNumber ?? 0,
                                         context: nil, characters: "=", charactersIgnoringModifiers: "=", isARepeat: false, keyCode: 24)
                expect(e.map { !bar.zoom.performKeyEquivalent(with: $0) } == true, "the pop-up leaves ⌘= to the View menu")
                tab.window?.layoutIfNeeded()
                expect(abs(bar.itemsFrame.maxX - bar.bounds.maxX) < 1, "no preview: the items reach the right edge",
                       "\(bar.itemsFrame) in \(bar.bounds)")
                tab.togglePreview()
            },
            snapshot("statuszoom-docked.png"),
            sync {
                tab.window?.layoutIfNeeded()
                let column = tab.editorArea.frame
                let items = bar.itemsFrame
                expect(tab.previewVisible && column.maxX < bar.bounds.width - 100, "the preview is docked beside the editor", "\(column)")
                expect(abs(items.maxX - column.maxX) < 1 && items.minX >= column.minX - 1,
                       "the status items sit under the editor column, not under the preview", "items \(items) column \(column)")
                let zoom = bar.zoom.convert(bar.zoom.bounds, to: bar)
                expect(zoom.maxX <= column.maxX, "the zoom too", "\(zoom)")
                tab.togglePreview()
            },
            sync {
                tab.window?.layoutIfNeeded()
                expect(abs(bar.itemsFrame.maxX - bar.bounds.maxX) < 1, "preview closed: back to the full width", "\(bar.itemsFrame)")
                Settings.shared.fontSize = start
            },
        ])
    }
}
