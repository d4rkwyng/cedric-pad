import CryptoKit
import Foundation

/// Replace in Files: a preview (`ReplacePlan`, computed from the files the
/// search found, off the main thread), then the writes, then an undo.
///
/// Data safety, in order:
/// - a file is planned only if its bytes decode and re-encode to exactly
///   the same bytes (encoding, BOM, line endings), so the write changes
///   nothing but the replaced spans; mixed line endings are skipped;
/// - a file changed since the search (date, size) is skipped at preview,
///   and one changed since the preview (date, size, SHA-256) at the write;
/// - every target's original bytes are copied to the undo store before
///   the first write;
/// - writes are atomic (a temp file in the same folder, renamed over the
///   file) and keep the file's mode, ACL and extended attributes; symbolic
///   links, hard-linked files and files outside the searched folder are
///   refused;
/// - files open in a tab are not written at all: the app edits their
///   buffer (one ⌘Z there), from the tab's own text.
public struct ReplaceQuery: Sendable, Equatable, Codable {
    public var query: String
    public var template: String
    public var regex: Bool
    public var caseSensitive: Bool

    public init(query: String, template: String, regex: Bool = false, caseSensitive: Bool = false) {
        self.query = query
        self.template = template
        self.regex = regex
        self.caseSensitive = caseSensitive
    }

    public var findOptions: FindOptions { FindOptions(regex: regex, caseSensitive: caseSensitive) }
}

/// One replacement in a file's (LF-normalised) text.
public struct ReplaceEdit: Sendable, Equatable {
    public var range: NSRange
    public var replacement: String
    /// 1-based.
    public var line: Int
    /// The line before the edit, cut to 400 characters around the match.
    public var lineText: String
    /// The match within `lineText`.
    public var lineRange: NSRange
}

/// Why a file is left out of a replace.
public enum ReplaceSkip: String, Sendable, Codable, CaseIterable {
    case binary, tooLarge, mixedLineEndings, notRoundTrip, cannotEncode
    case changedSinceSearch, changedSincePreview, changedSinceReplace
    case unreadable, unwritable, outsideFolder, symbolicLink, hardLinked, readOnlyTab

    public var summary: String {
        switch self {
        case .binary: return String(localized: "binary")
        case .tooLarge: return String(localized: "over 20 MB")
        case .mixedLineEndings: return String(localized: "mixed line endings (open it to replace there)")
        case .notRoundTrip: return String(localized: "encoding wouldn’t round-trip")
        case .cannotEncode: return String(localized: "replacement not encodable")
        case .changedSinceSearch: return String(localized: "changed since search")
        case .changedSincePreview: return String(localized: "changed since preview")
        case .changedSinceReplace: return String(localized: "changed since the replace")
        case .unreadable: return String(localized: "unreadable")
        case .unwritable: return String(localized: "couldn’t write")
        case .outsideFolder: return String(localized: "outside the folder")
        case .symbolicLink: return String(localized: "symbolic link")
        case .hardLinked: return String(localized: "hard-linked")
        case .readOnlyTab: return String(localized: "read-only tab")
        }
    }
}

public struct SkippedFile: Sendable, Equatable {
    public var url: URL
    public var relativePath: String
    public var reason: ReplaceSkip

    public init(url: URL, relativePath: String, reason: ReplaceSkip) {
        self.url = url
        self.relativePath = relativePath
        self.reason = reason
    }
}

/// What a planned file looked like on disk at preview time.
public struct DiskSource: Sendable, Equatable {
    public var stamp: DiskStamp
    public var sha256: Data
    public var encoding: TextEncoding
    public var lineEnding: LineEnding
}

public struct ReplaceFile: Sendable {
    public var url: URL
    public var relativePath: String
    /// The text the edits apply to: the decoded file, or the open tab's.
    public var sourceText: String
    public var edits: [ReplaceEdit]
    /// Nil when planned against an open tab's text.
    public var disk: DiskSource?
}

public struct ReplacePlan: Sendable {
    public var query: ReplaceQuery
    public var root: URL
    public var files: [ReplaceFile]
    public var skipped: [SkippedFile]
    public var cancelled = false

    public var replacementCount: Int { files.reduce(0) { $0 + $1.edits.count } }

    public func skippedCount(_ r: ReplaceSkip) -> Int { skipped.filter { $0.reason == r }.count }
}

public struct ReplaceReport: Sendable {
    public var written: [URL] = []
    public var replacements = 0
    public var skipped: [SkippedFile] = []
    /// The undo store operation, if anything was written.
    public var operation: UUID?

    public init() {}
}

/// How far `FileReplace.apply` has got: each file checked again, the
/// originals backed up, each file written. `total` is the number of files
/// in that stage.
public struct ReplaceProgress: Sendable, Equatable {
    public enum Stage: Sendable, Equatable { case checking, backingUp, writing }
    public var stage: Stage
    public var done: Int
    public var total: Int

    public init(stage: Stage, done: Int, total: Int) {
        self.stage = stage
        self.done = done
        self.total = total
    }
}

public enum FileReplace {
    // MARK: Pure

    /// Every non-empty match of `regex` in `text` and its replacement, as
    /// the find bar's Replace All makes them (`FindEngine.replacement`).
    public static func edits(in text: String, regex: NSRegularExpression, query: ReplaceQuery) -> [ReplaceEdit] {
        let ns = text as NSString
        let found = FindEngine.matches(regex, in: ns)
        guard !found.isEmpty else { return [] }
        let index = LineIndex(ns)
        return found.map { m in
            let rep = FindEngine.replacement(for: m, in: ns, template: query.template, regex: regex, options: query.findOptions)
            let line = index.line(containing: m.range.location)
            let content = index.contentRange(ofLine: line)
            var lineText = ns.substring(with: content)
            var loc = m.range.location - content.location
            let len = min(m.range.length, max(0, content.length - loc))
            let lineLen = (lineText as NSString).length
            if lineLen > 400 {
                let shift = max(0, min(loc - 100, lineLen - 400))
                lineText = (lineText as NSString).substring(with: NSRange(location: shift, length: 400))
                loc -= shift
            }
            let lr = NSRange(location: loc, length: min(len, max(0, (lineText as NSString).length - loc)))
            return ReplaceEdit(range: m.range, replacement: rep, line: line + 1, lineText: lineText, lineRange: lr)
        }
    }

    /// `text` with `edits` (sorted, non-overlapping) applied.
    public static func applying(_ edits: [ReplaceEdit], to text: String) -> String {
        let out = NSMutableString(string: text)
        for e in edits.sorted(by: { $0.range.location > $1.range.location }) {
            out.replaceCharacters(in: e.range, with: e.replacement)
        }
        return out as String
    }

    /// The span covering every edit and its new text, for one undoable
    /// buffer change.
    public static func span(_ edits: [ReplaceEdit], in text: String) -> (NSRange, String)? {
        let sorted = edits.sorted { $0.range.location < $1.range.location }
        guard let first = sorted.first, let last = sorted.last else { return nil }
        let span = NSRange(location: first.range.location, length: NSMaxRange(last.range) - first.range.location)
        let ns = text as NSString
        guard NSMaxRange(span) <= ns.length else { return nil }
        let shifted = sorted.map { e -> ReplaceEdit in
            var e = e
            e.range.location -= span.location
            return e
        }
        return (span, applying(shifted, to: ns.substring(with: span)))
    }

    public static func sha256(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }

    /// Same date (within DiskStamp's tolerance) and same size.
    static func same(_ a: DiskStamp, _ b: DiskStamp) -> Bool {
        !DiskStamp.changed(known: a, current: b) && a.size == b.size && (a.modified == nil) == (b.modified == nil)
    }

    // MARK: Plan

    /// One file the search found.
    public struct Candidate: Sendable {
        public var url: URL
        public var relativePath: String
        /// The file's stamp when it was searched (nil: don't compare).
        public var searchStamp: DiskStamp?

        public init(url: URL, relativePath: String, searchStamp: DiskStamp?) {
            self.url = url
            self.relativePath = relativePath
            self.searchStamp = searchStamp
        }
    }

    /// Plans the replace. `buffers`: the text of files open in a tab, by
    /// standardized path; those are planned against that text, not disk.
    /// Reads files; call it off the main thread.
    public static func plan(_ query: ReplaceQuery, root: URL, candidates: [Candidate], buffers: [String: String] = [:],
                            maxFileSize: Int = 20 * 1024 * 1024, isCancelled: () -> Bool = { false }) throws -> ReplacePlan {
        let re = try FindEngine.regex(query.query, query.findOptions)
        var plan = ReplacePlan(query: query, root: root, files: [], skipped: [])
        for c in candidates {
            if isCancelled() { plan.cancelled = true; break }
            func skip(_ r: ReplaceSkip) { plan.skipped.append(SkippedFile(url: c.url, relativePath: c.relativePath, reason: r)) }
            let key = c.url.standardizedFileURL.path
            if let text = buffers[key] {
                let edits = edits(in: text, regex: re, query: query)
                if !edits.isEmpty { plan.files.append(ReplaceFile(url: c.url, relativePath: c.relativePath, sourceText: text, edits: edits, disk: nil)) }
                continue
            }
            if let refusal = refusal(c.url, root: root) { skip(refusal); continue }
            guard let stamp = DiskStamp.of(c.url) else { skip(.unreadable); continue }
            if let s = c.searchStamp, !same(s, stamp) {
                skip(.changedSinceSearch); continue
            }
            if (stamp.size ?? 0) > maxFileSize { skip(.tooLarge); continue }
            guard let data = try? Data(contentsOf: c.url) else { skip(.unreadable); continue }
            if FileSearch.looksBinary(data) { skip(.binary); continue }
            guard let decoded = TextCodec.decode(data) else { skip(.binary); continue }
            if decoded.mixedLineEndings { skip(.mixedLineEndings); continue }
            guard TextCodec.encode(decoded.text, encoding: decoded.encoding, lineEnding: decoded.lineEnding) == data else {
                skip(.notRoundTrip); continue
            }
            let edits = edits(in: decoded.text, regex: re, query: query)
            guard !edits.isEmpty else { continue }
            if !TextCodec.canEncode(edits.map(\.replacement).joined(), as: decoded.encoding) { skip(.cannotEncode); continue }
            plan.files.append(ReplaceFile(url: c.url, relativePath: c.relativePath, sourceText: decoded.text, edits: edits,
                                          disk: DiskSource(stamp: stamp, sha256: sha256(data), encoding: decoded.encoding,
                                                           lineEnding: decoded.lineEnding)))
        }
        return plan
    }

    /// Why `url` may not be written: a symbolic link, hard-linked, not a
    /// regular file, or (links resolved) outside `root`.
    static func refusal(_ url: URL, root: URL) -> ReplaceSkip? {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return .unreadable }
        if st.st_mode & S_IFMT == S_IFLNK { return .symbolicLink }
        guard st.st_mode & S_IFMT == S_IFREG else { return .unreadable }
        if st.st_nlink > 1 { return .hardLinked }
        guard SafePaths.isInside(url, root) else { return .outsideFolder }
        return nil
    }

    // MARK: Apply (disk)

    /// Writes the planned disk files (`files` with `disk` set and only the
    /// edits to make). Each is checked again (date, size, SHA-256) first;
    /// every original goes to `store` before the first write. Files open
    /// in a tab (`disk == nil`) are ignored here: the app edits those.
    /// Reads, hashes and writes files: the app calls it off the main
    /// thread, one at a time, and shows `progress` (called on the calling
    /// thread after each file of each stage).
    public static func apply(_ files: [ReplaceFile], query: ReplaceQuery, root: URL, store: ReplaceUndoStore,
                             progress: (ReplaceProgress) -> Void = { _ in }) -> ReplaceReport {
        var report = ReplaceReport()
        struct Prepared { var file: ReplaceFile; var original: Data; var new: Data; var mode: mode_t; var count: Int }
        var ready: [Prepared] = []
        let targets = files.filter { $0.disk != nil && !$0.edits.isEmpty }
        for (n, f) in targets.enumerated() {
            defer { progress(ReplaceProgress(stage: .checking, done: n + 1, total: targets.count)) }
            guard let disk = f.disk, !f.edits.isEmpty else { continue }
            func skip(_ r: ReplaceSkip) { report.skipped.append(SkippedFile(url: f.url, relativePath: f.relativePath, reason: r)) }
            if let refusal = refusal(f.url, root: root) { skip(refusal); continue }
            guard let now = DiskStamp.of(f.url), let data = try? Data(contentsOf: f.url) else { skip(.unreadable); continue }
            guard same(disk.stamp, now), sha256(data) == disk.sha256 else { skip(.changedSincePreview); continue }
            guard let new = TextCodec.encode(applying(f.edits, to: f.sourceText), encoding: disk.encoding, lineEnding: disk.lineEnding) else {
                skip(.cannotEncode); continue
            }
            var st = stat()
            guard stat(f.url.path, &st) == 0 else { skip(.unreadable); continue }
            ready.append(Prepared(file: f, original: data, new: new, mode: st.st_mode & 0o7777, count: f.edits.count))
        }
        guard !ready.isEmpty else { return report }

        // The originals, all of them, before the first write.
        let op: ReplaceUndoStore.Operation
        do {
            op = try store.begin(query: query)
            for (k, p) in ready.enumerated() {
                try op.backup(p.original, index: k, for: p.file.url, written: p.new, mode: p.mode)
                progress(ReplaceProgress(stage: .backingUp, done: k + 1, total: ready.count))
            }
            try op.save()
        } catch {
            for p in ready { report.skipped.append(SkippedFile(url: p.file.url, relativePath: p.file.relativePath, reason: .unwritable)) }
            return report
        }

        for (k, p) in ready.enumerated() {
            defer { progress(ReplaceProgress(stage: .writing, done: k + 1, total: ready.count)) }
            // Last look just before the rename.
            guard let now = DiskStamp.of(p.file.url), let disk = p.file.disk, same(disk.stamp, now) else {
                op.drop(index: k)
                report.skipped.append(SkippedFile(url: p.file.url, relativePath: p.file.relativePath, reason: .changedSincePreview))
                continue
            }
            do {
                try atomicWrite(p.new, to: p.file.url, mode: p.mode)
                op.noteWritten(index: k, stamp: DiskStamp.of(p.file.url))
                report.written.append(p.file.url)
                report.replacements += p.count
            } catch {
                op.drop(index: k)
                report.skipped.append(SkippedFile(url: p.file.url, relativePath: p.file.relativePath, reason: .unwritable))
            }
        }
        try? op.save()
        report.operation = report.written.isEmpty ? nil : op.id
        return report
    }

    /// Replaces `url`'s contents atomically: a temp file in the same folder
    /// (so the rename can't cross volumes) gets the bytes, then the file's
    /// mode, ACL and extended attributes (copyfile), then is renamed over it.
    public static func atomicWrite(_ data: Data, to url: URL, mode: mode_t) throws {
        let dir = url.deletingLastPathComponent().path
        var template = Array((dir + "/." + url.lastPathComponent + ".owlink-XXXXXX").utf8CString)
        let fd = mkstemp(&template)
        guard fd >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        let tmp = String(cString: template)
        var ok = data.withUnsafeBytes { buf -> Bool in
            var off = 0
            while off < buf.count {
                let n = Darwin.write(fd, buf.baseAddress! + off, buf.count - off)
                if n < 0 { if errno == EINTR { continue }; return false }
                off += n
            }
            return true
        }
        if ok { ok = fsync(fd) == 0 }
        close(fd)
        if ok {
            // Mode, owner (if allowed), ACL and xattrs from the file being replaced; then the mode exactly.
            _ = copyfile(url.path, tmp, nil, copyfile_flags_t(COPYFILE_SECURITY | COPYFILE_XATTR))
            ok = chmod(tmp, mode) == 0
        }
        guard ok, rename(tmp, url.path) == 0 else {
            unlink(tmp)
            throw CocoaError(.fileWriteUnknown)
        }
    }
}

// MARK: - Undo store

/// The originals of each Replace in Files operation, so Undo Replace in
/// Files can put them back: `<root>/<uuid>/` (owner-only, 0700) holds
/// `manifest.json` and one backup file per written file. Kept for the
/// last 5 operations or 7 days.
public final class ReplaceUndoStore: @unchecked Sendable {
    public let root: URL

    /// ~/Library/Application Support/Cedric/ReplaceUndo
    public static var defaultRoot: URL { PrivateDirectory.supportRoot.appendingPathComponent("ReplaceUndo", isDirectory: true) }

    public init(root: URL = ReplaceUndoStore.defaultRoot) { self.root = root }

    public struct Entry: Codable, Sendable, Equatable {
        public var path: String
        public var backup: String
        public var originalSHA256: String
        public var writtenSHA256: String
        public var mode: UInt16
        public var originalSize: Int
        public var writtenModified: Date?
        public var written: Bool
        public var restored = false
    }

    public struct Manifest: Codable, Sendable {
        public var id: UUID
        public var date: Date
        public var query: ReplaceQuery
        public var entries: [Entry]
        public var undone = false
    }

    public final class Operation: @unchecked Sendable {
        public let id: UUID
        let dir: URL
        var manifest: Manifest

        init(dir: URL, manifest: Manifest) {
            self.dir = dir
            self.manifest = manifest
            id = manifest.id
        }

        func backup(_ original: Data, index: Int, for url: URL, written: Data, mode: mode_t) throws {
            let name = "\(index).orig"
            try PrivateDirectory.writePrivateFile(original, to: dir.appendingPathComponent(name))
            manifest.entries.append(Entry(path: url.standardizedFileURL.path, backup: name,
                                          originalSHA256: FileReplace.sha256(original).sha256Hex,
                                          writtenSHA256: FileReplace.sha256(written).sha256Hex, mode: UInt16(mode),
                                          originalSize: original.count, writtenModified: nil, written: false))
        }

        func noteWritten(index: Int, stamp: DiskStamp?) {
            manifest.entries[index].written = true
            manifest.entries[index].writtenModified = stamp?.modified
        }

        func drop(index: Int) {
            manifest.entries[index].written = false
        }

        func save() throws {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            enc.dateEncodingStrategy = .iso8601
            try PrivateDirectory.writePrivateFile(try enc.encode(manifest), to: dir.appendingPathComponent("manifest.json"))
        }
    }

    func begin(query: ReplaceQuery, now: Date = Date()) throws -> Operation {
        prune(now: now)
        let id = UUID()
        let dir = root.appendingPathComponent(id.uuidString, isDirectory: true)
        try PrivateDirectory.make(dir, root: root)
        let op = Operation(dir: dir, manifest: Manifest(id: id, date: now, query: query, entries: []))
        try op.save()
        return op
    }

    public func manifest(_ id: UUID) -> Manifest? {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        guard let d = try? Data(contentsOf: root.appendingPathComponent(id.uuidString).appendingPathComponent("manifest.json")) else { return nil }
        return try? dec.decode(Manifest.self, from: d)
    }

    public struct UndoReport: Sendable {
        public var restored: [URL] = []
        public var skipped: [SkippedFile] = []
    }

    /// Puts back every written file whose bytes are still exactly what the
    /// replace wrote; the rest are skipped and reported.
    public func undo(_ id: UUID) -> UndoReport {
        var report = UndoReport()
        guard var m = manifest(id), !m.undone else { return report }
        let dir = root.appendingPathComponent(id.uuidString)
        for (k, e) in m.entries.enumerated() where e.written && !e.restored {
            let url = URL(fileURLWithPath: e.path)
            func skip(_ r: ReplaceSkip) { report.skipped.append(SkippedFile(url: url, relativePath: url.lastPathComponent, reason: r)) }
            var st = stat()
            guard lstat(e.path, &st) == 0, st.st_mode & S_IFMT == S_IFREG else { skip(.changedSinceReplace); continue }
            guard let current = try? Data(contentsOf: url), FileReplace.sha256(current).sha256Hex == e.writtenSHA256 else {
                skip(.changedSinceReplace); continue
            }
            guard let original = try? Data(contentsOf: dir.appendingPathComponent(e.backup)),
                  FileReplace.sha256(original).sha256Hex == e.originalSHA256 else { skip(.unreadable); continue }
            do {
                try FileReplace.atomicWrite(original, to: url, mode: st.st_mode & 0o7777)
                m.entries[k].restored = true
                report.restored.append(url)
            } catch {
                skip(.unwritable)
            }
        }
        m.undone = true
        let op = Operation(dir: dir, manifest: m)
        try? op.save()
        return report
    }

    /// Keeps the newest `keep` operations younger than `maxAge`.
    public func prune(keep: Int = 5, maxAge: TimeInterval = 7 * 24 * 3600, now: Date = Date()) {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        var ops: [(URL, Date)] = []
        for d in dirs {
            guard let id = UUID(uuidString: d.lastPathComponent) else { continue }
            let date = manifest(id)?.date ?? ((try? fm.attributesOfItem(atPath: d.path)[.modificationDate]) as? Date) ?? .distantPast
            ops.append((d, date))
        }
        ops.sort { $0.1 > $1.1 }
        for (k, (d, date)) in ops.enumerated() where k >= keep || now.timeIntervalSince(date) > maxAge {
            try? fm.removeItem(at: d)
        }
    }
}

extension Data {
    var sha256Hex: String { map { String(format: "%02x", $0) }.joined() }
}
