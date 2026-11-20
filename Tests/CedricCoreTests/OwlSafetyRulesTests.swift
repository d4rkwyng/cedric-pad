import Foundation
import Testing
@testable import CedricCore

/// Pack 7: safety help. The downloaded-script offer, the secrets' Fix it
/// and the new secret shapes. Fake secrets are built in pieces, so no
/// scanner takes this file for a leak.
@Suite struct OwlSafetyRulesTests {
    func find(_ id: String, _ text: String, language: String = "plain", fileName: String? = nil,
              facts: OwlDocumentFacts = OwlDocumentFacts()) -> OwlHint? {
        OwlLanguageRulesTests.check(text, language: language, fileName: fileName, facts: facts).first { $0.id == id }
    }

    func apply(_ h: OwlHint, to text: String) -> String {
        (text as NSString).replacingCharacters(in: h.range!, with: h.replacement!)
    }

    @Test func downloadedScriptOffer() throws {
        let q = OwlDocumentFacts(isQuarantined: true)
        let h = try #require(find(SafetyRules.downloadedScriptID, "echo hi\n", language: "shell", fileName: "install.sh", facts: q))
        #expect(h.kind == .tip && h.range == nil && h.replacement == nil)
        // It comes first: before the script's own hints.
        let ids = OwlLanguageRulesTests.languageIDs("NAME = x\n", language: "shell", fileName: "a.sh", facts: q)
        #expect(ids.first == SafetyRules.downloadedScriptID)
        for (lang, name) in [("python", "a.py"), ("powershell", "a.ps1"), ("batch", "a.bat"), ("ruby", "a.rb")] {
            #expect(find(SafetyRules.downloadedScriptID, "x\n", language: lang, fileName: name, facts: q) != nil, "\(lang)")
        }
        // Not without the attribute (or once offered); not for documents; still for generated or minified scripts.
        #expect(find(SafetyRules.downloadedScriptID, "echo hi\n", language: "shell", fileName: "a.sh") == nil)
        #expect(find(SafetyRules.downloadedScriptID, "# Read me\n", language: "markdown", fileName: "a.md", facts: q) == nil)
        #expect(find(SafetyRules.downloadedScriptID, "{\"a\": 1}\n", language: "json", fileName: "a.json", facts: q) == nil)
        #expect(find(SafetyRules.downloadedScriptID, "as_fn_exit 1\n", language: "shell", fileName: "configure", facts: q) != nil)
    }

    @Test func newSecretShapes() throws {
        let google = "AI" + "za" + "Sy" + String(repeating: "Fa1_k", count: 6) + "e-9"
        let gitlab = "gl" + "pat-" + String(repeating: "Fk3x", count: 5)
        let npm = "np" + "m_" + String(repeating: "aB3d", count: 9)
        let slack = "https://hooks.sl" + "ack.com/services/" + "T0FAKE00/B0FAKE00/" + String(repeating: "fAk3", count: 6)
        for (s, kind) in [(google, "a Google API key"), (gitlab, "a GitLab token"), (npm, "an npm token"), (slack, "a Slack webhook")] {
            let text = "config = \"\(s)\"\n"
            let h = try #require(find(RulesHintProvider.secretID, text), "\(kind)")
            #expect(h.detail?.contains(kind) == true, "\(kind)")
            #expect(apply(h, to: text) == "config = \"<REDACTED>\"\n", "\(kind)")
        }
        // Near misses: too short, longer than the shape, part of a word, docs.
        for s in ["AI" + "za" + "short", "AI" + "za" + String(repeating: "x", count: 40), "x" + "AI" + "za" + String(repeating: "Ab3", count: 12) + "Ab",
                  "gl" + "pat-" + "short", "np" + "m_" + "install", "https://hooks.sl" + "ack.com/services/", "The glpat- prefix marks GitLab tokens."] {
            #expect(find(RulesHintProvider.secretID, "see \(s) here\n") == nil, "\(s)")
        }
    }

    @Test func passwordInAURL() throws {
        let text = "DATABASE_URL=postgres://app:" + "Xk29f" + "Pq7v@db.internal:5432/app\n"
        let h = try #require(find(RulesHintProvider.secretID, text, language: "ini", fileName: ".env"))
        #expect(h.detail?.contains("a password in a URL") == true)
        #expect(apply(h, to: text) == "DATABASE_URL=postgres://app:<password>@db.internal:5432/app\n")
        for t in ["postgres://user:password@localhost/db", "postgres://app:${DB_PASS}@db/app", "mysql://root:<pass>@host/db",
                  "postgres://postgres:postgres@localhost:5432/test", "amqp://guest:guest@localhost//", "redis://:****@cache:6379",
                  "\"%s://%s:%s@%s\" % (scheme, user, pw, host)", "https://user:token@github.com/x", "ftp://anonymous:anonymous@ftp.x.org",
                  "https://example.com/a:b@c", "mongodb://admin:yourpassword@host", "postgres://app:mysecret@host",
                  "git@github.com:owner/repo.git", "http://[::1]:8080/"] {
            #expect(find(RulesHintProvider.secretID, t + "\n") == nil, "\(t)")
        }
    }

    @Test func privateKeyPlaceholderTakesTheWholeBlock() throws {
        let d = String(repeating: "-", count: 5)
        let text = "a\n" + d + "BEGIN OPENSSH " + "PRIVATE KEY" + d + "\nb3BlbnNzaC1rZXkt\nAAAA\n" + d + "END OPENSSH " + "PRIVATE KEY" + d + "\nz\n"
        let h = try #require(find(RulesHintProvider.secretID, text))
        #expect(apply(h, to: text) == "a\n<private key removed>\nz\n")
    }
}
