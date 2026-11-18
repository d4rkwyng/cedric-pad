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
}
