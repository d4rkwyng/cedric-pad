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
        // A verdict at the end of a paragraph (real Qwen3 output) is replaced too.
        let inline = ScriptVerdict.clamp("Line 3 runs remote code. No other risks. Verdict: Don't run it", forced: .highFinding)
        #expect(inline == "Line 3 runs remote code. No other risks.\n" + ScriptVerdict.Reason.highFinding.note + "\nVerdict: " + ScriptVerdict.forcedDontRun + ".")
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

/// ScriptVerdictStream: char by char, never a safe claim or (forced) a model verdict.
@Suite struct ScriptVerdictStreamTests {
    @Test func everyPrefixIsClamped() {
        let answer = "It looks fine.\nVerdict: safe to run.\n"
        var s = ScriptVerdictStream(forced: nil)
        for c in answer {
            let shown = s.append(String(c))
            #expect(shown.range(of: "safe to run", options: .caseInsensitive) == nil, "\(shown)")
            #expect(!shown.lowercased().hasSuffix("verdict: safe"), "\(shown)")
        }
        #expect(s.display == ScriptVerdict.clamp(answer))
    }

    @Test func forcedHidesPartialVerdicts() {
        var s = ScriptVerdictStream(forced: .truncated)
        #expect(s.display == ScriptVerdict.Reason.truncated.note + "\nVerdict: " + ScriptVerdict.forcedDontRun + ".")
        for c in "Line 2 is fine. Verd" { s.append(String(c)) }
        #expect(s.display.hasPrefix("Line 2 is fine.\n"), "a partial \"Verd\" doesn't show: \(s.display)")
        for c in "ict: No obvious red flags\nMore." { s.append(String(c)) }
        #expect(!s.display.contains(ScriptVerdict.noRedFlags))
        #expect(s.display.hasSuffix("Verdict: " + ScriptVerdict.forcedDontRun + "."))
    }

    @Test func longAnswersStayCheap() {
        // Finished lines are clamped once: 5,000 lines streamed a line at a time.
        var s = ScriptVerdictStream(forced: nil)
        let clock = ContinuousClock()
        let took = clock.measure { for i in 0..<5_000 { s.append("line \(i) does a thing\n") } }
        #expect(took < .seconds(2), "\(took)")
        #expect(s.display.hasPrefix("line 0 does a thing\nline 1"))
    }
}
