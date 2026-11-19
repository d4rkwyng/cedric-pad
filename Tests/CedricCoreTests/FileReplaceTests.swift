import Foundation
import Testing
@testable import CedricCore

@Suite struct FileReplaceTests {
    func dir() throws -> URL {
        let d = tempDir()
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d.resolvingSymlinksInPath()
    }

    func put(_ root: URL, _ rel: String, _ data: Data) throws -> URL {
        let u = root.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: u)
        return u
    }

    func candidates(_ root: URL, _ urls: [URL]) -> [FileReplace.Candidate] {
        urls.map { .init(url: $0, relativePath: String($0.path.dropFirst(root.path.count + 1)), searchStamp: DiskStamp.of($0)) }
    }

    /// Plans and writes every edit; returns the report.
    func replaceAll(_ q: ReplaceQuery, root: URL, _ urls: [URL], store: ReplaceUndoStore) throws -> (ReplacePlan, ReplaceReport) {
        let plan = try FileReplace.plan(q, root: root, candidates: candidates(root, urls))
        return (plan, FileReplace.apply(plan.files, query: q, root: root, store: store))
    }

    @Test func encodingsRoundTripByteExact() throws {
        let root = try dir()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ReplaceUndoStore(root: root.appendingPathComponent(".undo"))
        let cases: [(String, Data, Data)] = [
            ("utf8.txt", Data("café owl\nowl\n".utf8), Data("café OWL\nOWL\n".utf8)),
            ("bom.txt", Data([0xEF, 0xBB, 0xBF]) + Data("owl ünï\n".utf8), Data([0xEF, 0xBB, 0xBF]) + Data("OWL ünï\n".utf8)),
            ("u16le.txt", Data([0xFF, 0xFE]) + "owl é\r\n".data(using: .utf16LittleEndian)!,
             Data([0xFF, 0xFE]) + "OWL é\r\n".data(using: .utf16LittleEndian)!),
            ("u16be.txt", Data([0xFE, 0xFF]) + "x owl\n".data(using: .utf16BigEndian)!,
             Data([0xFE, 0xFF]) + "x OWL\n".data(using: .utf16BigEndian)!),
            ("latin1.txt", "naïve owl\n".data(using: .isoLatin1)!, "naïve OWL\n".data(using: .isoLatin1)!),
            ("crlf.txt", Data("a owl\r\nb\r\nowl c\r\n".utf8), Data("a OWL\r\nb\r\nOWL c\r\n".utf8)),
            ("cr.txt", Data("owl\rx\r".utf8), Data("OWL\rx\r".utf8)),
        ]
        let urls = try cases.map { try put(root, $0.0, $0.1) }
        let (plan, report) = try replaceAll(ReplaceQuery(query: "owl", template: "OWL", caseSensitive: true), root: root, urls, store: store)
        #expect(plan.skipped.isEmpty, "\(plan.skipped)")
        #expect(report.written.count == cases.count)
        for (u, c) in zip(urls, cases) {
            #expect(try Data(contentsOf: u) == c.2, "\(c.0)")
        }
    }

    @Test func mixedEndingsAndBinaryAndLargeSkipped() throws {
        let root = try dir()
        defer { try? FileManager.default.removeItem(at: root) }
        let mixed = try put(root, "mixed.txt", Data("owl\r\nowl\n".utf8))
        let bin = try put(root, "b.bin", Data("owl".utf8) + Data([0, 1, 0]))
        let big = try put(root, "big.txt", Data("owl ".utf8) + Data(repeating: 0x61, count: 2048))
        let q = ReplaceQuery(query: "owl", template: "x")
        let plan = try FileReplace.plan(q, root: root, candidates: candidates(root, [mixed, bin, big]), maxFileSize: 1024)
        #expect(plan.files.isEmpty)
        #expect(plan.skippedCount(.mixedLineEndings) == 1)
        #expect(plan.skippedCount(.binary) == 1)
        #expect(plan.skippedCount(.tooLarge) == 1)
    }

    @Test func regexTemplatesCaseAndZeroLength() throws {
        let q = ReplaceQuery(query: #"(\w+)@(\w+)"#, template: "$2 at $1", regex: true)
        let re = try FindEngine.regex(q.query, q.findOptions)
        let text = "mail bob@home\nand Amy@Work\n"
        let e = FileReplace.edits(in: text, regex: re, query: q)
        #expect(FileReplace.applying(e, to: text) == "mail home at bob\nand Work at Amy\n")
        #expect(e.map(\.line) == [1, 2])
        #expect(e[1].lineText == "and Amy@Work" && e[1].lineRange == NSRange(location: 4, length: 8))
        // The find bar's Replace All gives the same text.
        #expect(try FindEngine.replaceAll(in: text, pattern: q.query, with: q.template, options: q.findOptions).0 == FileReplace.applying(e, to: text))
        // Case-insensitive literal; "$1" stays literal outside regex mode.
        let lit = ReplaceQuery(query: "OWL", template: "$1")
        let le = FileReplace.edits(in: "owl Owl", regex: try FindEngine.regex(lit.query, lit.findOptions), query: lit)
        #expect(FileReplace.applying(le, to: "owl Owl") == "$1 $1")
        // Zero-length matches are ignored.
        let z = ReplaceQuery(query: "x*", template: "-", regex: true)
        let ze = FileReplace.edits(in: "abxxc", regex: try FindEngine.regex(z.query, z.findOptions), query: z)
        #expect(ze.count == 1 && FileReplace.applying(ze, to: "abxxc") == "ab-c")
        // Line anchors per line, as the find bar.
        let a = ReplaceQuery(query: "^", template: "> ", regex: true)
        #expect(FileReplace.edits(in: "a\nb", regex: try FindEngine.regex(a.query, a.findOptions), query: a).isEmpty)
        let b = ReplaceQuery(query: "^(.)", template: "> $1", regex: true)
        #expect(FileReplace.applying(FileReplace.edits(in: "a\nb", regex: try FindEngine.regex(b.query, b.findOptions), query: b), to: "a\nb") == "> a\n> b")
    }

    @Test func spanIsOneBufferChange() throws {
        let q = ReplaceQuery(query: "o", template: "00")
        let text = "xo yo zo!"
        let e = FileReplace.edits(in: text, regex: try FindEngine.regex(q.query, q.findOptions), query: q)
        let (span, new) = try #require(FileReplace.span(Array(e.dropFirst()), in: text))
        #expect(span == NSRange(location: 4, length: 4))
        #expect(new == "00 z00")
    }

    @Test func stampMismatchSkipped() throws {
        let root = try dir()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ReplaceUndoStore(root: root.appendingPathComponent(".undo"))
        let a = try put(root, "a.txt", Data("owl\n".utf8))
        let b = try put(root, "b.txt", Data("owl\n".utf8))
        let q = ReplaceQuery(query: "owl", template: "cat")
        // Changed between search and preview.
        var cs = candidates(root, [a, b])
        cs[0].searchStamp = DiskStamp(modified: Date(timeIntervalSince1970: 1), size: 4)
        let plan = try FileReplace.plan(q, root: root, candidates: cs)
        #expect(plan.skippedCount(.changedSinceSearch) == 1 && plan.files.count == 1)
        // Changed between preview and write, same size and (forced) same date: the hash catches it.
        let date = try FileManager.default.attributesOfItem(atPath: b.path)[.modificationDate] as! Date
        try Data("OWL\n".utf8).write(to: b)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: b.path)
        let report = FileReplace.apply(plan.files, query: q, root: root, store: store)
        #expect(report.written.isEmpty)
        #expect(report.skipped.map(\.reason) == [.changedSincePreview])
        #expect(try Data(contentsOf: b) == Data("OWL\n".utf8))
        #expect(report.operation == nil)
    }

    @Test func permissionsAndXattrsKept() throws {
        let root = try dir()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ReplaceUndoStore(root: root.appendingPathComponent(".undo"))
        let f = try put(root, "run.sh", Data("echo owl\n".utf8))
        chmod(f.path, 0o750)
        setxattr(f.path, "org.owlink.test", "v", 1, 0, 0)
        _ = try replaceAll(ReplaceQuery(query: "owl", template: "hoot"), root: root, [f], store: store)
        var st = stat()
        stat(f.path, &st)
        #expect(st.st_mode & 0o7777 == 0o750)
        var buf = [UInt8](repeating: 0, count: 4)
        #expect(getxattr(f.path, "org.owlink.test", &buf, 4, 0, 0) == 1)
        #expect(try String(contentsOf: f, encoding: .utf8) == "echo hoot\n")
        // No temp files left behind.
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted() == [".undo", "run.sh"])
    }

    @Test func undoRestoresBytesAndSkipsLaterEdits() throws {
        let root = try dir()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ReplaceUndoStore(root: root.appendingPathComponent(".undo"))
        let origA = Data([0xEF, 0xBB, 0xBF]) + Data("owl\r\nowl\r\n".utf8)
        let origB = Data("one owl\n".utf8)
        let a = try put(root, "a.txt", origA)
        let b = try put(root, "b.txt", origB)
        let (_, report) = try replaceAll(ReplaceQuery(query: "owl", template: "bird"), root: root, [a, b], store: store)
        let id = try #require(report.operation)
        #expect(report.replacements == 3)
        // The backup folder is private.
        var st = stat()
        stat(root.appendingPathComponent(".undo/\(id.uuidString)").path, &st)
        #expect(st.st_mode & 0o777 == 0o700)
        // b is edited again after the replace: undo leaves it alone.
        try Data("one bird!\n".utf8).write(to: b)
        let u = store.undo(id)
        #expect(u.restored.map(\.lastPathComponent) == ["a.txt"])
        #expect(u.skipped.map(\.reason) == [.changedSinceReplace])
        #expect(try Data(contentsOf: a) == origA)
        #expect(try Data(contentsOf: b) == Data("one bird!\n".utf8))
        #expect(store.manifest(id)?.undone == true)
        // A second undo does nothing.
        #expect(store.undo(id).restored.isEmpty)
    }

    @Test func manifestPruning() throws {
        let root = try dir()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ReplaceUndoStore(root: root.appendingPathComponent("undo"))
        let q = ReplaceQuery(query: "a", template: "b")
        let now = Date()
        var ids: [UUID] = []
        // One 8 days old, then six recent ones.
        ids.append(try store.begin(query: q, now: now.addingTimeInterval(-8 * 24 * 3600)).id)
        for k in 0..<6 { ids.append(try store.begin(query: q, now: now.addingTimeInterval(Double(k))).id) }
        store.prune(now: now.addingTimeInterval(10))
        let left = Set(try FileManager.default.contentsOfDirectory(atPath: store.root.path))
        #expect(left == Set(ids.suffix(5).map(\.uuidString)))
    }

    @Test func symlinksAndOutsideRootRefused() throws {
        let root = try dir()
        let outside = try dir()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
        let target = try put(outside, "t.txt", Data("owl\n".utf8))
        let link = root.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let hard = try put(root, "h.txt", Data("owl\n".utf8))
        try FileManager.default.linkItem(at: hard, to: root.appendingPathComponent("h2.txt"))
        let q = ReplaceQuery(query: "owl", template: "x")
        let plan = try FileReplace.plan(q, root: root, candidates: [
            .init(url: link, relativePath: "link.txt", searchStamp: nil),
            .init(url: target, relativePath: "t.txt", searchStamp: nil),
            .init(url: hard, relativePath: "h.txt", searchStamp: nil),
        ])
        #expect(plan.files.isEmpty)
        #expect(plan.skipped.map(\.reason) == [.symbolicLink, .outsideFolder, .hardLinked])
        #expect(try Data(contentsOf: target) == Data("owl\n".utf8))
    }

    @Test func openBuffersPlannedFromTheirText() throws {
        let root = try dir()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ReplaceUndoStore(root: root.appendingPathComponent(".undo"))
        let f = try put(root, "open.txt", Data("owl on disk\n".utf8))
        let q = ReplaceQuery(query: "owl", template: "cat")
        let plan = try FileReplace.plan(q, root: root, candidates: candidates(root, [f]),
                                        buffers: [f.standardizedFileURL.path: "owl owl unsaved"])
        #expect(plan.files.count == 1 && plan.files[0].disk == nil && plan.files[0].edits.count == 2)
        // apply never writes a buffer-planned file.
        let r = FileReplace.apply(plan.files, query: q, root: root, store: store)
        #expect(r.written.isEmpty)
        #expect(try Data(contentsOf: f) == Data("owl on disk\n".utf8))
    }

    @Test func unencodableReplacementSkipped() throws {
        let root = try dir()
        defer { try? FileManager.default.removeItem(at: root) }
        let f = try put(root, "l.txt", "caf\u{E9} owl\n".data(using: .isoLatin1)!)
        let plan = try FileReplace.plan(ReplaceQuery(query: "owl", template: "🦉"), root: root, candidates: candidates(root, [f]))
        #expect(plan.files.isEmpty && plan.skippedCount(.cannotEncode) == 1)
    }

    @Test func partialSelectionWritesOnlyCheckedEdits() throws {
        let root = try dir()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ReplaceUndoStore(root: root.appendingPathComponent(".undo"))
        let f = try put(root, "p.txt", Data("owl1 owl2 owl3\n".utf8))
        let q = ReplaceQuery(query: "owl", template: "cat")
        var plan = try FileReplace.plan(q, root: root, candidates: candidates(root, [f]))
        plan.files[0].edits.remove(at: 1)
        let r = FileReplace.apply(plan.files, query: q, root: root, store: store)
        #expect(r.replacements == 2)
        #expect(try String(contentsOf: f, encoding: .utf8) == "cat1 owl2 cat3\n")
    }
}
