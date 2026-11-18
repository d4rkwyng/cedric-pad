import Foundation
import Testing
@testable import CedricCore

@Suite struct PowerShellTests {
    @Test func basics() {
        let k = kinds(#"""
        [CmdletBinding(SupportsShouldProcess)]
        param([Parameter(Mandatory = $true)][string]$Name, [int[]]$Sizes = @(1KB, 10MB, 0x1F))
        function Get-Widget {
            foreach ($item in $Sizes) { if ($item -gt 5 -and $Name -like 'w*') { Write-Host $item -ForegroundColor Green } }
            $env:PATH; $script:count++; ${weird name} = $null; $_.Length; $true
            [System.Collections.Generic.List[string]]::new().Add('x')
            Get-ChildItem -Path . | Where-Object { $_.Name -match '\.ps1$' } # trailing
        }
        """#, .powershell)
        #expect(k["CmdletBinding"] == .attribute && k["Parameter"] == .attribute)
        #expect(k["SupportsShouldProcess"] == nil && k["Mandatory"] == nil)
        #expect(k["param"] == .keyword && k["function"] == .keyword && k["foreach"] == .keyword && k["in"] == .keyword && k["if"] == .keyword)
        #expect(k["[string]"] == .type && k["[int[]]"] == .type && k["[System.Collections.Generic.List[string]]"] == .type)
        #expect(k["$Name"] == .variable && k["$Sizes"] == .variable && k["$item"] == .variable)
        #expect(k["$true"] == .constant && k["$null"] == .constant)
        #expect(k["1KB"] == .number && k["10MB"] == .number && k["0x1F"] == .number && k["5"] == .number)
        #expect(k["Get-Widget"] == .function && k["Write-Host"] == .function && k["Get-ChildItem"] == .function && k["Where-Object"] == .function)
        #expect(k["-gt"] == .keyword && k["-and"] == .keyword && k["-like"] == .keyword && k["-match"] == .keyword)
        #expect(k["-ForegroundColor"] == .attribute && k["-Path"] == .attribute)
        #expect(k["'w*'"] == .string && k["'\\.ps1$'"] == .string)
        #expect(k["$env:PATH"] == .variable && k["$script:count"] == .variable && k["${weird name}"] == .variable)
        #expect(k["$_"] == .variable)
        #expect(k["Length"] == nil)          // a member, not a keyword or a call
        #expect(k["new"] == .function && k["Add"] == .function)
        #expect(k["# trailing"] == .comment)
        #expect(k["Green"] == nil)
    }

    @Test func expandableStringsAndNestedSubexpressions() {
        let s = spans(#"""
        "Hello $name, today is $(Get-Date -Format "yyyy-MM-dd $($env:TZ)") ok" + 'not $expanded'
        "escaped `$dollar and ""quotes"" and ${braced}"
        """#, .powershell)
        let l0 = s[0]
        #expect(l0.first! == ("\"Hello ", .string))
        #expect(l0.contains { $0 == ("$name", .variable) })
        #expect(l0.contains { $0 == ("$(", .variable) })
        #expect(l0.contains { $0 == ("Get-Date", .function) })
        #expect(l0.contains { $0 == ("-Format", .attribute) })
        // The string inside the subexpression has its own subexpression.
        #expect(l0.contains { $0 == ("\"yyyy-MM-dd ", .string) })
        // `$(`, the variable and `)` touch, so they are one variable-coloured run.
        #expect(l0.contains { $0 == ("$($env:TZ)", .variable) })
        #expect(l0.contains { $0 == (" ok\"", .string) })
        #expect(l0.last! == ("'not $expanded'", .string))
        // Backtick-escaped $ and doubled quotes stay string; ${braced} is a variable.
        #expect(s[1].first! == ("\"escaped `$dollar and \"\"quotes\"\" and ", .string))
        #expect(s[1].contains { $0 == ("${braced}", .variable) })
    }

    @Test func hereStrings() {
        let s = spans(#"""
        $a = @'
        literal $notvar "quotes" '@ not the end
        '@
        $b = @"
        expands $name and $(1 + 2) here
         "@ indented: still inside
        "@
        Write-Output $b
        """#, .powershell)
        #expect(s[0].last! == ("@'", .string))
        #expect(s[1] == [("literal $notvar \"quotes\" '@ not the end", .string)])
        #expect(s[2] == [("'@", .string)])
        #expect(s[3].last! == ("@\"", .string))
        #expect(s[4].contains { $0 == ("$name", .variable) })
        #expect(s[4].contains { $0 == ("2", .number) })
        #expect(s[5] == [(" \"@ indented: still inside", .string)])
        #expect(s[6] == [("\"@", .string)])
        #expect(s[7].contains { $0 == ("Write-Output", .function) })
    }

    @Test func blockCommentsAndHelp() {
        let s = spans("""
        <#
        .SYNOPSIS
            Gets a widget. # not a new comment
        .PARAMETER Name
        #>
        <# .NOTES inline #> $x = 1
        # .EXAMPLE
        """, .powershell)
        #expect(s[0] == [("<#", .comment)])
        #expect(s[1] == [(".SYNOPSIS", .keyword)])
        #expect(s[2] == [("    Gets a widget. # not a new comment", .comment)])
        #expect(s[3] == [(".PARAMETER", .keyword), (" Name", .comment)])
        #expect(s[4] == [("#>", .comment)])
        #expect(s[5].prefix(3).map { $0.1 } == [.comment, .keyword, .comment])
        #expect(s[5].contains { $0 == ("$x", .variable) })
        #expect(s[6] == [("# ", .comment), (".EXAMPLE", .keyword)])
    }

    @Test func multiLineStringsCarryState() {
        let s = spans("""
        $q = "first
        second $v"
        $r = 'one
        two'; $z
        """, .powershell)
        #expect(s[1] == [("second ", .string), ("$v", .variable), ("\"", .string)])
        #expect(s[3].first! == ("two'", .string) && s[3].last! == ("$z", .variable))
    }

    @Test func notCommentsOrTypes() {
        let k = kinds("""
        $a[0] = $h['key']; git commit -m fix#123
        """, .powershell)
        #expect(k["$a"] == .variable && k["'key'"] == .string)
        #expect(k["[0]"] == nil && k["0"] == .number)
        #expect(!k.keys.contains { $0.hasPrefix("#") }) // `fix#123` is one word, not a comment
    }

    @Test func detectionAndExtensions() {
        #expect(LanguageDetector.language(forFileName: "build.ps1") == .powershell)
        #expect(LanguageDetector.language(forFileName: "Mod.psm1") == .powershell)
        #expect(LanguageDetector.language(forFileName: "Mod.psd1") == .powershell)
        #expect(LanguageDetector.language(forFileName: "Types.ps1xml") == .xml)
        #expect(LanguageDetector.language(forShebang: "#!/usr/bin/env pwsh") == .powershell)
        #expect(LanguageDetector.sniff("param(\n  [string]$Path\n)\nGet-ChildItem $Path\n") == .powershell)
        #expect(LanguageDetector.sniff("function Get-Thing {\n  $x = 1\n  return $x\n}\n") == .powershell)
        #expect(LanguageDetector.sniff("$PSVersionTable.PSVersion\n") == .powershell)
        #expect(LanguageDetector.sniff("$name = 'world'\nWrite-Host \"Hello $name\"\n") == .powershell)
        // Shell stays shell.
        #expect(LanguageDetector.sniff("set -e\nNAME=world\necho \"hi $NAME\"\nif [ -f x ]; then\n  echo y\nfi\n") == .shell)
        #expect(Language(fenceInfo: "powershell") == .powershell && Language(fenceInfo: "ps1") == .powershell && Language(fenceInfo: "pwsh") == .powershell)
        #expect(Language.powershell.commentSyntax == CommentSyntax(line: "#"))
    }

    @Test func outlineListsFunctions() {
        let o = PowerShellOutline.entries(in: """
        function Get-One { }
        <#
        function Not-This { }
        #>
        $s = @'
        function Nor-This
        '@
        filter Only-Even { }
        class Widget {
            [string] Name
        }
        enum Color { Red }
        """)
        #expect(o.map(\.title) == ["Get-One", "Only-Even", "Widget", "Color"])
        #expect(o.map(\.line) == [0, 7, 8, 11])
    }

    @Test func owlBracketsUnderstandPowerShell() {
        let rules = RulesHintProvider()
        func brackets(_ text: String) -> OwlHint? {
            let ctx = OwlContext(fileName: "x.ps1", language: "powershell", text: text, textStart: 0,
                                 visibleRange: NSRange(location: 0, length: 0), selection: nil, documentID: UUID(), editGeneration: 0)
            return rules.check(ctx, facts: OwlDocumentFacts()).first { $0.id == RulesHintProvider.bracketsID }
        }
        // Here-strings, subexpressions, comments, escapes and ${…} hold brackets that don't count.
        let fine = #"""
        <# a ( in help #>
        function Get-Thing {
            param([string]$Name = "x)")   # ) in a comment
            $here = @"
        Unbalanced ( and } in a here-string, $(Get-Date) and $($a[0])
        "@
            $lit = @'
        ] [ { lit
        '@
            $s = "nested $(if ($x) { "in $(Get-Item ")") here" }) end"
            $e = "a `( b" + 'it''s ('
            ${odd (name} = 1
            $q = “typographic ( quotes”
            Write-Host `( @{ a = 1 }
        }
        """#
        #expect(brackets(fine) == nil)
        #expect(brackets("function F {\n  if ($a) { 1 ]\n}\n")?.title == "“{” closed by “]” on line 2.")
        #expect(brackets("$x = (1 + 2))\n")?.title == "An extra “)” on line 1.")
        #expect(brackets("function F {\n  Write-Host 'x'\n")?.title == "“{” on line 1 is never closed.")
    }

    @Test func autoIndentAfterBraceAndParen() {
        let t = "function F {" as NSString
        let r = AutoEdit.newline(in: t, lineStart: 0, caret: t.length, after: t.length, language: .powershell)
        #expect(r.text == "\n    ")
        let p = "param(" as NSString
        #expect(AutoEdit.newline(in: p, lineStart: 0, caret: p.length, after: p.length, language: .powershell).text == "\n    ")
    }
}

/// One line's spans compared with the expected (text, kind) pairs.
func == (a: [(String, TokenKind)], b: [(String, TokenKind)]) -> Bool {
    a.count == b.count && zip(a, b).allSatisfy { $0 == $1 }
}
