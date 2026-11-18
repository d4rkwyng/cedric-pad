import Foundation
import Testing
@testable import CedricCore

/// Certificates made on the spot with macOS's own /usr/bin/openssl
/// (LibreSSL), so nothing secret or expiring is checked in.
final class CertFixtures: @unchecked Sendable {
    static let shared = CertFixtures()
    static let available = FileManager.default.isExecutableFile(atPath: "/usr/bin/openssl")
    let dir: URL

    private init() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("cedric-cert-tests-\(getpid())")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard Self.available else { return }
        // A server certificate with names, usages and a 30-day life.
        ssl("req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", "leaf.key", "-out", "leaf.pem", "-days", "30",
            "-subj", "/CN=example.test/O=Cedric Test/C=US",
            "-addext", "subjectAltName=DNS:example.test,DNS:www.example.test,IP:10.0.0.1",
            "-addext", "basicConstraints=critical,CA:FALSE",
            "-addext", "keyUsage=digitalSignature,keyEncipherment",
            "-addext", "extendedKeyUsage=serverAuth,clientAuth")
        ssl("x509", "-in", "leaf.pem", "-outform", "DER", "-out", "leaf.der")
        // An EC (named curve P-256) certificate that lives one day.
        ssl("ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", "short.key")
        ssl("req", "-new", "-x509", "-key", "short.key", "-out", "short.pem", "-days", "1", "-subj", "/CN=short.test")
        // The same curve given by explicit parameters (LibreSSL's -newkey ec): Security reads no key from it.
        ssl("req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:prime256v1", "-nodes", "-keyout", "explicit.key",
            "-out", "explicit.pem", "-days", "1", "-subj", "/CN=explicit.test")
        // A chain: a CA and a certificate it signed.
        ssl("req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", "ca.key", "-out", "ca.pem", "-days", "365",
            "-subj", "/CN=Cedric Test CA/O=Cedric Test", "-addext", "basicConstraints=critical,CA:TRUE",
            "-addext", "keyUsage=keyCertSign,cRLSign")
        ssl("req", "-new", "-newkey", "rsa:2048", "-nodes", "-keyout", "child.key", "-out", "child.csr",
            "-subj", "/CN=child.test/O=Cedric Child/OU=Owls")
        ssl("x509", "-req", "-in", "child.csr", "-CA", "ca.pem", "-CAkey", "ca.key", "-CAcreateserial", "-out", "child.pem", "-days", "90")
        ssl("crl2pkcs7", "-nocrl", "-certfile", "child.pem", "-certfile", "ca.pem", "-outform", "DER", "-out", "chain.p7b")
        ssl("crl2pkcs7", "-nocrl", "-certfile", "child.pem", "-certfile", "ca.pem", "-out", "chain-pem.p7b")
    }

    @discardableResult
    func ssl(_ args: String...) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        p.arguments = args
        p.currentDirectoryURL = dir
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try? p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    func text(_ name: String) -> String { (try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)) ?? "" }
    func data(_ name: String) -> Data { (try? Data(contentsOf: dir.appendingPathComponent(name))) ?? Data() }
}

@Suite(.enabled(if: CertFixtures.available, "needs /usr/bin/openssl")) struct CertificateTests {
    let f = CertFixtures.shared

    @Test func readsAServerCertificate() throws {
        let items = Certificates.items(inText: "intro text\n" + f.text("leaf.pem"))
        #expect(items.count == 1)
        let c = try #require(items.first?.item.certificate)
        #expect(c.summary == "example.test")
        #expect(c.subject == [CertificateField("Common name", "example.test"), CertificateField("Organization", "Cedric Test"), CertificateField("Country", "US")])
        #expect(c.isSelfIssued)
        #expect(CertificateInfo.distinguishedName(c.subject) == "CN=example.test, O=Cedric Test, C=US")
        #expect(c.alternativeNames == ["example.test", "www.example.test", "10.0.0.1"])
        #expect(c.publicKey == "RSA 2048-bit")
        #expect(c.signatureAlgorithm == "SHA-256 with RSA")
        #expect(c.isCA == false)
        #expect(c.keyUsage == ["Digital signature", "Key encipherment"])
        #expect(c.extendedKeyUsage == ["Server authentication (TLS)", "Client authentication (TLS)"])
        let days = c.notAfter!.timeIntervalSince(c.notBefore!) / 86_400
        #expect(abs(days - 30) < 0.01)
        // Serial and fingerprints as openssl prints them.
        let serial = f.ssl("x509", "-in", "leaf.pem", "-noout", "-serial").split(separator: "=").last!.trimmingCharacters(in: .whitespacesAndNewlines)
        func digits(_ x: String) -> String { String(x.replacingOccurrences(of: ":", with: "").uppercased().drop { $0 == "0" }) }
        #expect(!serial.isEmpty && digits(c.serialNumber) == digits(serial))
        let sha256 = f.ssl("x509", "-in", "leaf.pem", "-noout", "-fingerprint", "-sha256").split(separator: "=").last!.trimmingCharacters(in: .whitespacesAndNewlines)
        let sha1 = f.ssl("x509", "-in", "leaf.pem", "-noout", "-fingerprint", "-sha1").split(separator: "=").last!.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(c.sha256 == sha256 && c.sha1 == sha1)
        // The DER file reads the same.
        let der = Certificates.items(inDER: f.data("leaf.der"))
        #expect(der.count == 1 && der.first?.certificate?.sha256 == c.sha256)
        #expect(PEM.encode(c.der) == f.text("leaf.pem"))
    }

    @Test func readsAnECCertificateAndAChain() throws {
        let ec = try #require(Certificates.items(inText: f.text("short.pem")).first?.item.certificate)
        #expect(ec.publicKey == "EC P-256" && ec.signatureAlgorithm == "ECDSA with SHA-256")
        #expect(ec.isCA == nil && ec.keyUsage.isEmpty)
        #expect(Certificates.items(inText: f.text("explicit.pem")).first?.item.certificate?.publicKey == "EC P-256")

        let chain = Certificates.items(inText: f.text("child.pem") + "\n" + f.text("ca.pem"))
        #expect(chain.count == 2)
        let leaf = try #require(chain[0].item.certificate), ca = try #require(chain[1].item.certificate)
        #expect(leaf.issuer == ca.subject && !leaf.isSelfIssued)
        #expect(leaf.subject.map(\.value) == ["child.test", "Cedric Child", "Owls"])
        #expect(ca.isCA == true && ca.keyUsage == ["Certificate signing", "CRL signing"])
        // Ranges are the blocks' own.
        let text = f.text("child.pem") + "\n" + f.text("ca.pem")
        #expect((text as NSString).substring(with: chain[1].range).hasPrefix("-----BEGIN CERTIFICATE-----"))
        #expect((text as NSString).substring(with: chain[1].range).hasSuffix("-----END CERTIFICATE-----"))
    }

    @Test func readsPKCS7BundlesDERAndPEM() {
        let der = Certificates.items(inDER: f.data("chain.p7b"))
        #expect(der.compactMap { $0.certificate?.summary }.sorted() == ["Cedric Test CA", "child.test"])
        let pem = Certificates.items(inText: f.text("chain-pem.p7b"))
        #expect(pem.compactMap { $0.item.certificate?.summary }.sorted() == ["Cedric Test CA", "child.test"])
        #expect(Certificates.isDERFile(prefix: Array(f.data("chain.p7b").prefix(8)), fileName: "chain.p7b"))
    }

    @Test func requestsAndPrivateKeysAndOtherBlocks() {
        let csr = Certificates.items(inText: f.text("child.csr"))
        #expect(csr.count == 1)
        #expect(csr.first?.item == .request(subject: [CertificateField("Common name", "child.test"),
                                                      CertificateField("Organization", "Cedric Child"),
                                                      CertificateField("Organizational unit", "Owls")]))
        // A private key is found and never decoded.
        let key = f.text("leaf.key")
        let blocks = PEM.blocks(in: key + f.text("leaf.pem"))
        #expect(blocks.count == 2 && blocks[0].isPrivateKey && blocks[0].der == nil && blocks[1].der != nil)
        #expect(Certificates.items(inText: key).map(\.item) == [.privateKey])
        // A damaged certificate and a label Cedric doesn't read.
        let bad = "-----BEGIN CERTIFICATE-----\nnot base64 at all!!\n-----END CERTIFICATE-----\n"
        #expect(Certificates.items(inText: bad).map(\.item) == [.damaged("CERTIFICATE")])
        let other = "-----BEGIN DH PARAMETERS-----\nMAA=\n-----END DH PARAMETERS-----\n"
        #expect(Certificates.items(inText: other).map(\.item) == [.other("DH PARAMETERS")])
        // An unterminated block is skipped.
        #expect(PEM.blocks(in: "-----BEGIN CERTIFICATE-----\nMIIB\n").isEmpty)
    }

    @Test func validityBadgesAndTheOwl() throws {
        let c = try #require(Certificates.items(inText: f.text("leaf.pem")).first?.item.certificate)
        let start = c.notBefore!
        #expect(c.badge(at: start.addingTimeInterval(3600)) == "Expires in 29 days")
        #expect(c.badge(at: start.addingTimeInterval(-86_400 * 2)) == "Not yet valid")
        #expect(c.badge(at: c.notAfter!.addingTimeInterval(60)) == "Expired")
        #expect(c.badge(at: c.notAfter!.addingTimeInterval(-3600)) == "Expires today")
        #expect(c.needsAttention(at: start.addingTimeInterval(3600)))      // 29 days left
        #expect(!c.needsAttention(at: start.addingTimeInterval(3600), within: 10))

        let rules = RulesHintProvider()
        func hint(_ text: String, now: Date) -> OwlHint? {
            let ctx = OwlContext(fileName: "site.pem", language: "plain", text: text, textStart: 0,
                                 visibleRange: NSRange(location: 0, length: 0), selection: nil, documentID: UUID(), editGeneration: 0)
            return rules.check(ctx, facts: OwlDocumentFacts(now: now)).first { $0.id == RulesHintProvider.certificateExpiryID }
        }
        // The CA (a year) first, then the one-day certificate: the owl points at the second.
        let text = f.text("ca.pem") + f.text("short.pem")
        let short = try #require(Certificates.items(inText: f.text("short.pem")).first?.item.certificate)
        let soon = try #require(hint(text, now: short.notBefore!.addingTimeInterval(60)))
        #expect(soon.title == "This certificate expires today." && soon.kind == .warning)
        #expect((text as NSString).substring(with: soon.range!).contains(f.text("short.pem").split(separator: "\n")[1]))
        let gone = try #require(hint(text, now: short.notAfter!.addingTimeInterval(86_400 * 3 + 60)))
        #expect(gone.title == "This certificate expired 3 days ago.")
        #expect(gone.detail?.hasPrefix("“short.test” was valid until") == true)
        // Plenty of time left: nothing.
        #expect(hint(f.text("ca.pem"), now: Date()) == nil)
    }

    @Test func certificateTabsComeBackWithTheSession() throws {
        let tab = SessionTab(path: "/tmp/site.der", certificate: OfficeTabState())
        let back = try JSONDecoder().decode(SessionTab.self, from: JSONEncoder().encode(tab))
        #expect(back.certificate != nil && back.isViewer && back.office == nil)
        #expect(!SessionTab(path: "/tmp/a.txt").isViewer)
    }

    @Test func whichFilesAreCertificates() {
        #expect(Certificates.isDERFile(prefix: [0x30, 0x82, 0x03, 0x01], fileName: "site.cer"))
        #expect(Certificates.isDERFile(prefix: [0x30, 0x82], fileName: "x.DER"))
        #expect(!Certificates.isDERFile(prefix: Array("-----BEGIN".utf8), fileName: "site.crt"))   // PEM text: the editor
        #expect(!Certificates.isDERFile(prefix: [0x30, 0x82], fileName: "site.bin"))
        #expect(Certificates.isCertificateText("anything", fileName: "site.pem"))
        #expect(Certificates.isCertificateText("notes\n" + f.text("leaf.pem"), fileName: "notes.txt"))
        #expect(!Certificates.isCertificateText("just notes", fileName: "notes.txt"))
        // Base64 isn't checked for spelling in certificate and key files.
        #expect(!SpellScope.checks(language: .plain, fileName: "site.pem") && !SpellScope.checks(language: .plain, fileName: "site.key"))
        #expect(DocumentKind.detect(prefix: Array(f.data("leaf.der").prefix(32)), fileName: "leaf.der") == .certificate)
        #expect(DocumentKind.detect(prefix: Array(f.text("leaf.pem").utf8.prefix(32)), fileName: "leaf.crt") == .text)
    }
}
