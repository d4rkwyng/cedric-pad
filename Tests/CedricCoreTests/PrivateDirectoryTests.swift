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

    @Test func makeRefusesALinkAFileAndAnotherUsersFolder() throws {
        let t = try temp(); defer { try? fm.removeItem(at: t) }
        let real = t.appendingPathComponent("real")
        try fm.createDirectory(at: real, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let link = t.appendingPathComponent("Cedric")
        try fm.createSymbolicLink(at: link, withDestinationURL: real)
        #expect(throws: PrivateDirectory.Failure.notPrivate(path: link.path, why: "a symbolic link")) {
            try PrivateDirectory.make(link, root: t.appendingPathComponent("elsewhere"))
        }
        // A link as the root, with dir inside it, is refused too.
        #expect(throws: (any Error).self) { try PrivateDirectory.make(link.appendingPathComponent("Session"), root: link) }
        let file = t.appendingPathComponent("file")
        try Data().write(to: file)
        #expect(throws: (any Error).self) { try PrivateDirectory.make(file) }
        #expect(throws: PrivateDirectory.Failure.notPrivate(path: file.path, why: "not a folder")) { try PrivateDirectory.verify(file.path) }
        // Root's /usr: not this user's, not changed.
        #expect(throws: PrivateDirectory.Failure.notPrivate(path: "/usr", why: "owned by another user")) {
            try PrivateDirectory.make(URL(fileURLWithPath: "/usr"), root: t)
        }
    }

    @Test func onlyExactly0700Passes() throws {
        let t = try temp(); defer { try? fm.removeItem(at: t) }
        let d = t.appendingPathComponent("d")
        try fm.createDirectory(at: d, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o750])
        #expect(throws: PrivateDirectory.Failure.notPrivate(path: d.path, why: "mode 750")) { try PrivateDirectory.verify(d.path) }
        chmod(d.path, 0o2700)
        #expect(throws: (any Error).self) { try PrivateDirectory.verify(d.path) }
        try PrivateDirectory.make(d, root: t.appendingPathComponent("elsewhere"))
        #expect(mode(d) == 0o700, "a setgid bit is cleared too")
    }

    @Test func sessionFilesAre0600EvenWithAWideUmask() throws {
        let t = try temp(); defer { try? fm.removeItem(at: t) }
        let store = SessionStore(directory: t.appendingPathComponent("Session"))
        let old = umask(0o022); defer { umask(old) }
        let id = UUID()
        // A buffer an older version left 0644 is replaced by a 0600 one.
        try fm.createDirectory(at: t.appendingPathComponent("Session"), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try Data("old".utf8).write(to: store.bufferURL(id))
        chmod(store.bufferURL(id).path, 0o644)
        try store.writeBuffer(id, text: "unsaved text")
        try store.save(Session(windows: []))
        #expect(mode(store.bufferURL(id)) == 0o600)
        #expect(mode(t.appendingPathComponent("Session/session.json")) == 0o600)
        #expect(store.readBuffer(id) == "unsaved text")
        let left = try fm.contentsOfDirectory(atPath: t.appendingPathComponent("Session").path).filter { $0.hasPrefix(".") }
        #expect(left.isEmpty, "no temp files left: \(left)")
    }

    @Test func aStaleEmptyTokenIsReplacedAFreshOneIsKept() throws {
        let t = try temp(); defer { try? fm.removeItem(at: t) }
        let dir = t.appendingPathComponent("Cedric")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let u = dir.appendingPathComponent("cli-token")
        // Fresh and empty: another run is filling it; left alone.
        #expect(fm.createFile(atPath: u.path, contents: Data(), attributes: [.posixPermissions: 0o600]))
        #expect(CLIToken.ensure(at: u) == nil)
        let size = try fm.attributesOfItem(atPath: u.path)[.size] as? NSNumber
        #expect(mode(u) == 0o600 && size?.intValue == 0)
        // Empty for a minute: a run died; replaced with a real token.
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-60)], ofItemAtPath: u.path)
        let token = try #require(CLIToken.ensure(at: u))
        #expect(token.count == 32 && mode(u) == 0o600)
        #expect(CLIToken.ensure(at: u) == token, "then kept")
        #expect(try fm.contentsOfDirectory(atPath: dir.path) == ["cli-token"], "no temp file left")
    }
}
