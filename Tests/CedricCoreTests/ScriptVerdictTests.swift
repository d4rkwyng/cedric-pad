import Foundation
import Testing
@testable import CedricCore

/// The script check's verdict, clamped in code: never "safe", and "Don't
/// run it" after a high finding or a partial review.
@Suite struct ScriptVerdictTests {
    @Test func aSafeVerdictBecomesNoRedFlags() {
        #expect(ScriptVerdict.clamp("Nothing risky.\nVerdict: safe to run.") == "Nothing risky.\nVerdict: No obvious red flags (not a guarantee).")
        #expect(ScriptVerdict.clamp("**Verdict:** Safe.") == "Verdict: No obvious red flags (not a guarantee).")
        #expect(ScriptVerdict.clamp("Line 2 downloads a file.\nThe script IS SAFE") == "Line 2 downloads a file.\nNo obvious red flags (not a guarantee).")
    }

    @Test func aSafeClaimAnywhereIsRewritten() {
        let a = ScriptVerdict.clamp("This script is completely safe to run.\nLine 4 prints.\nVerdict: Run only if you trust the source.")
        #expect(a.range(of: "safe", options: .caseInsensitive) == nil)
        #expect(a.hasSuffix("Verdict: Run only if you trust the source."))
        // "safe" as a word only in the verdict and final lines.
        #expect(ScriptVerdict.clamp("It writes to a safe temp folder.\nVerdict: Don't run it.") == "It writes to a safe temp folder.\nVerdict: Don't run it.")
    }

    @Test func warningsAreLeftAlone() {
        let warn = "Line 3 is not safe: it pipes curl into bash.\nVerdict: Don't run it — it isn't safe."
        #expect(ScriptVerdict.clamp(warn) == warn)
        #expect(ScriptVerdict.clamp("Verdict: Don't run it.") == "Verdict: Don't run it.")
        // "Safe" next to "don't run": the warning wins, the claim goes.
        #expect(ScriptVerdict.clamp("Verdict: safe to run, but don't run it as root.") == "Verdict: Don't run it.")
    }

    @Test func aHighFindingForcesDontRun() {
        let a = ScriptVerdict.clamp("Looks fine.\nVerdict: safe to run.", forced: .highFinding)
        #expect(a.hasSuffix("Verdict: Don't run it — review the flagged lines."))
        #expect(a.range(of: "safe to run", options: .caseInsensitive) == nil)
        #expect(a.components(separatedBy: "\n").filter { ScriptVerdict.isVerdictLine($0) }.count == 1, "one verdict, the forced one")
        #expect(a.contains(ScriptVerdict.Reason.highFinding.note))
    }

    @Test func truncationForcesDontRun() {
        let a = ScriptVerdict.clamp("No obvious problems.\nVerdict: No obvious red flags (not a guarantee).", forced: .truncated)
        #expect(a.hasSuffix("Verdict: " + ScriptVerdict.forcedDontRun + "."))
        #expect(!a.contains(ScriptVerdict.noRedFlags), "no reassuring verdict when part of the script wasn't read")
        #expect(ScriptVerdict.forcedReason(scanHasHigh: false, truncated: true) == .truncated)
        #expect(ScriptVerdict.forcedReason(scanHasHigh: true, truncated: true) == .highFinding)
        #expect(ScriptVerdict.forcedReason(scanHasHigh: false, truncated: false) == nil)
    }
}
