import Foundation

/// Pack 7: safety help. A downloaded script gets the offer to check it for
/// risks (the offline scan in `ScriptSafety`, then the AI's review when
/// Ask Cedric is on): a quiet tip, once per file (the app remembers the
/// files it offered it for, `OwlDocumentFacts.isQuarantined`).
public enum SafetyRules {
    public static let downloadedScriptID = "rules.downloaded-script"

    static let downloadedScript = LintRule(downloadedScriptID, applies: { l, _ in Language(rawValue: l).map(ScriptSafety.isScript) ?? false }) { input in
        guard input.facts.isQuarantined else { return nil }
        return LintFinding(kind: .tip, title: String(localized: "This script came from the internet. Check it for risks?"),
                           detail: String(localized: "Check Script for Risks looks for downloads that run, encoded commands, deletes and other risky lines, offline, before you run it."))
    }
}
