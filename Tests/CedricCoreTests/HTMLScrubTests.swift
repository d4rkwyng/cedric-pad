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
}
