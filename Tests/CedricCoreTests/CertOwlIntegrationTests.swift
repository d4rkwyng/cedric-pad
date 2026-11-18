import Foundation
import Testing
@testable import CedricCore

/// Where the certificate work (ps-cert) meets the owl fixes (owl-fixes):
/// PEM is data for the whitespace and doubled-word fixes, a PowerShell
/// here-string keeps its trailing spaces, and a DER certificate goes to
/// its viewer tab before any binary-file check.
@Suite struct CertOwlIntegrationTests {
    let rules = RulesHintProvider()

    func ids(_ text: String, language: String = "plain", fileName: String? = nil) -> [OwlHint] {
        let ctx = OwlContext(fileName: fileName, language: language, text: text, textStart: 0,
                             visibleRange: NSRange(location: 0, length: 0), selection: nil, documentID: UUID(), editGeneration: 0)
        return rules.check(ctx, facts: OwlDocumentFacts())
    }

    @Test func pemIsNeitherTrimmedNorProofread() {
        // Trailing spaces on armour lines and a word twice in the
        // explanatory header: none of it is the owl's to change.
        let pem = "Issued to the the server team  \nBag Attributes  \n    friendlyName: web  \n"
            + "-----BEGIN CERTIFICATE-----  \nMIIBszCCAVmgAwIBAgIUXzZ  \nAAAA  \nAAAA  \n-----END CERTIFICATE-----  \n"
        for name in ["web.pem", "web.crt", "web.key", "web.csr", nil] as [String?] {
            let hints = ids(pem, fileName: name).map(\.id)
            #expect(!hints.contains(RulesHintProvider.trailingID), "trim offered for \(name ?? "untitled")")
            #expect(!hints.contains(RulesHintProvider.duplicateWordID), "doubled word offered for \(name ?? "untitled")")
        }
        // The same prose without PEM in it still gets both.
        let prose = "Issued to the the server team  \nfor the web site  \nand the mail host  \nand the rest  \nof it  \n"
        let hints = ids(prose, fileName: "notes.txt").map(\.id)
        #expect(hints.contains(RulesHintProvider.trailingID))
        #expect(hints.contains(RulesHintProvider.duplicateWordID))
    }

    @Test func powerShellHereStringKeepsTrailingSpaces() throws {
        let ps = "$a = 1  \n$b = 2  \n$e = 5  \n$f = 6  \n$body = @\"\nline one  \nline two  \n\"@\n$c = @'\nraw  \n'@\n$d = 3  \n"
        let h = try #require(ids(ps, language: "powershell", fileName: "x.ps1").first { $0.id == RulesHintProvider.trailingID })
        let fixed = (ps as NSString).replacingCharacters(in: h.range!, with: h.replacement!)
        #expect(fixed == "$a = 1\n$b = 2\n$e = 5\n$f = 6\n$body = @\"\nline one  \nline two  \n\"@\n$c = @'\nraw  \n'@\n$d = 3\n")
        // Not PowerShell: an @" means nothing, the lines are trimmed.
        let sh = try #require(ids(ps, language: "plain", fileName: "x.txt").first { $0.id == RulesHintProvider.trailingID })
        #expect(!(ps as NSString).replacingCharacters(in: sh.range!, with: sh.replacement!).contains("line one  "))
    }

    @Test func derCertificateRoutesBeforeBinaryCheck() {
        // A DER certificate's bytes look binary (NUL bytes) …
        let der: [UInt8] = [0x30, 0x82, 0x01, 0x0A, 0x30, 0x81, 0xB2, 0xA0, 0x03, 0x02, 0x01, 0x02, 0x02, 0x00, 0x00, 0x00]
        #expect(TextCodec.looksBinary(Data(der)))
        // … but by its name and ASN.1 header it opens in the certificate tab, never as text.
        for name in ["a.der", "a.cer", "a.crt", "bundle.p7b"] {
            #expect(DocumentKind.detect(prefix: der, fileName: name) == .certificate)
        }
        // PEM text in a .crt is text (the panel beside it), and an
        // unknown binary .crt is text too: the binary bar, not the cert tab.
        #expect(DocumentKind.detect(prefix: Array("-----BEGIN CERTIFICATE-----\n".utf8), fileName: "a.crt") == .text)
        #expect(DocumentKind.detect(prefix: [0x00, 0x01, 0x02, 0x03], fileName: "a.crt") == .text)
        #expect(DocumentKind.detect(prefix: der, fileName: "a.bin") == .text)
    }
}
