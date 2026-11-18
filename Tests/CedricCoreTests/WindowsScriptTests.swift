import Foundation
import Testing
@testable import CedricCore

@Suite struct WindowsScriptTests {
    @Test func batch() {
        let s = spans("""
        @echo off
        REM a comment
        :: another
        setlocal enabledelayedexpansion
        set "NAME=%~dp0build"
        if %ERRORLEVEL% neq 0 goto :fail
        for %%f in (*.txt) do echo !count! %%f
        copy /y C:\\tmp\\set.txt out & rem done
        :fail
        exit /b 1
        """, .batch)
        let k = Dictionary(s.flatMap { $0 }.map { ($0.0, $0.1) }, uniquingKeysWith: { a, _ in a })
        #expect(s[0] == [("@", .punctuation), ("echo", .keyword), ("off", .keyword)])
        #expect(s[1] == [("REM a comment", .comment)] && s[2] == [(":: another", .comment)])
        #expect(k["setlocal"] == .keyword && k["enabledelayedexpansion"] == .keyword)
        #expect(k["\"NAME="] == .string && k["%~dp0"] == .variable && k["build\""] == .string)
        #expect(k["%ERRORLEVEL%"] == .variable && k["neq"] == .keyword && k["goto"] == .keyword && k["0"] == .number)
        #expect(k["%%f"] == .variable && k["!count!"] == .variable && k["for"] == .keyword && k["do"] == .keyword)
        #expect(k["/y"] == .attribute && k["/b"] == .attribute)
        #expect(k["set.txt"] == nil && !s[7].contains { $0.0 == "set" }) // a file name, not the command
        #expect(k["rem done"] == .comment)
        #expect(s[8] == [(":fail", .tag)])
        #expect(LanguageDetector.language(forFileName: "build.bat") == .batch && LanguageDetector.language(forFileName: "x.CMD") == .batch)
        #expect(LanguageDetector.sniff("@echo off\r\necho hi\r\n") == .batch)
        #expect(Language.batch.commentSyntax == CommentSyntax(line: "REM"))
    }

    @Test func registry() {
        let s = spans("""
        Windows Registry Editor Version 5.00

        ; Cedric settings
        [HKEY_CURRENT_USER\\Software\\Cedric]
        "Name"="Cedric \\"the owl\\""
        @="default"
        "Count"=dword:0000002a
        "Blob"=hex(2):25,00,50,00,\\
          41,00,00,00
        "Gone"=-
        [-HKEY_CURRENT_USER\\Software\\Old]
        """, .registry)
        #expect(s[0] == [("Windows Registry Editor Version 5.00", .keyword)])
        #expect(s[2] == [("; Cedric settings", .comment)])
        #expect(s[3] == [("[HKEY_CURRENT_USER\\Software\\Cedric]", .tag)])
        #expect(s[4] == [("\"Name\"", .key), ("\"Cedric \\\"the owl\\\"\"", .string)])
        #expect(s[5] == [("@", .key), ("\"default\"", .string)])
        #expect(s[6] == [("\"Count\"", .key), ("dword:", .type), ("0000002a", .number)])
        #expect(s[7] == [("\"Blob\"", .key), ("hex(2):", .type), ("25,00,50,00,\\", .number)])
        #expect(s[8] == [("41,00,00,00", .number)])
        #expect(s[9] == [("\"Gone\"", .key), ("-", .keyword)])
        #expect(s[10].first?.1 == .tag)
        #expect(LanguageDetector.language(forFileName: "settings.reg") == .registry)
        #expect(LanguageDetector.sniff("REGEDIT4\n\n[HKEY_LOCAL_MACHINE\\X]\n") == .registry)
        #expect(SpellScope.isData(.registry))
    }
}
