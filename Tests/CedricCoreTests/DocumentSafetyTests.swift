import Foundation
import Testing
@testable import CedricCore

/// The iOS app's document safety: copies kept before anything could
/// replace a file's bytes, iCloud conflict choices, and the editor's
/// read-only gate.
@Suite struct DocumentSafetyTests {
    let fm = FileManager.default

    func temp() throws -> URL {
        let u = URL(fileURLWithPath: NSTemporaryDirectory() + "owlink-doc-safety-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    // MARK: Safety copies

    @Test func safetyCopyKeepsBytesAndRecordPrivately() throws {
        let t = try temp(); defer { try? fm.removeItem(at: t) }
        let store = SafetyCopyStore(directory: t.appendingPathComponent("Copies"))
        let bytes = Data([0xFF, 0xFE, 0x61, 0x00])
        let c = try store.keep(bytes, as: SafetyCopy(documentPath: "/d/a.txt", displayName: "a.txt", kind: .conflictVersion,
                                                     device: "iPad"))
        #expect(c.byteCount == 4)
        #expect(store.data(for: c) == bytes)
        #expect(store.copies(forDocumentPath: "/d/a.txt") == [c])
        #expect(store.copies(forDocumentPath: "/d/b.txt").isEmpty)
        let mode = (try fm.attributesOfItem(atPath: store.dataURL(id: c.id).path)[.posixPermissions] as? NSNumber)?.intValue
        #expect(mode == 0o600)
        #expect(try store.directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
    }

    @Test func safetyCopyRefusesOverCapSoCallersStop() throws {
        let t = try temp(); defer { try? fm.removeItem(at: t) }
        let store = SafetyCopyStore(directory: t, maxBytes: 3)
        #expect(throws: SafetyCopyStore.KeepError.tooLarge(bytes: 4)) {
            try store.keep(Data([1, 2, 3, 4]), as: SafetyCopy(documentPath: "/a", displayName: "a", kind: .original))
        }
        #expect(store.all().isEmpty)
    }

    @Test func safetyCopiesNewestFirstAndPrunedAfterSevenDays() throws {
        let t = try temp(); defer { try? fm.removeItem(at: t) }
        let store = SafetyCopyStore(directory: t)
        let now = Date()
        let old = try store.keep(Data("old".utf8), as: SafetyCopy(documentPath: "/a", displayName: "a", kind: .original,
                                                                  savedAt: now.addingTimeInterval(-8 * 86_400)))
        let mid = try store.keep(Data("mid".utf8), as: SafetyCopy(documentPath: "/a", displayName: "a", kind: .original,
                                                                  savedAt: now.addingTimeInterval(-6 * 86_400)))
        let new = try store.keep(Data("new".utf8), as: SafetyCopy(documentPath: "/a", displayName: "a", kind: .unsavedText,
                                                                  savedAt: now))
        #expect(store.all().map(\.id) == [new.id, mid.id, old.id])
        store.prune(now: now)
        #expect(store.all().map(\.id) == [new.id, mid.id])
        #expect(!fm.fileExists(atPath: store.dataURL(id: old.id).path))
    }

    @Test func pruneRemovesHalfWrittenCopies() throws {
        let t = try temp(); defer { try? fm.removeItem(at: t) }
        let store = SafetyCopyStore(directory: t)
        let c = try store.keep(Data("x".utf8), as: SafetyCopy(documentPath: "/a", displayName: "a", kind: .original))
        try fm.removeItem(at: store.recordURL(id: c.id))
        try Data("orphan record".utf8).write(to: store.recordURL(id: "orphan"))
        #expect(store.all().isEmpty)
        store.prune()
        #expect(!fm.fileExists(atPath: store.dataURL(id: c.id).path))
        #expect(!fm.fileExists(atPath: store.recordURL(id: "orphan").path))
    }

    // MARK: Conflicts

    @Test func conflictStepsCopyFirstAndFollowApplesOrder() {
        for choice in [ConflictResolution.Choice.keepThis, .keepOther, .keepBoth] {
            let s = ConflictResolution.steps(for: choice)
            #expect(s.first == .copyAllVersions)
            // Replace (when any), then remove, then resolved.
            let remove = s.firstIndex(of: .removeOtherVersions)!, resolved = s.firstIndex(of: .markResolved)!
            #expect(remove < resolved)
            if let replace = s.firstIndex(of: .replaceWithOther) { #expect(replace < remove) }
            if let copies = s.firstIndex(of: .saveOthersAsCopies) { #expect(copies < remove) }
        }
        #expect(ConflictResolution.steps(for: .keepThis) == [.copyAllVersions, .removeOtherVersions, .markResolved])
        #expect(ConflictResolution.steps(for: .keepOther).contains(.replaceWithOther))
        #expect(ConflictResolution.steps(for: .keepOther).last == .reload)
        #expect(!ConflictResolution.steps(for: .keepBoth).contains(.replaceWithOther))
        #expect(ConflictResolution.steps(for: .keepBoth).contains(.saveOthersAsCopies))
    }

    @Test func conflictCopyNameKeepsExtensionAndAvoidsTakenNames() {
        let utc = TimeZone(identifier: "UTC")!
        let d = Date(timeIntervalSince1970: 1_795_000_000) // 2026-11-18 11:06 UTC
        #expect(ConflictResolution.copyName(for: "notes.md", date: d, timeZone: utc) == "notes (conflict 2026-11-18 11.06).md")
        #expect(ConflictResolution.copyName(for: "Makefile", date: d, timeZone: utc) == "Makefile (conflict 2026-11-18 11.06)")
        #expect(ConflictResolution.copyName(for: "a.tar.gz", date: d, timeZone: utc) == "a.tar (conflict 2026-11-18 11.06).gz")
        let taken: Set = ["notes (conflict 2026-11-18 11.06).md", "notes (conflict 2026-11-18 11.06 2).md"]
        #expect(ConflictResolution.copyName(for: "notes.md", date: d, timeZone: utc, taken: taken.contains)
                == "notes (conflict 2026-11-18 11.06 3).md")
    }

    // MARK: Edit gate

    @Test func editGateConflictLocksUntilResolved() {
        var g = EditGate()
        #expect(g.isEditable)
        g.set(.conflict, true)
        #expect(!g.isEditable)
        g.set(.conflict, false)
        #expect(g.isEditable)
    }

    // MARK: External change

    @Test func externalChangeAsksOnlyWithUnsavedEdits() {
        #expect(ExternalChange.onRevert(hasUnsavedChanges: false, chosen: false, asking: false) == .reload)
        #expect(ExternalChange.onRevert(hasUnsavedChanges: true, chosen: false, asking: false) == .askFirst)
        // A second change while the question is up: one question.
        #expect(ExternalChange.onRevert(hasUnsavedChanges: true, chosen: false, asking: true) == .ignore)
        // Use Theirs / Keep Other Version: the app's own reload goes ahead.
        #expect(ExternalChange.onRevert(hasUnsavedChanges: true, chosen: true, asking: true) == .reload)
        #expect(ExternalChange.onRevert(hasUnsavedChanges: true, chosen: true, asking: false) == .reload)
    }

    @Test func editGateLocksWhileAskingAboutExternalChange() {
        var g = EditGate()
        g.set(.externalChange, true)
        g.set(.conflict, true)
        g.set(.externalChange, false)
        #expect(!g.isEditable)
        g.set(.conflict, false)
        #expect(g.isEditable)
    }

    // MARK: Locked editing, failed saves

    @Test func editGateFollowsUIDocumentDisableEditing() {
        var g = EditGate()
        g.set(.documentLocked, true)
        #expect(!g.isEditable)
        g.set(.documentLocked, true)
        g.set(.documentLocked, false)
        #expect(g.isEditable)
    }

    @Test func autosaveStopsAfterUnencodableFailureUntilEdited() {
        #expect(SavePolicy.shouldAutosave(saveAutomatically: true, hasUnsavedChanges: true, blockedUntilEdited: false))
        #expect(!SavePolicy.shouldAutosave(saveAutomatically: true, hasUnsavedChanges: true, blockedUntilEdited: true))
    }

    // MARK: One window per document

    @Test func secondOpenOfSameFileGoesToTheFirstWindow() {
        var r = OpenDocumentRegistry()
        #expect(r.register(path: "/docs/a.txt", window: "w1") == .registered)
        #expect(r.register(path: "/docs/a.txt", window: "w1") == .alreadyHere)
        #expect(r.register(path: "/docs/./b/../a.txt", window: "w2") == .openElsewhere(window: "w1"))
        #expect(r.register(path: "/docs/b.txt", window: "w2") == .registered)
        // Another window can't close it for the one that has it.
        r.unregister(path: "/docs/a.txt", window: "w2")
        #expect(r.owner(ofPath: "/docs/a.txt") == "w1")
        r.unregister(path: "/docs/a.txt", window: "w1")
        #expect(!r.contains(path: "/docs/a.txt"))
        #expect(r.register(path: "/docs/a.txt", window: "w2") == .registered)
    }

    @Test func registryKeySeesThroughSymlinksAndWindowsGoing() throws {
        let t = try temp(); defer { try? fm.removeItem(at: t) }
        let real = t.appendingPathComponent("real.txt")
        try Data("x".utf8).write(to: real)
        let link = t.appendingPathComponent("link.txt")
        try fm.createSymbolicLink(at: link, withDestinationURL: real)
        #expect(OpenDocumentRegistry.key(forPath: link.path) == OpenDocumentRegistry.key(forPath: real.path))
        var r = OpenDocumentRegistry()
        _ = r.register(path: real.path, window: "w1")
        _ = r.register(path: "/other", window: "w1")
        _ = r.register(path: "/kept", window: "w2")
        #expect(r.register(path: link.path, window: "w2") == .openElsewhere(window: "w1"))
        r.removeAll(window: "w1")
        #expect(!r.contains(path: real.path) && !r.contains(path: "/other"))
        #expect(r.contains(path: "/kept"))
    }
}
