import Foundation
import Testing
import UniformTypeIdentifiers
@testable import CedricCore

@Suite struct DocumentTypesTests {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    @Test func theListedTypes() {
        #expect(DocumentTypes.all.map(\.label) == ["TXT", "MD", "JSON", "YAML", "SWIFT", "PY", "JS", "TS", "SH", "LOG", "CSV",
                                                    "XML", "HTML", "CSS", "TOML", "INI", "SQL", "PS1"])
        let all = DocumentTypes.declared
        #expect(Set(all.map(\.label)).count == all.count)
        #expect(Set(all.map(\.icon)).count == all.count)
        let claims = DocumentTypes.all.flatMap(\.contentTypes)
        #expect(Set(claims).count == claims.count, "no content type is in two labelled rows")
        // The catch-all keeps 0.2.x's list exactly (same defaults after the update).
        #expect(DocumentTypes.catchAll.contentTypes == ["public.text", "public.plain-text", "public.source-code", "public.script",
                                                        "public.json", "public.yaml", "public.html", "public.xml", "public.css",
                                                        "net.daringfireball.markdown", "public.log", "public.data"])
    }

    @Test func infoPlistSourceMatchesTheModel() throws {
        let text = try String(contentsOf: Self.root.appendingPathComponent("Resources/document-types.txt"), encoding: .utf8)
        #expect(DocumentTypes.parse(text) == DocumentTypes.declared)
    }

    @Test func everyTypeHasItsIcon() {
        for t in DocumentTypes.declared {
            let p = Self.root.appendingPathComponent("Resources/DocIcons/\(t.icon).icns").path
            #expect(FileManager.default.fileExists(atPath: p), "\(p)")
        }
        let script = (try? String(contentsOf: Self.root.appendingPathComponent("tools/icon/doc_icons.py"), encoding: .utf8)) ?? ""
        for t in DocumentTypes.declared {
            #expect(script.contains("'\(t.icon)'"), "doc_icons.py makes \(t.icon)")
        }
    }

    @Test func systemTypesMapFromTheirExtensions() {
        // The types Owlink doesn't declare: macOS knows them, and a file's
        // extension resolves to them (or a subtype the claim covers).
        let ext = ["TXT": "txt", "JSON": "json", "YAML": "yaml", "SWIFT": "swift", "PY": "py", "JS": "js",
                   "SH": "sh", "LOG": "log", "CSV": "csv", "XML": "xml", "HTML": "html", "CSS": "css"]
        for t in DocumentTypes.all where t.imported == nil {
            #expect(UTType(t.primaryType) != nil, "\(t.primaryType) is declared by macOS")
            let e = ext[t.label]!
            let found = UTType(filenameExtension: e)
            #expect(found.map { f in t.contentTypes.contains { f.conforms(to: UTType($0)!) } } == true,
                    ".\(e) -> \(found?.identifier ?? "nil") is claimed by \(t.label)")
            #expect(found?.conforms(to: .text) == true, ".\(e) is text")
        }
        #expect(UTType(filenameExtension: "zsh").map { $0.conforms(to: UTType("public.shell-script")!) } == true)
    }

    @Test func settingsList() {
        #expect(DocumentTypes.settingsTypes.map(\.label) == DocumentTypes.all.map(\.label).filter { $0 != "HTML" })
        let log = DocumentTypes.all.first { $0.label == "LOG" }!
        #expect(log.settingsTypes == ["com.apple.log"])
        #expect(DocumentTypes.all.first { $0.label == "SH" }!.settingsTypes.count == 3)
        #expect(DocumentTypes.all.first { $0.label == "TS" }!.sampleExtension == "tsx", ".ts is a video type to macOS first")
    }

    @Test func importedDeclarations() {
        let imported = DocumentTypes.all.filter { $0.imported != nil }
        #expect(imported.map(\.label) == ["MD", "TS", "TOML", "INI", "SQL", "PS1"])
        for t in imported {
            let i = t.imported!
            #expect(!i.extensions.isEmpty && !i.conformsTo.isEmpty)
            #expect(i.conformsTo.allSatisfy { UTType($0) != nil }, "\(t.label) conforms to system types")
            #expect(i.conformsTo.allSatisfy { UTType($0)!.conforms(to: .text) }, "\(t.label) is declared as text")
            #expect(t.sampleExtension == i.extensions[0])
        }
        // .ts stays the system's video type by preference; the TypeScript
        // claim is a separate type.
        #expect(DocumentTypes.all.first { $0.label == "TS" }?.contentTypes == ["com.microsoft.typescript"])
    }
}

@MainActor
@Suite struct DefaultEditorModelTests {
    final class Fake: DefaultAppService, @unchecked Sendable {
        var map: [String: URL] = [:]
        var sets: [(String, URL)] = []
        var refuse: Set<String> = []
        func defaultApp(forContentType id: String) -> URL? { map[id] }
        func setDefaultApp(_ app: URL, forContentType id: String) async throws {
            if refuse.contains(id) { throw CocoaError(.userCancelled) }
            sets.append((id, app))
            map[id] = app
        }
    }

    // Real paths, so "the earlier app still exists" holds.
    let owlink = URL(fileURLWithPath: "/tmp/Owlink-test.app")
    let other = URL(fileURLWithPath: NSTemporaryDirectory())

    func make(_ f: Fake) -> (DefaultEditorModel, String) {
        let (d, n) = TestDefaults.make("cedric-default-")
        return (DefaultEditorModel(app: owlink, service: f, defaults: d), n)
    }

    @Test func readingChangesNothing() {
        let f = Fake()
        f.map["net.daringfireball.markdown"] = other
        f.map["public.json"] = owlink
        let (m, n) = make(f)
        defer { TestDefaults.remove(n) }
        #expect(f.sets.isEmpty)
        #expect(m.rows.count == DocumentTypes.settingsTypes.count)
        let md = m.rows.first { $0.type.label == "MD" }!
        #expect(!md.isOwlink && md.current == other)
        #expect(m.rows.first { $0.type.label == "JSON" }!.isOwlink)
        #expect(m.rows.first { $0.type.label == "TOML" }!.currentName == "no app")
    }

    @Test func tickAndUntick() async {
        let f = Fake()
        for c in ["public.shell-script", "public.zsh-script", "public.bash-script"] { f.map[c] = other }
        let (m, n) = make(f)
        defer { TestDefaults.remove(n) }
        let sh = DocumentTypes.all.first { $0.label == "SH" }!
        #expect(await m.setOwlink(true, for: sh) == .done)
        #expect(f.sets.map(\.0) == sh.contentTypes && f.sets.allSatisfy { $0.1 == owlink })
        #expect(m.rows.first { $0.type.label == "SH" }!.isOwlink)
        #expect(m.previousApp(for: sh) == other)
        f.sets.removeAll()
        #expect(await m.setOwlink(false, for: sh) == .done)
        #expect(f.sets.count == 3 && f.sets.allSatisfy { $0.1 == other })
        #expect(!m.rows.first { $0.type.label == "SH" }!.isOwlink)
        #expect(m.previousApp(for: sh) == nil, "forgotten once given back")
    }

    @Test func untickWithNoEarlierApp() async {
        let f = Fake()
        f.map["public.toml"] = owlink
        let (m, n) = make(f)
        defer { TestDefaults.remove(n) }
        let toml = DocumentTypes.all.first { $0.label == "TOML" }!
        #expect(await m.setOwlink(false, for: toml) == .noPreviousApp)
        #expect(f.sets.isEmpty)
    }

    @Test func refusalIsReported() async {
        let f = Fake()
        f.refuse = ["public.yaml"]
        let (m, n) = make(f)
        defer { TestDefaults.remove(n) }
        let (changed, outcome) = await m.useOwlinkForAll()
        #expect(changed == 3, "TXT, MD, JSON, then YAML was refused")
        if case .failed = outcome {} else { Issue.record("expected .failed, got \(outcome)") }
        #expect(f.map["public.yaml"] == nil)
        f.refuse = []
        let (rest, ok) = await m.useOwlinkForAll()
        #expect(ok == .done && rest == DocumentTypes.settingsTypes.count)
        #expect(m.rows.allSatisfy { $0.isOwlink })
        // Again: types Owlink already opens are set explicitly too (the
        // labelled icon needs an explicit choice); never HTML or public.log.
        f.sets.removeAll()
        let (again, _) = await m.useOwlinkForAll()
        #expect(again == DocumentTypes.settingsTypes.count)
        #expect(!f.sets.contains { $0.0 == "public.html" || $0.0 == "public.log" })
    }
}
