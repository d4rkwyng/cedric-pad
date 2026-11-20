import Foundation
import Testing
@testable import CedricCore

@Suite struct DiskStampTests {
    let t = Date(timeIntervalSinceReferenceDate: 800_000_000.25)

    @Test func sameStampIsNoChange() {
        let s = DiskStamp(modified: t, size: 10)
        #expect(!DiskStamp.changed(known: s, current: s))
        // A date that went through the session file as a Double.
        #expect(!DiskStamp.changed(known: DiskStamp(modified: t.addingTimeInterval(0.0002)), current: s))
    }

    @Test func newerOrOlderDateIsAChange() {
        let known = DiskStamp(modified: t, size: 10)
        #expect(DiskStamp.changed(known: known, current: DiskStamp(modified: t.addingTimeInterval(1), size: 10)))
        // Another app restoring an older copy (its own date) counts too.
        #expect(DiskStamp.changed(known: known, current: DiskStamp(modified: t.addingTimeInterval(-60), size: 10)))
    }

    @Test func sizeCountsOnlyWhenBothKnowIt() {
        #expect(DiskStamp.changed(known: DiskStamp(modified: t, size: 10), current: DiskStamp(modified: t, size: 11)))
        #expect(!DiskStamp.changed(known: DiskStamp(modified: t), current: DiskStamp(modified: t, size: 11)))
    }

    @Test func unknownOrGoneIsNoChange() {
        #expect(!DiskStamp.changed(known: nil, current: DiskStamp(modified: t)))
        #expect(!DiskStamp.changed(known: DiskStamp(modified: t), current: nil))
        #expect(!DiskStamp.changed(known: DiskStamp(modified: nil), current: DiskStamp(modified: t)))
    }

    @Test func readsAFile() throws {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("diskstamp-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: u) }
        try "four".write(to: u, atomically: true, encoding: .utf8)
        let a = try #require(DiskStamp.of(u))
        #expect(a.size == 4 && a.modified != nil)
        try "longer text".write(to: u, atomically: true, encoding: .utf8)
        #expect(DiskStamp.changed(known: a, current: DiskStamp.of(u)))
        #expect(DiskStamp.of(u.appendingPathExtension("gone")) == nil)
    }

    @Test func goneFileIsMissing() {
        let known = DiskStamp(modified: t, size: 10)
        #expect(DiskStamp.status(known: known, current: nil, exists: false) == .missing)
        // Never read from disk (no date): saving just creates it.
        #expect(DiskStamp.status(known: DiskStamp(modified: nil), current: nil, exists: false) == .same)
        #expect(DiskStamp.status(known: nil, current: nil, exists: false) == .same)
        // There but unreadable (no access): not deleted.
        #expect(DiskStamp.status(known: known, current: nil, exists: true) == .same)
        #expect(DiskStamp.status(known: known, current: known, exists: true) == .same)
        #expect(DiskStamp.status(known: known, current: DiskStamp(modified: t.addingTimeInterval(5), size: 10), exists: true) == .changed)
    }

    @Test func deletedOrMovedFileOnDisk() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("diskstamp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let u = dir.appendingPathComponent("open.md")
        try "text".write(to: u, atomically: true, encoding: .utf8)
        let known = try #require(DiskStamp.of(u))
        #expect(DiskStamp.status(known: known, at: u) == .same)
        let moved = dir.appendingPathComponent("moved.md")
        try FileManager.default.moveItem(at: u, to: moved)
        #expect(DiskStamp.status(known: known, at: u) == .missing)
        // Moved back untouched: the same file again.
        try FileManager.default.moveItem(at: moved, to: u)
        #expect(DiskStamp.status(known: known, at: u) == .same)
        try FileManager.default.removeItem(at: u)
        #expect(DiskStamp.status(known: known, at: u) == .missing)
    }
}
