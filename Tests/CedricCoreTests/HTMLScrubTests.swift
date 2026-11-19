import Foundation
import Testing
@testable import CedricCore

/// Security audit L4 (export keeps scripts) and M3 (rich text remote loads).
@Suite struct HTMLScrubTests {
    @Test func exportHasNoScript() {
        let md = "# T\n\n<script>alert(1)</script>\n\n<img src=\"a.png\" onerror=\"alert(2)\">\n\n<iframe src=\"https://x\"></iframe>\n\n<a href=\"javascript:alert(3)\">j</a> <a href='https://example.com/ok'>ok</a>\n\n<div onclick=alert(4) ONMOUSEOVER='x'>d</div>\n"
        let html = HTMLScrub.noScript(Markdown.render(md, options: .preview))
        let low = html.lowercased()
        #expect(!low.contains("<script") && !low.contains("alert(1)"))
        #expect(!low.contains("onerror") && !low.contains("onclick") && !low.contains("onmouseover"))
        #expect(!low.contains("<iframe") && !low.contains("javascript:"))
        #expect(html.contains("src=\"a.png\"") && html.contains("https://example.com/ok"), "the rest is kept")
        #expect(html.contains("<h1"))
    }

    @Test func richTextHasNoRemoteLoads() {
        let html = "<link rel=stylesheet href='https://t/css'><style>@import url('https://t/i'); p{background:url(http://t/bg)}</style><p style=\"background:url('//t/x')\">p</p><img src=\"https://tracker.example/p.gif\"><img src=dot.png><img srcset=\"https://t/a 2x\"><a href=\"https://example.com\">link</a>"
        let s = HTMLScrub.noScriptNoRemote(html)
        #expect(!s.contains("https://t") && !s.contains("http://t") && !s.contains("//t/") && !s.contains("tracker"), "\(s)")
        #expect(s.contains("src=dot.png") && s.contains(">link</a>"))
    }

    /// Release review 0.2.1 M1: script URLs a browser still runs although
    /// the plain text "javascript:" isn't there.
    @Test func scriptURLsInEveryForm() {
        let bad = [
            // `/` as the attribute separator
            #"<a/href="javascript:alert(1)">x</a>"#,
            #"<a/href=javascript:alert(1)>x</a>"#,
            #"<a title="t"href="javascript:alert(1)">x</a>"#,
            #"<img/src='vbscript:msgbox(1)'>"#,
            // character references: decimal, hex, no `;`, leading zeros, named
            #"<a href="&#106;avascript:alert(1)">x</a>"#,
            #"<a href="&#x6a;avascript:alert(1)">x</a>"#,
            #"<a href="&#X6A;&#x61;vascript:alert(1)">x</a>"#,
            #"<a href="&#106avascript:alert(1)">x</a>"#,
            #"<a href="&#0000106;avascript:alert(1)">x</a>"#,
            #"<a href="javascript&colon;alert(1)">x</a>"#,
            #"<a href="java&Tab;script:alert(1)">x</a>"#,
            #"<a href="java&NewLine;script:alert(1)">x</a>"#,
            #"<a href=&#106;&#97;&#118;&#97;&#115;&#99;&#114;&#105;&#112;&#116;&#58;alert(1)>x</a>"#,
            // whitespace and control characters inside or before the scheme
            "<a href=\"java\tscript:alert(1)\">x</a>",
            "<a href=\"java\nscript:alert(1)\">x</a>",
            "<a href=\"java\rscript:alert(1)\">x</a>",
            "<a href=\"\u{01}javascript:alert(1)\">x</a>",
            "<a href=\"jav\u{0B}ascript:alert(1)\">x</a>",
            "<a href=\" \t javascript:alert(1)\">x</a>",
            "<a href=\"JaVa\tScRiPt:alert(1)\">x</a>",
            "<a href=\"vb&#x09;script:msgbox(1)\">x</a>",
            "<form action=\"&#x6A;avascript:alert(1)\"><button formaction='java&#9;script:alert(1)'>b</button></form>",
            "<svg><a xlink:href=\"java&#10;script:alert(1)\">x</a></svg>",
        ]
        for html in bad {
            let s = HTMLScrub.noScript(html)
            #expect(!s.lowercased().contains("alert(1)") && !s.lowercased().contains("msgbox(1)"), "\(html) -> \(s)")
            #expect(s.contains("\"#\""), "the link is kept, pointing nowhere: \(s)")
            #expect(HTMLScrub.noScriptNoRemote(html).contains("\"#\""))
        }
        // Not script URLs: kept as written.
        let good = [
            #"<a href="https://example.com/javascript:x">x</a>"#,
            #"<a href="docs/javascript.html">x</a>"#,
            ##"<a href="#javascript:x">x</a>"##,
            #"<a href="a?b=1&amp;c=2">x</a>"#,
            #"<img src="data:image/png;base64,iVBORw0KGgo=">"#,
        ]
        for html in good { #expect(HTMLScrub.noScript(html) == html, "\(html)") }
        // Text outside tags is never rewritten.
        let text = "<p>type javascript:alert(1) or href=&#106;avascript:</p>"
        #expect(HTMLScrub.noScript(text) == text)
    }

    @Test func characterReferences() {
        #expect(HTMLScrub.decodeCharacterReferences("&#106;&#x61;&#X76;&#97&colon;&Tab;&amp;&unknown;&#99999999999;") == "java:\t&&unknown;\u{FFFD}")
    }
}
