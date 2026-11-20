import XCTest
import UIKit
import CedricCore
import CedricAI

/// Drives the real editor (the app's own sources, compiled into this
/// hostless test bundle) in a window without SpringBoard: open a sample,
/// type, save and read the file back; Cedric's offline hint and its fix;
/// the Markdown preview; Settings. Renders PNGs of iPhone and iPad layouts
/// in light and dark into $OWLINK_SNAPSHOTS (or the temp folder).
///
/// Why not only XCUITest: on the build Mac the simulator's SpringBoard
/// never draws a home screen, so apps can't be launched there. These tests
/// need no SpringBoard; OwlinkUITests covers the same on a working
/// simulator or a device.
@MainActor
final class EditorSnapshotTests: XCTestCase {
    var windows: [UIWindow] = []

    override func setUp() async throws {
        for k in [AppSettings.Key.fontSize, AppSettings.Key.wrap, AppSettings.Key.owlHints, AppSettings.Key.theme] {
            UserDefaults.standard.removeObject(forKey: k)
        }
    }

    override func tearDown() async throws {
        for w in windows { w.isHidden = true; w.rootViewController = nil }
        windows = []
    }

    static var outDir: URL {
        let env = ProcessInfo.processInfo.environment["OWLINK_SNAPSHOTS"]
        let url = env.map { URL(fileURLWithPath: $0) } ?? FileManager.default.temporaryDirectory.appendingPathComponent("owlink-snapshots")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A fresh copy of a bundled sample in a temp folder.
    func sample(_ name: String) throws -> URL {
        let b = Bundle(for: Self.self)
        let src = try XCTUnwrap(b.url(forResource: (name as NSString).deletingPathExtension,
                                      withExtension: (name as NSString).pathExtension, subdirectory: "Samples"))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try FileManager.default.copyItem(at: src, to: url)
        return url
    }

    func open(_ url: URL) async throws -> TextDocument {
        let doc = TextDocument(fileURL: url)
        let ok = await withCheckedContinuation { c in doc.open { c.resume(returning: $0) } }
        XCTAssertTrue(ok, "couldn't open \(url.lastPathComponent)")
        return doc
    }

    func show(_ doc: TextDocument, size: CGSize, dark: Bool, regular: Bool = false) -> (UIWindow, EditorViewController) {
        let editor = EditorViewController(document: doc, readModeOnOpen: false)
        let nav = UINavigationController(rootViewController: editor)
        let w = UIWindow(frame: CGRect(origin: .zero, size: size))
        w.overrideUserInterfaceStyle = dark ? .dark : .light
        w.rootViewController = nav
        if regular {
            nav.traitOverrides.horizontalSizeClass = .regular
            nav.traitOverrides.verticalSizeClass = .regular
            nav.traitOverrides.userInterfaceIdiom = .pad
        }
        w.isHidden = false
        w.layoutIfNeeded()
        windows.append(w)
        return (w, editor)
    }

    func spin(_ seconds: TimeInterval) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    @discardableResult
    func snapshot(_ w: UIWindow, _ name: String) throws -> URL {
        w.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        let img = UIGraphicsImageRenderer(bounds: w.bounds, format: format).image { ctx in
            if !w.drawHierarchy(in: w.bounds, afterScreenUpdates: true) { w.layer.render(in: ctx.cgContext) }
        }
        let url = Self.outDir.appendingPathComponent(name + ".png")
        try XCTUnwrap(img.pngData()).write(to: url)
        add(XCTAttachment(image: img))
        return url
    }

    static let iPhone = CGSize(width: 402, height: 874)
    static let iPad = CGSize(width: 1032, height: 1376)

    // MARK: Behaviour

    func testOpenTypeSaveReadBack() async throws {
        let url = try sample("sample.swift")
        let doc = try await open(url)
        let (_, editor) = show(doc, size: Self.iPhone, dark: false)
        XCTAssertEqual(doc.language.language, .swift)
        XCTAssertEqual(doc.encoding, .utf8)
        XCTAssertTrue(editor.textView.text.contains("struct Owl"))
        editor.textView.selectedRange = NSRange(location: (editor.textView.text as NSString).length, length: 0)
        editor.textView.insertText("// typed in the test\n")
        XCTAssertTrue(doc.hasUnsavedChanges)
        let saved = await withCheckedContinuation { c in
            doc.save(to: doc.fileURL, for: .forOverwriting) { c.resume(returning: $0) }
        }
        XCTAssertTrue(saved)
        let back = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(back.hasSuffix("// typed in the test\n"), "file on disk: \(back.suffix(60))")
        await withCheckedContinuation { c in doc.close { _ in c.resume() } }
    }

    /// The hide-keyboard button shows only while editing and resigns.
    func testHideKeyboardButton() async throws {
        let doc = try await open(try sample("sample.swift"))
        let (_, editor) = show(doc, size: Self.iPhone, dark: false)
        XCTAssertTrue(editor.hideKeyboardButton.isHidden, "shown without the keyboard")
        XCTAssertEqual(editor.hideKeyboardButton.accessibilityLabel, "Hide Keyboard")
        XCTAssertTrue(editor.textView.becomeFirstResponder())
        XCTAssertFalse(editor.hideKeyboardButton.isHidden, "not shown while editing")
        editor.hideKeyboardButton.sendActions(for: .primaryActionTriggered)
        XCTAssertFalse(editor.textView.isFirstResponder, "didn't resign")
        XCTAssertTrue(editor.hideKeyboardButton.isHidden)
        await withCheckedContinuation { c in doc.close { _ in c.resume() } }
    }

    func testKeepsCRLFAndLatin1OnSave() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("legacy.txt")
        try XCTUnwrap("caf\u{e9}\r\nna\u{ef}ve\r\n".data(using: .isoLatin1)).write(to: url)
        let doc = try await open(url)
        let (_, editor) = show(doc, size: Self.iPhone, dark: false)
        XCTAssertEqual(doc.lineEnding, .crlf)
        XCTAssertEqual(editor.textView.text, "café\nnaïve\n")
        editor.textView.insertText("x")
        let saved = await withCheckedContinuation { c in doc.save(to: doc.fileURL, for: .forOverwriting) { c.resume(returning: $0) } }
        XCTAssertTrue(saved)
        let data = try Data(contentsOf: url)
        XCTAssertTrue(data.contains(0xE9), "not Latin-1/Windows-1252 any more")
        XCTAssertNotNil(String(data: data, encoding: .isoLatin1)?.range(of: "\r\n"), "CRLF lost")
        await withCheckedContinuation { c in doc.close { _ in c.resume() } }
    }

    func testOwlHintAndFixIt() async throws {
        let doc = try await open(try sample("sample.swift"))
        let (w, editor) = show(doc, size: Self.iPhone, dark: false)
        for _ in 0..<30 where editor.owl.visible == nil { await spin(0.2) }
        let shown = try XCTUnwrap(editor.owl.visible, "no hint")
        XCTAssertTrue(shown.hint.title.contains("spaces"), shown.hint.title)
        XCTAssertFalse(editor.owlSprite.isHidden)
        editor.openHint()
        XCTAssertFalse(editor.hintBar.isHidden)
        try snapshot(w, "test-owl-hint")
        editor.applyFix()
        XCTAssertFalse(editor.textView.text.contains("struct Owl {   "))
        XCTAssertTrue(editor.textView.undoManager?.canUndo ?? false, "the fix should be undoable")
        await withCheckedContinuation { c in doc.close { _ in c.resume() } }
    }

    func testMarkdownPreviewTurnsOn() async throws {
        let doc = try await open(try sample("README.md"))
        let (_, editor) = show(doc, size: Self.iPad, dark: false, regular: true)
        XCTAssertEqual(doc.language.language, .markdown)
        editor.togglePreview()
        XCTAssertTrue(editor.previewOn)
        XCTAssertNotNil(editor.preview)
        await withCheckedContinuation { c in doc.close { _ in c.resume() } }
    }

    func testBuiltInSaysNeedsDeviceInSimulator() {
        #if targetEnvironment(simulator)
        XCTAssertEqual(BuiltInEngine().unavailableReason, BuiltInPlatform.unavailableReason)
        XCTAssertEqual(BuiltInPlatform.unavailableReason, "Built-in model: needs a real device.")
        #endif
        // iPhone offers only the small model.
        let phone = ModelCatalog.bundled()?.offered(on: .iPhone) ?? []
        XCTAssertFalse(phone.isEmpty)
        XCTAssertTrue(phone.allSatisfy { $0.parametersB <= 2 })
    }

    // MARK: Screenshots

    func testScreenshots() async throws {
        for (device, size, regular) in [("iphone", Self.iPhone, false), ("ipad", Self.iPad, true)] {
            for dark in [false, true] {
                let mode = dark ? "dark" : "light"
                let swift = try await open(try sample("sample.swift"))
                let (w1, e1) = show(swift, size: size, dark: dark, regular: regular)
                for _ in 0..<30 where e1.owl.visible == nil { await spin(0.2) }
                await spin(0.3)
                try snapshot(w1, "\(device)-\(mode)-swift")
                await withCheckedContinuation { c in swift.close { _ in c.resume() } }
                w1.isHidden = true

                let md = try await open(try sample("README.md"))
                let (w2, e2) = show(md, size: size, dark: dark, regular: regular)
                e2.togglePreview()
                await spin(2.5)   // WebKit renders out of process
                try snapshot(w2, "\(device)-\(mode)-markdown-preview")
                await withCheckedContinuation { c in md.close { _ in c.resume() } }
                w2.isHidden = true
            }
        }
        // Dracula, and Settings.
        AppSettings.theme = .dracula
        let doc = try await open(try sample("sample.swift"))
        let (w, _) = show(doc, size: Self.iPhone, dark: true)
        await spin(1.2)
        try snapshot(w, "iphone-dracula-swift")
        let settings = UIWindow(frame: CGRect(origin: .zero, size: Self.iPhone))
        settings.rootViewController = UIHostingSettings.make()
        settings.isHidden = false
        windows.append(settings)
        await spin(0.8)
        try snapshot(settings, "iphone-settings")
        await withCheckedContinuation { c in doc.close { _ in c.resume() } }
        AppSettings.theme = .system
        print("Snapshots in \(Self.outDir.path)")
    }
}
