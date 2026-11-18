import AppKit
import CedricCore

/// CEDRIC_CHECK=binary (tools-check): a file of bytes 0…255 opens with the
/// "This looks like a binary file" bar and nothing shown; ⌘S does nothing
/// and the file is unchanged; Open Anyway shows it read-only (typing
/// changes nothing, Save still off); Allow Editing makes it a text tab.
/// A UTF-16 file and a log with escape codes open as text, with no bar.
@MainActor
extension DevChecks {
    static func binaryCheck(_ name: String, _ app: AppDelegate) -> Bool {
        guard name == "binary" else { return false }
        let bin = dir.appendingPathComponent("binary.bin")
        let bytes = Data((0..<4).flatMap { _ in (0...255).map { UInt8($0) } })
        try? bytes.write(to: bin)
        let utf16 = dir.appendingPathComponent("utf16.txt")
        try? (Data([0xFF, 0xFE]) + "Hello from UTF-16\n".data(using: .utf16LittleEndian)!).write(to: utf16)
        let ansi = write("build.log", String(repeating: "\u{1B}[32mok\u{1B}[0m step done\n", count: 20))
        guard let tab = app.open(bin) else { expect(false, "opened binary.bin"); finish(); return true }
        sized(tab)
        func saveItem() -> NSMenuItem? { menuItem("s", [.command]) }
        run([
            sync {
                tab.window?.makeKeyAndOrderFront(nil)
                tab.window?.makeFirstResponder(tab.textView)
                expect(tab.binary == .held(tab.binaryHeldText ?? ""), "binary.bin is held, not shown", "\(String(describing: tab.binary).prefix(40))")
                expect(tab.text.isEmpty, "nothing shown before Open Anyway", "\(tab.text.count) characters")
                expect(tab.binaryBar?.isHidden == false && tab.binaryBar?.button.title == "Open Anyway",
                       "the bar says so, with Open Anyway", tab.binaryBar?.label.stringValue ?? "no bar")
                expect(saveItem().map { app.validateMenuItem($0) } == false, "Save is off")
                key("s", [.command])
                expect((try? Data(contentsOf: bin)) == bytes, "⌘S left the file's bytes alone")
            },
            snapshot("binary-1-held.png"),
            sync {
                tab.binaryBar?.button.performClick(nil)
                expect(tab.binary == .readOnly, "Open Anyway: read-only")
                expect(tab.text.count > 900, "the bytes show as text", "\(tab.text.count) characters")
                expect(!tab.textView.isEditable, "the text view is read-only")
                let before = tab.text
                key("x")
                expect(tab.text == before && !tab.doc.isDirty, "typing changes nothing")
                expect(saveItem().map { app.validateMenuItem($0) } == false, "Save is still off")
                expect(!tab.save() && (try? Data(contentsOf: bin)) == bytes, "and saving writes nothing")
                expect(tab.binaryBar?.button.title == "Allow Editing", "the bar offers Allow Editing")
            },
            snapshot("binary-2-readonly.png"),
            sync {
                tab.binaryBar?.button.performClick(nil)
                expect(tab.binary == .editable && tab.textView.isEditable, "Allow Editing: editable")
                expect(tab.binaryBar?.isHidden == true, "the bar goes")
                expect(saveItem().map { app.validateMenuItem($0) } == true, "Save is on")
                tab.doc.markSaved()
            },
            sync {
                for url in [utf16, ansi] {
                    guard let t = app.open(url) else { expect(false, "opened \(url.lastPathComponent)"); continue }
                    expect(t.binary == nil && t.binaryBar == nil && !t.text.isEmpty, "\(url.lastPathComponent) opens as text, no bar",
                           String(t.text.prefix(30)))
                }
            },
        ])
        return true
    }
}

extension EditorWindowController {
    /// The text waiting for Open Anyway (checks).
    var binaryHeldText: String? { if case .held(let t) = binary { return t } else { return nil } }
}
