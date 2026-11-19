import Foundation

/// A deterministic, offline scan of a script for the patterns that make
/// running it risky: download-and-run, dynamic execution, encoded
/// commands, system and registry changes, credential access, turning off
/// security, persistence and broad deletes. No AI, no network: it works on
/// any Mac (Intel too), and Ask Cedric's "Is This Safe to Run?" shows its
/// findings first and hands them to the model.
///
/// It flags what a careful reader would want to look at, not malware: a
/// finding is a reason to read that line, and an empty scan is not proof
/// that a script is safe. Whole-line comments are skipped (`#`, `REM`,
/// `::`, `;` for the registry, PowerShell `<# … #>` blocks); a line
/// continued with `\` or a PowerShell backtick is read with the next one.
public enum ScriptSafety {
    public enum Category: String, Sendable, CaseIterable {
        case downloadAndRun, dynamicCode, encoded, download, systemChange, persistence,
             credentials, disablesSecurity, broadDelete, hidden

        public var title: String {
            switch self {
            case .downloadAndRun: return String(localized: "Downloads and runs code")
            case .dynamicCode: return String(localized: "Runs code built at run time")
            case .encoded: return String(localized: "Encoded or hidden command")
            case .download: return String(localized: "Downloads a file")
            case .systemChange: return String(localized: "Changes system settings")
            case .persistence: return String(localized: "Runs again at login or on a schedule")
            case .credentials: return String(localized: "Reads passwords or keys")
            case .disablesSecurity: return String(localized: "Turns off a security protection")
            case .broadDelete: return String(localized: "Deletes broadly")
            case .hidden: return String(localized: "Hides what it does")
            }
        }
    }

    public enum Severity: Int, Sendable, Comparable {
        case caution = 1, high = 2
        public static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }
    }

    public struct Finding: Sendable, Equatable {
        public let category: Category
        public let severity: Severity
        /// 1-based.
        public let line: Int
        /// The line, trimmed and capped at 120 characters.
        public let snippet: String
        /// One plain sentence.
        public let why: String
    }

    /// Languages the scan (and "Is This Safe to Run?") is offered for.
    public static func isScript(_ language: Language) -> Bool {
        switch language {
        case .shell, .powershell, .batch, .registry, .python, .ruby: return true
        default: return false
        }
    }

    /// At most this many lines are read (a script, not a log).
    public static let maxLines = 20_000
    /// At most this many findings are kept (the highest first, then in order).
    public static let maxFindings = 40

    public static func scan(_ text: String, language: Language) -> [Finding] {
        var out: [Finding] = []
        var inBlockComment = false
        var lines = text.split(separator: "\n", maxSplits: maxLines, omittingEmptySubsequences: false).map(String.init)
        if lines.count > maxLines { lines.removeLast() }
        var i = 0
        while i < lines.count {
            let first = i
            var line = lines[i].trimmingCharacters(in: .whitespaces)
            if line.hasSuffix("\r") { line.removeLast() }
            // PowerShell block comments.
            if language == .powershell {
                if inBlockComment {
                    if let r = line.range(of: "#>") { inBlockComment = false; line = String(line[r.upperBound...]) } else { i += 1; continue }
                }
                if let r = line.range(of: "<#") {
                    if let e = line.range(of: "#>", range: r.upperBound..<line.endIndex) {
                        line = String(line[..<r.lowerBound]) + String(line[e.upperBound...])
                    } else { inBlockComment = true; line = String(line[..<r.lowerBound]) }
                }
            }
            // Continued lines are read as one.
            while i + 1 < lines.count, line.hasSuffix("\\") && language != .batch && language != .registry || line.hasSuffix("`") && language == .powershell {
                line.removeLast()
                i += 1
                line += " " + lines[i].trimmingCharacters(in: .whitespaces)
            }
            i += 1
            if isComment(line, language: language) || line.isEmpty { continue }
            for f in findings(in: line, language: language) where !out.contains(where: { $0.line == first + 1 && $0.category == f.0 }) {
                out.append(Finding(category: f.0, severity: f.1, line: first + 1, snippet: snippet(line), why: f.2))
            }
        }
        // Download-and-run covers the plain download on its line.
        let runLines = Set(out.filter { $0.category == .downloadAndRun }.map(\.line))
        out.removeAll { ($0.category == .download || $0.category == .dynamicCode) && runLines.contains($0.line) }
        if out.count > maxFindings {
            let keep = out.enumerated().sorted { ($0.element.severity, -$0.offset) > ($1.element.severity, -$1.offset) }.prefix(maxFindings)
            out = keep.sorted { $0.offset < $1.offset }.map(\.element)
        }
        return out
    }

    static func isComment(_ line: String, language: Language) -> Bool {
        switch language {
        case .batch:
            let l = line.lowercased()
            return l.hasPrefix("rem ") || l == "rem" || l.hasPrefix("::") || l.hasPrefix("@rem ")
        case .registry:
            return line.hasPrefix(";")
        case .shell, .powershell, .python, .ruby:
            return line.hasPrefix("#") && !line.hasPrefix("#!")
        default:
            return line.hasPrefix("#") || line.hasPrefix("//")
        }
    }

    static func snippet(_ line: String) -> String {
        line.count > 120 ? String(line.prefix(119)) + "…" : line
    }

    // MARK: Patterns

    private struct Rule {
        let category: Category
        let severity: Severity
        let regex: NSRegularExpression
        let why: String
        init(_ c: Category, _ s: Severity, _ pattern: String, _ why: String) {
            category = c; severity = s; self.why = why
            regex = try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        }
        func matches(_ line: String) -> Bool {
            regex.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) != nil
        }
    }

    private static let fetch = #"(?:curl|wget|fetch|iwr|irm|invoke-webrequest|invoke-restmethod|downloadstring|downloadfile|downloaddata|start-bitstransfer|urllib\.request|requests\.get|open-uri|net::http)"#
    private static let shells = #"(?:sh|bash|zsh|dash|ksh|fish|python3?|perl|ruby|node|osascript|sudo\s+(?:-\w+\s+)*(?:sh|bash|zsh))"#

    private static let rules: [Rule] = [
        // Download and run.
        Rule(.downloadAndRun, .high, #"\b(?:curl|wget)\b[^|;&]*\|\s*(?:sudo\s+(?:-\S+\s+)*)?(?:env\s+\S+\s+)*"# + shells + #"\b"#,
             "Pipes something from the internet straight into a shell: whatever the server sends runs, unseen."),
        Rule(.downloadAndRun, .high, #"\b"# + shells + #"\s+(?:-\w+\s+)*(?:<\(|-c\s+["']?\$\()\s*(?:curl|wget)\b"#,
             "Runs a script fetched from the internet without saving or showing it first."),
        Rule(.downloadAndRun, .high, #"\b(?:iex|invoke-expression)\b.*"# + fetch + "|" + fetch + #".*\|\s*(?:iex|invoke-expression)\b"#,
             "Downloads text and runs it as PowerShell (Invoke-Expression): whatever the server sends runs."),
        Rule(.downloadAndRun, .high, #"\bexec\s*\(\s*(?:urllib|requests)\b|\beval\s*\(\s*(?:urllib|requests)\b"#,
             "Downloads code and runs it in this program."),
        Rule(.downloadAndRun, .high, #"\b(?:msiexec|start-process|bitsadmin)\b.*https?://"#,
             "Starts a program or installer straight from a web address."),
        // Plain downloads.
        Rule(.download, .caution, #"\b(?:curl|wget)\b.*(?:https?|ftp)://|\b(?:invoke-webrequest|iwr|invoke-restmethod|irm|start-bitstransfer)\b|\.download(?:file|string|data)\s*\(|\bbitsadmin\b.*\/transfer|\bcertutil\b.*-urlcache"#,
             "Fetches something from the internet: check where it comes from and what is done with it."),
        // Dynamic code.
        Rule(.dynamicCode, .caution, #"\b(?:iex|invoke-expression)\b|\[scriptblock\]::create|\.invokescript\s*\("#,
             "Runs a string as PowerShell code (Invoke-Expression): what it runs isn't visible here."),
        Rule(.dynamicCode, .caution, #"(?:^|[;&|]\s*)eval\s+["'`$]"#,
             "Runs a string as shell code (eval): what it runs depends on that string."),
        // Encoded commands.
        Rule(.encoded, .high, #"\b(?:powershell|pwsh)(?:\.exe)?\b.*\s[-/](?:e|ec|en|enc|enco|encod|encode|encoded|encodedc\w*)\s+["']?[A-Za-z0-9+/=]{16,}"#,
             "Runs a Base64-encoded PowerShell command (-EncodedCommand), which hides what it does."),
        Rule(.encoded, .high, #"base64\s+(?:-d|--decode|-D)\b[^|]*\|\s*(?:sudo\s+)?"# + shells + #"\b"#,
             "Decodes hidden (Base64) text and runs it as a script."),
        Rule(.encoded, .caution, #"frombase64string\s*\(|\bbase64\s+(?:-d|--decode|-D)\b|b64decode\s*\(|\bcertutil\b.*-decode"#,
             "Decodes Base64 text: check what the decoded data is used for."),
        // Hiding.
        Rule(.hidden, .caution, #"\b(?:powershell|pwsh|start-process)\b.*\s-w(?:indowstyle)?\s+["']?h(?:idden)?\b"#,
             "Runs PowerShell with a hidden window."),
        Rule(.hidden, .caution, #"\bhistory\s+-c\b|\bunset\s+histfile\b|clear-history|remove-item.*\(get-psreadlineoption\)\.historysavepath"#,
             "Clears the shell history, hiding what was run."),
        // Disabling security.
        Rule(.disablesSecurity, .high, #"set-mppreference\b.*-disable\w*\s+(?:\$true|1)|add-mppreference\b.*-exclusion"#,
             "Turns off Microsoft Defender protection or excludes files from scanning."),
        Rule(.disablesSecurity, .high, #"\bspctl\s+(?:--master-disable|--global-disable)|\bcsrutil\s+disable|\bsetenforce\s+0|\bufw\s+disable|netsh\s+(?:adv)?firewall\s+set\b.*\bstate\s+off|set-netfirewallprofile\b.*-enabled\s+(?:\$?false|0)|systemctl\s+(?:stop|disable)\s+(?:firewalld|apparmor|ufw)"#,
             "Turns off a system protection (Gatekeeper, SIP, SELinux or the firewall)."),
        Rule(.disablesSecurity, .caution, #"set-executionpolicy\b.*\b(?:bypass|unrestricted)\b|-ex(?:ecutionpolicy)?\s+(?:bypass|unrestricted)\b"#,
             "Bypasses PowerShell's script execution policy."),
        Rule(.disablesSecurity, .caution, #"\bxattr\s+(?:-\w+\s+)*-\w*d\w*\s+com\.apple\.quarantine|\bxattr\s+-(?:cr|rc|c)\s"#,
             "Removes macOS's quarantine mark, so Gatekeeper won't check the file."),
        // Credentials.
        Rule(.credentials, .high, #"\bsecurity\s+(?:find-generic-password|find-internet-password|dump-keychain)\b|\bmimikatz\b|sekurlsa|/etc/shadow\b|lsass|\bcmdkey\s+/list|\bvaultcmd\b|login\s+data|logins\.json|key4\.db|cookies\.sqlite"#,
             "Reads stored passwords, keychain items or browser logins."),
        Rule(.credentials, .caution, #"\bget-credential\b|convertto-securestring\b.*-asplaintext|\.ssh/id_\w+|\.aws/credentials|\.netrc\b|\.git-credentials|\bgh\s+auth\s+token|ssh-keygen\b.*-f\s"#,
             "Handles a password, a private key or a credentials file."),
        // Persistence.
        Rule(.persistence, .high, #"(?:hklm|hkcu|hkey_local_machine|hkey_current_user)[:\\]+software\\microsoft\\windows\\currentversion\\run|\bschtasks\b.*/create|register-scheduledtask|new-scheduledtask|\bnew-service\b|\bsc(?:\.exe)?\s+create\b"#,
             "Makes something run at every login or on a schedule."),
        Rule(.persistence, .high, #"library/launch(?:agents|daemons)|\blaunchctl\s+(?:load|bootstrap|submit)\b|\bcrontab\s+(?!-l\b)|/etc/cron|\bsystemctl\s+enable\b|/etc/rc\.local|loginitems|\.(?:bash_profile|bashrc|zshrc|zprofile|profile)\b.*(?:>>|tee)|(?:>>|tee\s+-a)\s*\S*\.(?:bash_profile|bashrc|zshrc|zprofile|profile)\b"#,
             "Makes something run at every login or on a schedule (launch agent, cron or shell profile)."),
        // System changes.
        Rule(.systemChange, .caution, #"\b(?:set|new|remove)-itemproperty\b.*(?:hklm|hkey_local_machine)|\breg(?:\.exe)?\s+(?:add|delete|import)\b|^\s*\[-?hkey_local_machine"#,
             "Changes the Windows registry for the whole machine."),
        Rule(.systemChange, .caution, #"\bsudo\s+defaults\s+write\b|\bdefaults\s+write\s+/library|\bnvram\b|\bpmset\b|\bscutil\s+--set|\bnetworksetup\s+-set|\bdscl\b.*-(?:create|append|passwd)|\bsysadminctl\b|(?:>|tee(?:\s+-a)?)\s*/etc/|\bchmod\s+(?:-\w+\s+)*[0-7]*777\b|\bbcdedit\b|\bvssadmin\b.*delete|\bwevtutil\s+cl\b|\bnet\s+user\b.*/add|\badd-localgroupmember\b|\bdisable-computerrestore\b"#,
             "Changes system settings, users or permissions for the whole Mac or PC."),
        Rule(.systemChange, .caution, #"\b(?:sudo|doas)\s"#,
             "Runs commands as an administrator (sudo)."),
        // Disks.
        Rule(.broadDelete, .high, #"\bdiskutil\s+(?:erasedisk|erasevolume|zerodisk|secureerase|partitiondisk)\b|\bdd\b.*\bof=/dev/|\bmkfs(?:\.\w+)?\s|\bformat-volume\b|\bclear-disk\b|\bformat\s+[a-z]:|\bcipher\s+/w"#,
             "Erases or formats a disk."),
    ]

    /// The rules' findings on one (joined) line, plus the delete checks.
    static func findings(in line: String, language: Language) -> [(Category, Severity, String)] {
        var out: [(Category, Severity, String)] = []
        for r in rules where r.matches(line) && !out.contains(where: { $0.0 == r.category }) {
            if r.category == .dynamicCode, isKnownShellInit(line) { continue }
            out.append((r.category, r.severity, r.why))
        }
        if let d = broadDelete(line) { out.append((.broadDelete, d.0, d.1)) }
        return out
    }

    private static let shellInit = try! NSRegularExpression(
        pattern: #"eval\s+["']?\$\(\s*(?:[\w/.~-]*/)?(?:brew|ssh-agent|pyenv|pyenv-virtualenv|rbenv|nodenv|jenv|goenv|plenv|direnv|starship|zoxide|conda|fnm|mise|rtx|thefuck|dircolors|gdircolors|keychain|luarocks|opam|rustup|nix|gpg-agent|aws_completer|kubectl|helm)\b"#,
        options: [.caseInsensitive])

    /// `eval "$(brew shellenv)"` and friends: everyday shell setup.
    static func isKnownShellInit(_ line: String) -> Bool {
        shellInit.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) != nil
            && !line.lowercased().contains("curl") && !line.lowercased().contains("wget")
    }

    // MARK: Broad deletes

    private static let rmRegex = try! NSRegularExpression(pattern: #"(?:^|[;&|({"'`]\s*|\bsudo\s+|\bthen\s+|\bdo\s+|\bxargs\s+)rm\s+((?:-{1,2}[\w-]+\s+)+)(.*)"#, options: [.caseInsensitive])
    private static let psRemove = try! NSRegularExpression(pattern: #"\b(?:remove-item|rm|ri|del|erase|rmdir|rd)\b(.*)"#, options: [.caseInsensitive])

    /// Places whose recursive delete is never what a script means.
    static func isBroadPath(_ raw: String) -> Bool {
        var t = raw.replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: "'", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: " ),;"))
        t = t.replacingOccurrences(of: "\\", with: "/")
        let lower = t.lowercased()
        if ["/", "/*", "~", "~/", "~/*", "*", ".*", "/.", "$home", "$home/", "$home/*", "${home}", "${home}/", "${home}/*",
            "$env:userprofile", "$env:userprofile/*", "$env:systemroot", "$env:windir", "%userprofile%", "%systemroot%", "%windir%",
            "c:", "c:/", "c:/*", "c:/windows", "c:/users", "c:/program files", "/users", "/home", "/system", "/library",
            "/usr", "/etc", "/var", "/bin", "/sbin", "/applications", "/private", "/opt", "/boot"].contains(lower) { return true }
        if ["/users/*", "/home/*", "/system/*", "/library/*", "/usr/*", "/etc/*", "/var/*", "/applications/*", "c:/users/*", "c:/windows/*"].contains(lower) { return true }
        // "$DIR/" or "$DIR"/* with an unguarded variable: empty means "/".
        if let re = try? NSRegularExpression(pattern: #"^\$\{?[A-Za-z_][A-Za-z0-9_]*\}?/\*?$"#),
           re.firstMatch(in: t, range: NSRange(location: 0, length: (t as NSString).length)) != nil,
           !t.contains(":?") { return true }
        return false
    }

    static func broadDelete(_ line: String) -> (Severity, String)? {
        let ns = line as NSString
        if let m = rmRegex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) {
            let flags = ns.substring(with: m.range(at: 1)).lowercased()
            let recursive = flags.contains("--recursive") || flags.split(separator: " ").contains { $0.hasPrefix("-") && !$0.hasPrefix("--") && $0.contains("r") }
            if recursive {
                let rest = ns.substring(with: m.range(at: 2))
                let args = rest.split(whereSeparator: { $0 == " " || $0 == ";" || $0 == "&" || $0 == "|" }).map(String.init)
                for a in args where !a.hasPrefix("-") {
                    if isBroadPath(a) {
                        let raw = a.replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: "'", with: "")
                            .trimmingCharacters(in: CharacterSet(charactersIn: " ),;"))
                        if raw.hasPrefix("$") && !["$home", "$home/", "$home/*"].contains(raw.lowercased()) && !raw.lowercased().hasPrefix("${home}") {
                            return (.high, "Deletes \(raw) recursively: if that variable is ever empty, this deletes from the top of the disk.")
                        }
                        return (.high, "Deletes \(raw) and everything in it, recursively.")
                    }
                }
            }
        }
        if let m = psRemove.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) {
            let rest = ns.substring(with: m.range(at: 1))
            let lower = rest.lowercased()
            let recursive = lower.contains("-recurse") || lower.contains("-r ") || lower.hasSuffix("-r") || lower.contains("/s")
            guard recursive else { return nil }
            var tokens = rest.split(whereSeparator: { $0 == " " || $0 == ";" || $0 == "|" }).map(String.init)
            if let i = tokens.firstIndex(where: { ["-path", "-literalpath"].contains($0.lowercased()) }), i + 1 < tokens.count {
                tokens = [tokens[i + 1]]
            }
            for a in tokens where !a.hasPrefix("-") && !a.hasPrefix("/") || a.count > 2 && a.hasPrefix("/") {
                if isBroadPath(a) {
                    return (.high, "Deletes \(a.trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))) and everything in it, recursively.")
                }
            }
        }
        return nil
    }

    // MARK: Text

    /// The findings as plain text for the model and the transcript, e.g.
    /// "- line 4 [high] Downloads and runs code: curl … | sh".
    public static func summary(_ findings: [Finding]) -> String {
        guard !findings.isEmpty else { return String(localized: "The offline scan found none of the usual risky patterns (that is not proof the script is safe).") }
        return findings.map { f in
            "- " + String(localized: "line \(f.line)") + (f.severity == .high ? " [" + String(localized: "high") + "]" : "")
                + " \(f.category.title): `\(f.snippet)` — \(f.why)"
        }.joined(separator: "\n")
    }
}
