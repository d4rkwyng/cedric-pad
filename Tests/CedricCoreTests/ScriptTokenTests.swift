import Foundation
import Testing
@testable import CedricCore

/// Scripts/cedric's token(): the real function from the script, run by bash
/// with HOME pointed at a fresh folder.
@Suite(.offPool) struct ScriptTokenTests {
    let fm = FileManager.default

    /// `token_file=` through the end of `token() { … }`, from the script.
    static func tokenFunction() throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("Scripts/cedric"), encoding: .utf8)
        let start = try #require(text.range(of: "token_file=\"$HOME"))
        let body = try #require(text.range(of: "\ntoken() {", range: start.upperBound..<text.endIndex))
        let end = try #require(text.range(of: "\n}\n", range: body.upperBound..<text.endIndex))
        return String(text[start.lowerBound..<end.upperBound])
    }

    func home() throws -> String {
        let h = NSTemporaryDirectory() + "cedric-script-token-\(UUID().uuidString)"
        try fm.createDirectory(atPath: h + "/Library/Application Support", withIntermediateDirectories: true)
        return h
    }

    /// Runs `script` (after the token function) under bash; stdout.
    func bash(_ script: String, home: String) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-c", "set -euo pipefail\n" + (try Self.tokenFunction()) + script]
        p.environment = ["HOME": home, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        #expect(p.terminationStatus == 0)
        return String(decoding: data, as: UTF8.self)
    }

    func mode(_ path: String) -> Int? {
        (try? fm.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)?.intValue
    }

    func cedricDir(_ h: String) -> String { h + "/Library/Application Support/Cedric" }

    @Test func madeOnceIntoAPrivateFolderNoTempLeft() throws {
        let h = try home(); defer { try? fm.removeItem(atPath: h) }
        let t = try bash("token", home: h)
        #expect(t.count == 32 && t.allSatisfy(\.isHexDigit))
        #expect(try bash("token", home: h) == t, "read, not remade")
        #expect(mode(cedricDir(h)) == 0o700)
        #expect(mode(cedricDir(h) + "/cli-token") == 0o600)
        #expect(try fm.contentsOfDirectory(atPath: cedricDir(h)) == ["cli-token"])
        // The app reads what the script made.
        #expect(CLIToken.read(URL(fileURLWithPath: cedricDir(h) + "/cli-token")) == t)
    }

    /// Several runs at once agree on one token: the hard link lets exactly
    /// one of them win, and nobody reads a half-written file.
    @Test func racingRunsAgree() throws {
        let h = try home(); defer { try? fm.removeItem(atPath: h) }
        let out = try bash("for i in 1 2 3 4 5 6 7 8; do (token; echo) & done; wait", home: h)
        let tokens = out.split(separator: "\n").map(String.init)
        #expect(tokens.count == 8)
        #expect(Set(tokens).count == 1 && tokens[0].count == 32)
        #expect(try fm.contentsOfDirectory(atPath: cedricDir(h)) == ["cli-token"])
    }

    /// A token already there (the app's) is kept, never replaced.
    @Test func keepsTheAppsToken() throws {
        let h = try home(); defer { try? fm.removeItem(atPath: h) }
        let u = URL(fileURLWithPath: cedricDir(h) + "/cli-token")
        let app = try #require(CLIToken.ensure(at: u))
        #expect(try bash("token", home: h) == app)
    }

    /// The app creates its file, then writes it: an empty read waits 50 ms
    /// and reads again.
    @Test func emptyReadIsRetried() throws {
        let h = try home(); defer { try? fm.removeItem(atPath: h) }
        let f = cedricDir(h) + "/cli-token"
        try fm.createDirectory(atPath: cedricDir(h), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let late = String(repeating: "ab", count: 16)
        // An empty file that stays empty for about 30 ms, then filled in place.
        let out = try bash("""
            : > "$token_file"; chmod 600 "$token_file"
            ( sleep 0.03; printf '\(late)\\n' >> "$token_file" ) &
            token; wait
            """, home: h)
        #expect(out == late)
    }

    /// A Cedric folder an older version left 0755 is tightened to 0700.
    @Test func widerFolderIsTightened() throws {
        let h = try home(); defer { try? fm.removeItem(atPath: h) }
        try fm.createDirectory(atPath: cedricDir(h), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        #expect(mode(cedricDir(h)) == 0o755)
        _ = try bash("token", home: h)
        #expect(mode(cedricDir(h)) == 0o700)
        #expect(mode(cedricDir(h) + "/cli-token") == 0o600)
    }
}
