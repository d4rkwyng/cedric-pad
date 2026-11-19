import Foundation
import Testing
@testable import CedricCore

@Suite struct AboutInfoTests {
    @Test func helpOpensTheManualAtTheReleaseTagElseMain() {
        #expect(AboutInfo.help(version: "0.2.1").absoluteString == "https://github.com/d4rkwyng/owlink/blob/v0.2.1/docs/MANUAL.md")
        #expect(AboutInfo.help(version: "0.3.0-rc2").absoluteString == "https://github.com/d4rkwyng/owlink/blob/v0.3.0-rc2/docs/MANUAL.md")
        for dev in ["", "0.2.1-dev", "main", "0.2", "1.2.3.4", "v0.2.1"] {
            #expect(AboutInfo.help(version: dev).absoluteString == "https://github.com/d4rkwyng/owlink/blob/main/docs/MANUAL.md", "\(dev)")
        }
    }

    @Test func versionHasNoBuildNumber() {
        let v = AboutInfo.panelVersions(bundle: ["CFBundleShortVersionString": "0.2.1", "CFBundleVersion": "0.2.1"])
        #expect(v.application == "0.2.1" && v.build == "")
        #expect(AboutInfo.panelVersions(bundle: ["CFBundleVersion": "7"]).application == "7")
        #expect(AboutInfo.panelVersions(bundle: nil).application == CedricVersion.string)
    }

    @Test func licenceStaysOnOneLineAndCreditsAreThere() {
        #expect(AboutInfo.licence == "BSD-\u{2060}2-\u{2060}Clause license")
        #expect(AboutInfo.licence.replacingOccurrences(of: "\u{2060}", with: "") == "BSD-2-Clause license")
        #expect(AboutInfo.copyright == "© 2026 d4rkwyng" && AboutInfo.author == "Made by d4rkwyng")
        #expect(AboutInfo.llamaCredit.contains("llama.cpp") && AboutInfo.llamaCredit.contains("MIT"))
        #expect(AboutInfo.tribute.contains("not affiliated with or endorsed by Sierra"))
        #expect(AboutInfo.repository.absoluteString == "https://github.com/d4rkwyng/owlink")
        #expect(AboutInfo.newIssue.absoluteString == "https://github.com/d4rkwyng/owlink/issues/new")
    }
}
