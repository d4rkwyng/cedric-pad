import Foundation
import Testing
@testable import CedricCore

/// Security audit L1 (save through a symlink) and L3 (image paste folder).
@Suite struct SafePathsTests {
    @Test func saveThroughALinkKeepsTheLinkAndTheMode() throws {
        let d = tempDir()
        let fm = FileManager.default
        try fm.createDirectory(at: d.appendingPathComponent("real"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: d) }
        let target = d.appendingPathComponent("real/secret.env")
        try "A=1\n".write(to: target, atomically: true, encoding: .utf8)
        #expect(chmod(target.path, 0o600) == 0)
        let link = d.appendingPathComponent("link.env")
        try fm.createSymbolicLink(atPath: link.path, withDestinationPath: "real/secret.env")   // relative
        let link2 = d.appendingPathComponent("link2.env")
        try fm.createSymbolicLink(atPath: link2.path, withDestinationPath: link.path)         // a chain
        #expect(SafePaths.writeTarget(for: link2).path == target.standardizedFileURL.path)
        // What EditorDocument.write does: an atomic write to the target.
        try Data("A=2\n".utf8).write(to: SafePaths.writeTarget(for: link2), options: .atomic)
        #expect((try? fm.destinationOfSymbolicLink(atPath: link.path)) == "real/secret.env", "the link is still a link")
        #expect(try String(contentsOf: link2, encoding: .utf8) == "A=2\n" && String(contentsOf: target, encoding: .utf8) == "A=2\n")
        let mode = (try fm.attributesOfItem(atPath: target.path)[.posixPermissions] as? NSNumber)?.intValue
        #expect(mode == 0o600, "the target keeps 0600: \(String(mode ?? -1, radix: 8))")
        let plain = d.appendingPathComponent("new.txt")
        #expect(SafePaths.writeTarget(for: plain) == plain.standardizedFileURL)
    }

    @Test func imagesFolderMustStayInside() throws {
        let d = tempDir()
        let fm = FileManager.default
        try fm.createDirectory(at: d.appendingPathComponent("doc"), withIntermediateDirectories: true)
        try fm.createDirectory(at: d.appendingPathComponent("elsewhere"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: d) }
        let doc = d.appendingPathComponent("doc")
        #expect(SafePaths.isInside(doc.appendingPathComponent("images"), doc), "a plain images folder (not there yet)")
        try fm.createSymbolicLink(at: doc.appendingPathComponent("images"), withDestinationURL: d.appendingPathComponent("elsewhere"))
        #expect(!SafePaths.isInside(doc.appendingPathComponent("images"), doc), "a symlink out is refused")
        try fm.createDirectory(at: d.appendingPathComponent("x.png"), withIntermediateDirectories: true)
        #expect(!SafePaths.isRegularFile(d.appendingPathComponent("x.png")), "a folder named x.png is not an image file")
        try Data([1]).write(to: d.appendingPathComponent("y.png"))
        #expect(SafePaths.isRegularFile(d.appendingPathComponent("y.png")))
    }
}
