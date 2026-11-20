import Foundation
import Testing
@testable import CedricCore

/// The preview page builder, shared by the Mac preview and the iOS app.
@Suite struct PreviewHTMLTests {
    @Test func pageWrapsBodyWithPaletteAndCSP() {
        let html = PreviewHTML.page(body: "<p>hi</p>", palette: EditorPalettes.dracula, csp: "default-src 'none'", title: "T")
        #expect(html.contains("<p>hi</p>"))
        #expect(html.contains("Content-Security-Policy"))
        #expect(html.contains("<title>T</title>"))
        #expect(html.contains("color-scheme: dark"))
        #expect(html.contains(PreviewHTML.hex(EditorPalettes.dracula.background)))
    }

    @Test func noCSPWhenNil() {
        let html = PreviewHTML.page(body: "", palette: EditorPalettes.light, csp: nil)
        #expect(!html.contains("Content-Security-Policy"))
        #expect(html.contains("color-scheme: light"))
    }
}
