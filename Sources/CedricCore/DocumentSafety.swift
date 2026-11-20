import Foundation

/// Copies of a document's bytes that the iOS app keeps before anything
/// could replace them: the versions of an iCloud conflict, the text that
/// was unsaved when another app changed the file, and (once per session)
/// the file as it was before Owlink first wrote it. Private to the app
/// (0700 folder, 0600 files, kept out of backups and iCloud), each copy a
/// pair of files: the bytes, then a small record saying what they are.
public struct SafetyCopy: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        /// One version of an iCloud conflict (this device's or another's).
        case conflictVersion
        /// Unsaved text, kept before a reload from disk replaced it.
        case unsavedText
        /// The file on disk when another app changed it (theirs).
        case externalVersion
        /// The file before Owlink first wrote it this session.
        case original
    }

    public var id: String
    public var documentPath: String
    public var displayName: String
    public var kind: Kind
    /// When the copy was made.
    public var savedAt: Date
    /// When the bytes were last changed where they came from (a version's
    /// modification date), if known.
    public var sourceDate: Date?
    /// The device that saved them (a conflict version), if known.
    public var device: String?
    /// The encoding the bytes are in, when Owlink encoded them itself.
    public var encoding: TextEncoding?
    public var byteCount: Int

    public init(id: String = UUID().uuidString, documentPath: String, displayName: String, kind: Kind, savedAt: Date = Date(),
                sourceDate: Date? = nil, device: String? = nil, encoding: TextEncoding? = nil, byteCount: Int = 0) {
        self.id = id
        self.documentPath = documentPath
        self.displayName = displayName
        self.kind = kind
        self.savedAt = savedAt
        self.sourceDate = sourceDate
        self.device = device
        self.encoding = encoding
        self.byteCount = byteCount
    }
}

public struct SafetyCopyStore: Sendable {
    /// How long copies are kept.
    public static let keepDays = 7
    /// Larger files are not copied (as `RevertStore`).
    public static let maxBytes = RevertStore.maxBytes

    public let directory: URL
    public let maxBytes: Int

    public init(directory: URL, maxBytes: Int = SafetyCopyStore.maxBytes) {
        self.directory = directory
        self.maxBytes = maxBytes
    }

    public enum KeepError: Error, Equatable {
        case tooLarge(bytes: Int)
    }

    func dataURL(id: String) -> URL { directory.appendingPathComponent(id + ".bytes") }
    func recordURL(id: String) -> URL { directory.appendingPathComponent(id + ".copy") }

    /// Writes the bytes, then the record (a record never points at missing
    /// bytes). Throws if either write fails or the bytes are over the cap:
    /// callers that must not go on without a copy check for that.
    @discardableResult
    public func keep(_ data: Data, as copy: SafetyCopy) throws -> SafetyCopy {
        guard data.count <= maxBytes else { throw KeepError.tooLarge(bytes: data.count) }
        try PrivateDirectory.make(directory, root: directory)
        PrivateDirectory.excludeFromBackup(directory)
        var c = copy
        c.byteCount = data.count
        try PrivateDirectory.writePrivateFile(data, to: dataURL(id: c.id))
        try PrivateDirectory.writePrivateFile(try PropertyListEncoder().encode(c), to: recordURL(id: c.id))
        return c
    }

    public func data(for copy: SafetyCopy) -> Data? { try? Data(contentsOf: dataURL(id: copy.id)) }

    /// Every readable copy (with its bytes present), newest first.
    public func all() -> [SafetyCopy] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "copy" }
            .compactMap { (try? Data(contentsOf: $0)).flatMap { try? PropertyListDecoder().decode(SafetyCopy.self, from: $0) } }
            .filter { FileManager.default.fileExists(atPath: dataURL(id: $0.id).path) }
            .sorted { $0.savedAt > $1.savedAt }
    }

    public func copies(forDocumentPath path: String) -> [SafetyCopy] { all().filter { $0.documentPath == path } }

    public func remove(_ copy: SafetyCopy) {
        try? FileManager.default.removeItem(at: recordURL(id: copy.id))
        try? FileManager.default.removeItem(at: dataURL(id: copy.id))
    }

    /// Removes copies older than `days`, and bytes or records left without
    /// their other half (a crash between the two writes).
    public func prune(now: Date = Date(), days: Int = SafetyCopyStore.keepDays) {
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        for c in all() where c.savedAt < cutoff { remove(c) }
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let ids = Set(files.map { $0.deletingPathExtension().lastPathComponent })
        for id in ids {
            let hasData = FileManager.default.fileExists(atPath: dataURL(id: id).path)
            let hasRecord = FileManager.default.fileExists(atPath: recordURL(id: id).path)
            if hasData != hasRecord {
                try? FileManager.default.removeItem(at: dataURL(id: id))
                try? FileManager.default.removeItem(at: recordURL(id: id))
            }
        }
    }
}

/// An iCloud conflict: what each choice does, in Apple's documented order
/// ("Resolving Document Version Conflicts", Document-Based App
/// Programming Guide for iOS): replace the file with the chosen version,
/// remove the other versions, then mark the conflict versions resolved.
/// Every version's bytes are copied to the `SafetyCopyStore` before any of
/// these steps; if a copy fails, nothing is resolved.
public enum ConflictResolution {
    public enum Choice: Equatable, Sendable {
        /// The version open here (the file's current version) stays.
        case keepThis
        /// The other device's version (the newest of them) replaces it.
        case keepOther
        /// This one stays, and each other version is saved beside it as a copy.
        case keepBoth
    }

    public enum Step: Equatable, Sendable {
        /// Copy every version's bytes to the app's private store.
        case copyAllVersions
        /// Write the other version(s) beside the file as new files.
        case saveOthersAsCopies
        /// `NSFileVersion.replaceItem(at:)` with the other version.
        case replaceWithOther
        /// `NSFileVersion.removeOtherVersionsOfItem(at:)`.
        case removeOtherVersions
        /// `isResolved = true` on each unresolved conflict version.
        case markResolved
        /// Reload the document from disk.
        case reload
    }

    public static func steps(for choice: Choice) -> [Step] {
        switch choice {
        case .keepThis: return [.copyAllVersions, .removeOtherVersions, .markResolved]
        case .keepOther: return [.copyAllVersions, .replaceWithOther, .removeOtherVersions, .markResolved, .reload]
        case .keepBoth: return [.copyAllVersions, .saveOthersAsCopies, .removeOtherVersions, .markResolved]
        }
    }

    /// The file name for the other version kept beside the original:
    /// "notes (conflict 2026-11-20 10.23).md". `taken` says whether a name
    /// is already used; a number is added until one is free.
    public static func copyName(for name: String, date: Date, timeZone: TimeZone = .current,
                                taken: (String) -> Bool = { _ in false }) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd HH.mm"
        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        func make(_ n: Int) -> String {
            let stem = "\(base) (conflict \(f.string(from: date))\(n > 1 ? " \(n)" : ""))"
            return ext.isEmpty ? stem : stem + "." + ext
        }
        var n = 1
        while taken(make(n)) && n < 1000 { n += 1 }
        return make(n)
    }
}

/// Why the editor is read-only right now. Editing is allowed only with no
/// reason left.
public struct EditGate: Equatable, Sendable {
    public enum Reason: Hashable, Sendable {
        /// An iCloud conflict is waiting for a choice.
        case conflict
    }

    public private(set) var reasons: Set<Reason> = []

    public init() {}

    public var isEditable: Bool { reasons.isEmpty }

    public mutating func set(_ reason: Reason, _ on: Bool) {
        if on { reasons.insert(reason) } else { reasons.remove(reason) }
    }
}
