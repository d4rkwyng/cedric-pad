import Foundation
import Testing
@testable import CedricCore

/// ~/Library/Application Support/Cedric and the folders Cedric makes in it
/// are 0700; the CLI token in it stays 0600.
@Suite struct PrivateDirectoryTests {
    let fm = FileManager.default

    func temp() throws -> URL {
        let u = URL(fileURLWithPath: NSTemporaryDirectory() + "cedric-private-dir-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    func mode(_ u: URL) -> Int? {
        (try? fm.attributesOfItem(atPath: u.path)[.posixPermissions] as? NSNumber)?.intValue
    }

    @Test func newFoldersAndTheirParentsAreOwnerOnly() throws {
        let t = try temp(); defer { try? fm.removeItem(at: t) }
        let root = t.appendingPathComponent("Cedric"), dir = root.appendingPathComponent("Models/.partial")
        try PrivateDirectory.make(dir, root: root)
        for u in [root, root.appendingPathComponent("Models"), dir] { #expect(mode(u) == 0o700, "\(u.lastPathComponent)") }
    }

    @Test func widerFoldersAreTightenedOnlyInsideTheRoot() throws {
        let t = try temp(); defer { try? fm.removeItem(at: t) }
        let root = t.appendingPathComponent("Cedric"), session = root.appendingPathComponent("Session")
        try fm.createDirectory(at: session, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        // A folder outside the root leaves the root alone.
        let other = t.appendingPathComponent("Other")
        try PrivateDirectory.make(other, root: root)
        #expect(mode(other) == 0o700 && mode(root) == 0o755)
        try PrivateDirectory.make(session, root: root)
        #expect(mode(root) == 0o700 && mode(session) == 0o700)
    }

    @Test func aLinkIsNotFollowed() throws {
        let t = try temp(); defer { try? fm.removeItem(at: t) }
        let real = t.appendingPathComponent("real")
        try fm.createDirectory(at: real, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        let link = t.appendingPathComponent("Cedric")
        try fm.createSymbolicLink(at: link, withDestinationURL: real)
        #expect(!PrivateDirectory.tighten(link.path))
        #expect(mode(real) == 0o755)
        #expect(PrivateDirectory.tighten(real.path) && mode(real) == 0o700)
    }

    @Test func tokenFolderIsTightenedAndTheTokenStays0600() throws {
        let t = try temp(); defer { try? fm.removeItem(at: t) }
        let dir = t.appendingPathComponent("Cedric")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        let tokenURL = dir.appendingPathComponent("cli-token")
        let token = try #require(CLIToken.ensure(at: tokenURL))
        #expect(mode(dir) == 0o700)
        #expect(mode(tokenURL) == 0o600)
        // Session setup in the same folder leaves the token alone.
        let store = SessionStore(directory: dir.appendingPathComponent("Session"))
        try store.save(Session(windows: []))
        try store.writeBuffer(UUID(), text: "unsaved")
        #expect(mode(dir.appendingPathComponent("Session")) == 0o700)
        #expect(mode(tokenURL) == 0o600)
        #expect(CLIToken.ensure(at: tokenURL) == token)
    }

    @Test func sessionFolderIsMadeOwnerOnlyAndRemadeIfRemoved() throws {
        let t = try temp(); defer { try? fm.removeItem(at: t) }
        let dir = t.appendingPathComponent("Session")
        let store = SessionStore(directory: dir)
        try store.save(Session(windows: []))
        #expect(mode(dir) == 0o700)
        try fm.removeItem(at: dir)
        try store.save(Session(windows: []))
        #expect(mode(dir) == 0o700 && store.load() != nil)
    }
}
