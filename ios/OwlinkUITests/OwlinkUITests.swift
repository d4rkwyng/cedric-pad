import XCTest

/// Drives the real app in the simulator: open a sample, edit, save, reopen;
/// Cedric's offline hint and its fix; the Markdown preview; find.
/// `-OwlinkOpen <name>` opens Documents/<name> (copied from the bundled
/// samples), skipping the document browser.
final class OwlinkUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(_ name: String, fresh: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-OwlinkOpen", name, "-OwlinkResetSettings"] + (fresh ? ["-OwlinkFreshSample"] : [])
        app.launch()
        return app
    }

    private func editor(_ app: XCUIApplication) -> XCUIElement {
        let tv = app.textViews["editor.text"]
        XCTAssertTrue(tv.waitForExistence(timeout: 15), "editor didn't open")
        return tv
    }

    func testOpenEditSaveReopen() throws {
        var app = launch("sample.swift", fresh: true)
        var tv = editor(app)
        XCTAssertTrue((tv.value as? String ?? "").contains("struct Owl"))
        XCTAssertTrue(app.buttons["editor.language"].label.contains("Swift"))
        tv.tap()
        tv.typeText("\n// typed by the UI test\n")
        XCTAssertTrue((tv.value as? String ?? "").contains("typed by the UI test"))
        // The system overflow menu (the "More" button the system adds).
        app.navigationBars.buttons["More"].firstMatch.tap()
        app.buttons["Save"].firstMatch.tap()
        sleep(2)
        app.terminate()

        app = launch("sample.swift", fresh: false)
        tv = editor(app)
        XCTAssertTrue((tv.value as? String ?? "").contains("typed by the UI test"), "the edit wasn't saved")
        XCTAssertTrue(app.buttons["editor.format"].label.contains("UTF-8"))
    }

    func testHideKeyboardButton() throws {
        let app = launch("sample.swift", fresh: true)
        let tv = editor(app)
        let hide = app.buttons["editor.hideKeyboard"]
        XCTAssertFalse(hide.exists && hide.isHittable)
        tv.tap()
        XCTAssertTrue(hide.waitForExistence(timeout: 5), "no hide-keyboard button while editing")
        XCTAssertEqual(hide.label, "Hide Keyboard")
        hide.tap()
        let gone = NSPredicate { _, _ in !app.keyboards.firstMatch.exists }
        wait(for: [XCTNSPredicateExpectation(predicate: gone, object: nil)], timeout: 5)
    }

    func testOwlHintFixesTrailingSpaces() throws {
        let app = launch("sample.swift", fresh: true)
        let tv = editor(app)
        XCTAssertTrue((tv.value as? String ?? "").contains("struct Owl {   "))
        // The owl in the corner shows a badge; tapping him opens his bubble.
        let owl = app.descendants(matching: .any)["owl.sprite"]
        XCTAssertTrue(owl.waitForExistence(timeout: 10), "no owl")
        let badged = NSPredicate(format: "label CONTAINS 'hint'")
        wait(for: [XCTNSPredicateExpectation(predicate: badged, object: owl)], timeout: 10)
        owl.tap()
        let title = app.staticTexts["owl.hint.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 10), "no owl hint")
        XCTAssertTrue(title.label.contains("spaces"), "unexpected hint: \(title.label)")
        app.buttons["owl.hint.fix"].tap()
        let fixed = NSPredicate { _, _ in !((tv.value as? String ?? "").contains("struct Owl {   ")) }
        wait(for: [XCTNSPredicateExpectation(predicate: fixed, object: nil)], timeout: 5)
    }

    func testMarkdownPreview() throws {
        let app = launch("README.md", fresh: true)
        _ = editor(app)
        XCTAssertTrue(app.buttons["editor.language"].label.contains("Markdown"))
        app.buttons["editor.preview"].tap()
        XCTAssertTrue(app.webViews["editor.previewWeb"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.webViews.staticTexts["Owlink for iPhone and iPad"].waitForExistence(timeout: 10))
    }

    func testFindNavigatorOpens() throws {
        let app = launch("sample.swift", fresh: true)
        _ = editor(app)
        app.buttons["editor.find"].tap()
        let field = app.textFields.matching(NSPredicate(format: "placeholderValue CONTAINS[c] 'Search' OR placeholderValue CONTAINS[c] 'Find'")).firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "find navigator didn't open")
        field.typeText("hoot")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'of'")).firstMatch.waitForExistence(timeout: 5))
    }
}
