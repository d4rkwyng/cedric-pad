import Foundation
import Testing
@testable import CedricCore

@Suite struct MarkdownFormatTests {
    func t(_ style: MarkdownFormat.Style, _ s: String) -> String? {
        let (x, sel) = caretText(s)
        return shown(x, MarkdownFormat.toggle(style, in: x, selection: sel))
    }

    @Test func wrapsTheSelection() {
        #expect(t(.bold, "a ‸word‸ b") == "a **‸word‸** b")
        #expect(t(.italic, "a ‸word‸ b") == "a *‸word‸* b")
        #expect(t(.strikethrough, "‸gone‸") == "~~‸gone‸~~")
        #expect(t(.code, "run ‸ls‸") == "run `‸ls‸`")
        // Spaces at the ends stay outside.
        #expect(t(.bold, "a‸ word ‸b") == "a **‸word‸** b")
    }

    @Test func togglesOffInsteadOfStacking() {
        #expect(t(.bold, "a **‸word‸** b") == "a ‸word‸ b")
        #expect(t(.bold, "a ‸**word**‸ b") == "a ‸word‸ b")
        #expect(t(.italic, "a *‸word‸* b") == "a ‸word‸ b")
        #expect(t(.italic, "_‸word‸_") == "‸word‸")
        // Italic on bold adds italic; bold on bold-italic takes bold off.
        #expect(t(.italic, "**‸word‸**") == "***‸word‸***")
        #expect(t(.bold, "***‸word‸***") == "*‸word‸*")
        #expect(t(.italic, "***‸word‸***") == "**‸word‸**")
        #expect(t(.strikethrough, "~~‸x‸~~") == "‸x‸")
        #expect(t(.code, "`‸x‸`") == "‸x‸")
    }

    @Test func atTheCaret() {
        #expect(t(.bold, "a ‸") == "a **‸**")
        #expect(t(.bold, "a **‸**") == "a ‸")
        #expect(t(.italic, "a *‸*") == "a ‸")
        // Inside a styled word: unwrap it.
        #expect(t(.bold, "a **wo‸rd** b") == "a wo‸rd b")
        #expect(t(.code, "x `co‸de` y `z`") == "x co‸de y `z`")
        #expect(t(.italic, "my_va‸r_name") == "my_va*‸*r_name")
    }

    @Test func links() {
        func l(_ s: String, _ clip: String? = nil) -> String? {
            let (x, sel) = caretText(s)
            return shown(x, MarkdownFormat.link(in: x, selection: sel, clipboard: clip))
        }
        #expect(l("see ‸docs‸") == "see [docs](‸)")
        #expect(l("see ‸docs‸", "https://example.com/a") == "see [docs](https://example.com/a)‸")
        #expect(l("see ‸docs‸", "not a url") == "see [docs](‸)")
        #expect(l("‸https://x.org‸") == "[‸](https://x.org)")
        #expect(l("go ‸") == "go [‸]()")
        #expect(l("go ‸", "https://x.org") == "go [‸](https://x.org)")
        // In a link: unlink.
        #expect(l("see [do‸cs](https://x.org) now") == "see ‸docs‸ now")
        #expect(l("an ![im‸g](a.png)") == "an ![im[‸]()g](a.png)") // an image is not unlinked
        #expect(MarkdownFormat.isURL("mailto:a@b.c") && !MarkdownFormat.isURL("ftp:/") && !MarkdownFormat.isURL("javascript:alert(1)"))
    }
}
