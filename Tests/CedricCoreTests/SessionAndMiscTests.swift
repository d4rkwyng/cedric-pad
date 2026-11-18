import Foundation
import Testing
@testable import CedricCore

func tempDir() -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("cedric-test-\(UUID().uuidString)", isDirectory: true)
    return d
}

@Suite struct SessionTests {
    @Test func saveAndRestoreWithUntitledAndDirtyTabs() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SessionStore(directory: dir)
        #expect(store.load() == nil)

        let untitled = SessionTab(untitledName: "Untitled 2", hasBuffer: true, language: .markdown, selectionLocation: 3, topLine: 0)
        let dirtyFile = SessionTab(path: "/tmp/notes.txt", hasBuffer: true, encoding: .latin1, lineEnding: .crlf, selectionLocation: 10, selectionLength: 4, topLine: 42)
        let clean = SessionTab(path: "/tmp/clean.swift")
        try store.writeBuffer(untitled.id, text: "# Draft\nnever saved ✓")
        try store.writeBuffer(dirtyFile.id, text: "edited")
        let session = Session(windows: [SessionWindow(tabs: [untitled, dirtyFile], selectedTab: 1, frame: "0 0 800 600 0 0 1440 900"),
                                        SessionWindow(tabs: [clean])], untitledCounter: 2)
        try store.save(session)

        // A new store on the same directory, as after a relaunch or crash.
        let again = SessionStore(directory: dir)
        let restored = try #require(again.load())
        #expect(restored == session)
        #expect(again.readBuffer(untitled.id) == "# Draft\nnever saved ✓")
        #expect(again.readBuffer(dirtyFile.id) == "edited")
        #expect(again.readBuffer(clean.id) == nil)
        #expect(restored.allTabs.count == 3)
    }

    @Test func pruneRemovesOrphanBuffers() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SessionStore(directory: dir)
        let keep = UUID(), drop = UUID()
        try store.writeBuffer(keep, text: "k")
        try store.writeBuffer(drop, text: "d")
        store.pruneBuffers(keeping: [keep])
        #expect(store.readBuffer(keep) == "k")
        #expect(store.readBuffer(drop) == nil)
    }

    @Test func corruptSessionLoadsAsNil() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: dir.appendingPathComponent("session.json"))
        #expect(SessionStore(directory: dir).load() == nil)
    }

    @Test func newerVersionIsIgnored() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SessionStore(directory: dir)
        var s = Session(windows: [])
        s.version = Session.currentVersion + 1
        try store.save(s)
        #expect(store.load() == nil)
    }

    @Test func environmentOverridesDirectory() {
        #expect(SessionStore.defaultDirectory(environment: ["CEDRIC_SESSION_DIR": "/tmp/x"]).path == "/tmp/x")
        #expect(SessionStore.defaultDirectory(environment: [:]).path.hasSuffix("Application Support/Cedric/Session"))
    }
}

@Suite struct LanguageDetectionTests {
    @Test func byExtensionAndName() {
        #expect(LanguageDetector.language(forFileName: "a.swift") == .swift)
        #expect(LanguageDetector.language(forFileName: "A.PY") == .python)
        #expect(LanguageDetector.language(forFileName: "x.tsx") == .typescript)
        #expect(LanguageDetector.language(forFileName: "c.yml") == .yaml)
        #expect(LanguageDetector.language(forFileName: "Gemfile") == .ruby)
        #expect(LanguageDetector.language(forFileName: ".zshrc") == .shell)
        #expect(LanguageDetector.language(forFileName: "README") == nil)
        #expect(LanguageDetector.language(forFileName: ".hidden") == nil)
    }

    @Test func byShebang() {
        #expect(LanguageDetector.detect(fileName: "run", content: "#!/usr/bin/env python3\nprint(1)") == .python)
        #expect(LanguageDetector.detect(fileName: "run", content: "#!/bin/zsh\necho") == .shell)
        #expect(LanguageDetector.detect(fileName: nil, content: "#!/usr/bin/env -S node --x\n") == .javascript)
        #expect(LanguageDetector.detect(fileName: nil, content: "#!/usr/bin/ruby -w\n") == .ruby)
    }

    @Test func sniffingPastedContent() {
        #expect(LanguageDetector.sniff("{\"a\": [1, 2]}") == .json)
        #expect(LanguageDetector.sniff("<!DOCTYPE html>\n<html></html>") == .html)
        #expect(LanguageDetector.sniff("import SwiftUI\n\nstruct V: View {}") == .swift)
        #expect(LanguageDetector.sniff("from os import path\ndef f():\n    pass") == .python)
        #expect(LanguageDetector.sniff("# Title\n\nSome text\n\n## More") == .markdown)
        #expect(LanguageDetector.sniff("#include <stdio.h>\nint main() {}") == .c)
        #expect(LanguageDetector.sniff("name: x\nversion: 2\nitems:\n  - a") == .yaml)
        #expect(LanguageDetector.sniff("just some words") == .plain)
        #expect(LanguageDetector.sniff("") == .plain)
    }

    @Test func fileNameBeatsContent() {
        #expect(LanguageDetector.detect(fileName: "notes.txt", content: "{\"a\": 1}") == .json) // .txt unknown → sniff
        #expect(LanguageDetector.detect(fileName: "data.md", content: "{\"a\": 1}") == .markdown)
    }
}

@Suite struct ThemeTests {
    @Test func everyThemeMeetsAA() {
        var failures: [String] = []
        for p in EditorPalettes.all {
            for (name, fg, bg) in p.textPairs {
                let r = EditorPalettes.contrast(fg, bg)
                if r < 4.5 { failures.append(String(format: "%@ %.2f", name, r)) }
            }
        }
        #expect(failures.isEmpty, "\(failures)")
    }

    @Test func systemFollowsAppearance() {
        #expect(EditorTheme.system.palette(systemIsDark: true).name == "dark")
        #expect(EditorTheme.system.palette(systemIsDark: false).name == "light")
        #expect(EditorTheme.tankard.palette(systemIsDark: false).isDark)
    }

    @Test func everyTokenKindHasAColour() {
        for p in EditorPalettes.all {
            for k in TokenKind.allCases where k != .plain { #expect(p.tokens[k] != nil, "\(p.name) \(k)") }
        }
    }
}
