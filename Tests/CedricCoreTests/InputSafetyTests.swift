import Foundation
import Testing
@testable import CedricCore

/// Security audit M1(b) and L2.
@Suite struct InputSafetyTests {
    @Test func oneBasedNeverOverflows() {
        #expect(OneBased.index(Int.min, count: 10) == 0)
        #expect(OneBased.index(-5, count: 10) == 0)
        #expect(OneBased.index(0, count: 10) == 0)
        #expect(OneBased.index(1, count: 10) == 0)
        #expect(OneBased.index(3, count: 10) == 2)
        #expect(OneBased.index(Int.max, count: 10) == 9)
        #expect(OneBased.index(5, count: 0) == 0)
    }

    @Test func specialFilesAreNamed() throws {
        let d = tempDir()
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: d) }
        let fifo = d.appendingPathComponent("pipe").path
        #expect(mkfifo(fifo, 0o600) == 0)
        #expect(SpecialFile.kind(atPath: fifo) == "a named pipe")
        #expect(SpecialFile.kind(atPath: "/dev/zero") == "a device")
        #expect(SpecialFile.kind(atPath: "/dev/random") == "a device")
        let link = d.appendingPathComponent("zero-link").path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: "/dev/zero")
        #expect(SpecialFile.kind(atPath: link) == "a device", "a link to a device is followed")
        try "x".write(toFile: d.appendingPathComponent("f.txt").path, atomically: true, encoding: .utf8)
        #expect(SpecialFile.kind(atPath: d.appendingPathComponent("f.txt").path) == nil)
        #expect(SpecialFile.kind(atPath: d.path) == nil, "folders are the caller's call")
        #expect(SpecialFile.kind(atPath: d.appendingPathComponent("missing").path) == nil)
    }
}
