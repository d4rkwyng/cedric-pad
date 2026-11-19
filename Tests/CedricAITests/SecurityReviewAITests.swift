import Foundation
import Testing
@testable import CedricAI
import CedricCore

/// The 0.2.1 security review's fixes (CedricAI side).
@Suite(.offPool) struct SecurityReviewAITests {
    // MARK: 6. DNS rebinding: connect to the checked address

    @Test func requestsGoToTheCheckedAddress() throws {
        let req = URLRequest(url: URL(string: "http://studio.local:1234/v1/chat/completions")!)
        let pin = LocalModelClient.Pin(host: "studio.local", addresses: ["fd00::5", "192.168.1.20"])
        let r = pin.apply(req)
        #expect(r.url?.absoluteString == "http://192.168.1.20:1234/v1/chat/completions", "IPv4 first")
        #expect(r.value(forHTTPHeaderField: "Host") == "studio.local:1234", "the name stays in the Host header")
        // IPv6 only: bracketed.
        let v6 = LocalModelClient.Pin(host: "box.ts.net", addresses: ["fd7a:115c:a1e0::1"]).apply(URLRequest(url: URL(string: "http://box.ts.net:11434/api/tags")!))
        #expect(v6.url?.absoluteString == "http://[fd7a:115c:a1e0::1]:11434/api/tags")
        #expect(v6.value(forHTTPHeaderField: "Host") == "box.ts.net:11434")
        // An address in the URL already: nothing to pin.
        let lit = URLRequest(url: URL(string: "http://127.0.0.1:1234/v1/models")!)
        #expect(LocalModelClient.Pin(host: "127.0.0.1", addresses: ["127.0.0.1"]).apply(lit) == lit)
        // https: the certificate is checked against the name; left alone.
        let tls = URLRequest(url: URL(string: "https://studio.local/v1/models")!)
        #expect(LocalModelClient.Pin(host: "studio.local", addresses: ["192.168.1.20"]).apply(tls) == tls)
        // Only an IPv6 link-local address (its interface was dropped): not pinned.
        #expect(LocalModelClient.Pin(host: "x.local", addresses: ["fe80::1"]).address == nil)
        // The redirect guard still allows the pinned server's own redirects.
        #expect(LocalEndpointPolicy.allowsRedirect(from: r.url!, to: URL(string: "http://192.168.1.20:1234/v1/models")!))
    }

    @Test func checkLocalPinsWhatItResolved() async throws {
        var client = LocalModelClient(baseURL: URL(string: "http://studio.local:1234/v1")!, timeout: 5)
        client.resolver = { _ in ["10.0.0.7"] }
        let pin = try await client.checkLocal()
        #expect(pin.address == "10.0.0.7")
        // A public answer is still refused.
        client.resolver = { _ in ["10.0.0.7", "8.8.8.8"] }
        await #expect(throws: LocalAIError.endpointNotLocal("studio.local")) { try await client.checkLocal() }
    }

    // MARK: 10. Installed models are re-hashed before a load

    @Test func modelIsRehashedAfterAnyChange() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let body = Data((0..<10_000).map { UInt8($0 % 251) })
        let model = testModel(body: body)
        let store = ModelStore(directory: dir)
        let file = store.fileURL(for: model)
        try body.write(to: file)
        #expect(store.verifiedForLoad(model), "the catalog's bytes load")
        #expect(FileManager.default.fileExists(atPath: store.stampURL(for: model).path), "and the check is remembered")
        #expect(store.verifiedForLoad(model))
        // Same size, other bytes, written in place: refused.
        var evil = body
        evil[5000] ^= 0xff
        let h = try FileHandle(forWritingTo: file)
        try h.seek(toOffset: 5000)
        try h.write(contentsOf: evil[5000..<5001])
        try h.close()
        #expect(!store.verifiedForLoad(model), "a changed file is hashed again and refused")
        // Swapped for another file (new inode), same size and bytes as the evil one: refused.
        try FileManager.default.removeItem(at: file)
        try evil.write(to: file)
        #expect(!store.verifiedForLoad(model))
        // A symbolic link to the right bytes: refused.
        let real = dir.appendingPathComponent("elsewhere.bin")
        try body.write(to: real)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: real)
        #expect(!store.verifiedForLoad(model))
        // Put back: loads again; delete() takes the remembered check too.
        try FileManager.default.removeItem(at: file)
        try body.write(to: file)
        #expect(store.verifiedForLoad(model))
        try store.delete(model)
        #expect(!FileManager.default.fileExists(atPath: store.stampURL(for: model).path))
    }
}
