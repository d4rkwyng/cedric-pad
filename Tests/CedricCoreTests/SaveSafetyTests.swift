import Foundation
import Testing
@testable import CedricCore

/// The iOS app's data safety: the recovery store (crash-safe copies of
/// unsaved text), the revert store (the bytes as opened) and the
/// "Save automatically" decisions.
@Suite struct SaveSafetyTests {
    let fm = FileManager.default

    func temp() throws -> URL {
        let u = URL(fileURLWithPath: NSTemporaryDirectory() + "owlink-save-safety-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    func record(_ path: String = "/docs/a.txt", text: String = "hello", at date: Date = Date()) -> RecoveryRecord {
        RecoveryRecord(documentPath: path, displayName: (path as NSString).lastPathComponent, bookmark: Data([1, 2, 3]),
                       savedAt: date, text: text, encoding: .utf16LE, lineEnding: .crlf)
    }

    func mode(_ u: URL) -> Int? {
        (try? fm.attributesOfItem(atPath: u.path)[.posixPermissions] as? NSNumber)?.intValue
    }

    // MARK: Recovery store

    @Test func recoveryWriteAndReadBack() throws {
        let t = try temp(); defer { try? fm.removeItem(at: t) }
        let store = RecoveryStore(directory: t.appendingPathComponent("Recovery"))
        let r = record(text: "unsaved ✓\nsecond line")
        try store.write(r)
        #expect(store.read(documentPath: r.documentPath) == r)
        #expect(mode(store.directory) == 0o700)
        #expect(mode(store.fileURL(forDocumentPath: r.documentPath)) == 0o600)
        let excluded = try store.directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
        #expect(excluded == true)
    }

    @Test func recoveryWriteReplacesAtomicallyWithNoTempLeft() throws {
        let t = try temp(); defer { try? fm.removeItem(at: t) }
        let store = RecoveryStore(directory: t)
        try store.write(record(text: "one"))
        try store.write(record(text: "two"))
        #expect(store.read(documentPath: "/docs/a.txt")?.text == "two")
        #expect(try fm.contentsOfDirectory(atPath: t.path).count == 1)
    }

    @Test func recoveryIsPerDocument() throws {
        let t = try temp(); defer { try? fm.removeItem(at: t) }
        let store = RecoveryStore(directory: t)
        try store.write(record("/docs/a.txt", text: "A"))
        try store.write(record("/docs/b.txt", text: "B", at: Date().addingTimeInterval(5)))
        #expect(store.read(documentPath: "/docs/a.txt")?.text == "A")
        #expect(store.read(documentPath: "/docs/b.txt")?.text == "B")
        #expect(store.read(documentPath: "/docs/c.txt") == nil)
        #expect(store.all().map(\.text) == ["B", "A"])
    }

    @Test func newerThanTheDocument() {
        let now = Date()
        let r = record(at: now)
        #expect(r.isNewer(thanDocumentModified: now.addingTimeInterval(-10)))
        #expect(!r.isNewer(thanDocumentModified: now.addingTimeInterval(10)))
        #expect(!r.isNewer(thanDocumentModified: now))
        // The document is gone or has no date: still offered.
        #expect(r.isNewer(thanDocumentModified: nil))
    }

    @Test func pendingOnlyWhenNewer() throws {
        let t = try temp(); defer { try? fm.removeItem(at: t) }
        let store = RecoveryStore(directory: t)
        let now = Date()
        try store.write(record(at: now))
        #expect(store.pending(documentPath: "/docs/a.txt", documentModified: now.addingTimeInterval(-60)) != nil)
        #expect(store.pending(documentPath: "/docs/a.txt", documentModified: now.addingTimeInterval(60)) == nil)
    }

    @Test func recoveryClear() throws {
        let t = try temp(); defer { try? fm.removeItem(at: t) }
        let store = RecoveryStore(directory: t)
        try store.write(record("/docs/a.txt"))
        try store.write(record("/docs/b.txt"))
        store.clear(documentPath: "/docs/a.txt")
        #expect(store.read(documentPath: "/docs/a.txt") == nil)
        #expect(store.read(documentPath: "/docs/b.txt") != nil)
        // Clearing what isn't there is fine.
        store.clear(documentPath: "/docs/a.txt")
        #expect(store.all().count == 1)
    }

    @Test func recoveryIgnoresJunkAndMissingFolder() throws {
        let t = try temp(); defer { try? fm.removeItem(at: t) }
        #expect(RecoveryStore(directory: t.appendingPathComponent("none")).all().isEmpty)
        let store = RecoveryStore(directory: t)
        try Data("not a plist".utf8).write(to: store.fileURL(forDocumentPath: "/docs/a.txt"))
        #expect(store.read(documentPath: "/docs/a.txt") == nil)
        #expect(store.all().isEmpty)
    }

    @Test func throttleWritesAtMostEveryThreeSeconds() {
        #expect(RecoveryThrottle.interval == 3)
        #expect(RecoveryThrottle.delay(sinceLastWrite: nil) == 0)
        #expect(RecoveryThrottle.delay(sinceLastWrite: 0) == 3)
        #expect(RecoveryThrottle.delay(sinceLastWrite: 1) == 2)
        #expect(RecoveryThrottle.delay(sinceLastWrite: 3) == 0)
        #expect(RecoveryThrottle.delay(sinceLastWrite: 30) == 0)
        // A clock that went backwards doesn't hold writes back.
        #expect(RecoveryThrottle.delay(sinceLastWrite: -5) == 0)
    }

    // MARK: Revert store

    @Test func revertKeepLoadAndClear() throws {
        let t = try temp(); defer { try? fm.removeItem(at: t) }
        let store = RevertStore(directory: t.appendingPathComponent("Opened"))
        let bytes = Data([0xff, 0xfe, 0x68, 0x00, 0x0d, 0x00, 0x0a, 0x00])
        #expect(store.keep(bytes, id: "doc1") == .kept)
        #expect(store.load(id: "doc1") == bytes)
        #expect(mode(store.fileURL(id: "doc1")) == 0o600)
        let excluded = try store.directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
        #expect(excluded == true)
        store.clear(id: "doc1")
        #expect(store.load(id: "doc1") == nil)
    }

    @Test func revertCapIsTwentyMegabytes() throws {
        #expect(RevertStore.maxBytes == 20 * 1024 * 1024)
        let t = try temp(); defer { try? fm.removeItem(at: t) }
        let store = RevertStore(directory: t, maxBytes: 8)
        #expect(store.keep(Data(count: 8), id: "atCap") == .kept)
        #expect(store.keep(Data(count: 9), id: "over") == .tooLarge(bytes: 9))
        #expect(store.load(id: "over") == nil)
        #expect(!fm.fileExists(atPath: store.fileURL(id: "over").path))
    }

    @Test func revertClearAllAtLaunch() throws {
        let t = try temp(); defer { try? fm.removeItem(at: t) }
        let store = RevertStore(directory: t)
        store.keep(Data("a".utf8), id: "a")
        store.keep(Data("b".utf8), id: "b")
        try Data("other".utf8).write(to: t.appendingPathComponent("keep.me"))
        store.clearAll()
        #expect(store.load(id: "a") == nil)
        #expect(store.load(id: "b") == nil)
        #expect(fm.fileExists(atPath: t.appendingPathComponent("keep.me").path))
    }

    // MARK: Save automatically

    @Test func autosaveOnlyWhenOnAndEdited() {
        #expect(SavePolicy.shouldAutosave(saveAutomatically: true, hasUnsavedChanges: true))
        #expect(!SavePolicy.shouldAutosave(saveAutomatically: true, hasUnsavedChanges: false))
        #expect(!SavePolicy.shouldAutosave(saveAutomatically: false, hasUnsavedChanges: true))
        #expect(!SavePolicy.shouldAutosave(saveAutomatically: false, hasUnsavedChanges: false))
    }

    @Test func closeAsksOnlyWhenOffAndEdited() {
        #expect(SavePolicy.onClose(saveAutomatically: false, hasUnsavedChanges: true) == .ask)
        #expect(SavePolicy.onClose(saveAutomatically: false, hasUnsavedChanges: false) == .close)
        #expect(SavePolicy.onClose(saveAutomatically: true, hasUnsavedChanges: true) == .close)
        #expect(SavePolicy.onClose(saveAutomatically: true, hasUnsavedChanges: false) == .close)
    }

    @Test func saveButtonOnlyWithAutosaveOff() {
        #expect(SavePolicy.showsSaveButton(saveAutomatically: false))
        #expect(!SavePolicy.showsSaveButton(saveAutomatically: true))
    }
}
