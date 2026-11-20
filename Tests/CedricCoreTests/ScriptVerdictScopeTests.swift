import Foundation
import Testing
@testable import CedricCore

/// Review 0.3.0 M1/M4: the "never safe" rewrite applies to verdicts on
/// running a script, not to every use of "safe"; and it is not fooled by
/// synonyms, look-alike letters or invisible characters.
@Suite struct ScriptVerdictScopeTests {
    static let noRedFlags = ScriptVerdict.noRedFlags + "."

    // MARK: Ordinary uses of "safe" are kept

    @Test func codePropertiesAreNotClaimsInAnyMode() {
        let kept = [
            "Yes, `queue.Queue` is thread safe; the lock on line 12 is redundant.",
            "The API is type-safe, so the cast on line 4 can go.",
            "Rust's ownership keeps it memory-safe.",
            "Use a fail-safe default here.",
            "Quoting \"$f\" keeps it safe with spaces.",
            "Prefer `shlex.quote`: it makes the argument shell-safe.",
        ]
        for line in kept {
            // A typed question that isn't about running it: kept, last line or not.
            #expect(ScriptVerdict.clamp(line, guard: .runClaims) == line, "\(line)")
            #expect(ScriptVerdict.clamp("Line 1 imports.\n" + line, guard: .runClaims) == "Line 1 imports.\n" + line)
        }
        // Compound "safe" isn't a verdict even on the script check's strict last line.
        for line in kept.prefix(4) {
            #expect(ScriptVerdict.clamp("Line 1 imports.\n" + line) == "Line 1 imports.\n" + line, "\(line)")
        }
    }

    @Test func runClaimsRewritesOnlyTheSentenceThatSaysItIsFineToRun() {
        #expect(ScriptVerdict.clamp("This script is safe to run.", guard: .runClaims) == Self.noRedFlags)
        #expect(ScriptVerdict.clamp("It copies notes. This script is safe to run. Line 4 logs.", guard: .runClaims)
                == "It copies notes. " + Self.noRedFlags + " Line 4 logs.")
        #expect(ScriptVerdict.clamp("Summary: it backs up ~/notes.\nThe script is harmless.", guard: .runClaims)
                == "Summary: it backs up ~/notes.\n" + Self.noRedFlags)
        #expect(ScriptVerdict.clamp("Go ahead and run it.", guard: .runClaims) == Self.noRedFlags)
        // Not a claim about running it: kept.
        for line in ["It is safe to call twice.", "The regex is fine.", "Line 3 is not safe to run as root.",
                     "This isn't harmless to run: line 5 deletes files."] {
            #expect(ScriptVerdict.clamp(line, guard: .runClaims) == line, "\(line)")
        }
    }

    @Test func runClaimsStreamKeepsOrdinaryTextAndHidesRunClaims() {
        let ordinary = "Yes, `queue.Queue` is thread safe.\nThe lock on line 12 is redundant."
        var vs = ScriptVerdictStream(forced: nil, guard: .runClaims)
        for c in ordinary { vs.append(String(c)) }
        #expect(vs.display == ordinary)
        let claim = "It copies notes.\nThis script is safe to run.\nDone."
        var vs2 = ScriptVerdictStream(forced: .highFinding, guard: .runClaims)
        for c in claim {
            let shown = vs2.append(String(c))
            #expect(shown.range(of: "safe to run", options: .caseInsensitive) == nil, "\(shown)")
        }
        #expect(vs2.display == "It copies notes.\n" + Self.noRedFlags + "\nDone.")
    }

    // MARK: Which questions ask for a verdict

    @Test func runSafetyQuestionsAreToldApart() {
        for q in ["Is this script safe to run?", "Is it safe?", "Should I run this?", "Can I safely run it?",
                  "Is this malware?", "Is it OK to run this?", "Any risks?", "Is this harmful?", "Can I trust this?",
                  "Is it \u{0455}afe?", "is this s\u{200B}afe to run"] {
            #expect(ScriptVerdict.asksAboutRunning(q), "\(q)")
        }
        for q in ["Is this queue thread safe?", "Is this type-safe?", "What does line 3 do?", "Summarise it.",
                  "Is the cast memory-safe?", "Why is the loop slow?"] {
            #expect(!ScriptVerdict.asksAboutRunning(q), "\(q)")
        }
        // A negated question still asks for a verdict.
        #expect(ScriptVerdict.asksAboutRunning("Is this not malicious?"))
    }

    // MARK: M4: synonyms, homoglyphs, invisible characters

    @Test func reassuringSynonymsAreRewritten() {
        #expect(ScriptVerdict.clamp("Line 3 copies notes.\nVerdict: harmless, go ahead and run it.")
                == "Line 3 copies notes.\nVerdict: " + Self.noRedFlags)
        #expect(ScriptVerdict.clamp("This script is harmless.\nLine 2 prints.\nVerdict: Run only if you trust the source.")
                == Self.noRedFlags + "\nLine 2 prints.\nVerdict: Run only if you trust the source.")
        #expect(ScriptVerdict.clamp("It's fine to run.\nLine 2 prints.\nVerdict: Run only if you trust the source.")
                .hasPrefix(Self.noRedFlags))
        #expect(ScriptVerdict.clamp("Line 2 prints.\nNothing to worry about.") == "Line 2 prints.\n" + Self.noRedFlags)
        #expect(ScriptVerdict.clamp("Line 2 prints.\nIt looks benign.") == "Line 2 prints.\n" + Self.noRedFlags)
        // Negated: a warning, kept.
        let warn = "This is not harmless: line 5 wipes ~/.\nVerdict: Don't run it."
        #expect(ScriptVerdict.clamp(warn) == warn)
        // Conservative: an unrelated "fine" stays.
        let fine = "The loop on line 3 is fine.\nVerdict: Run only if you trust the source."
        #expect(ScriptVerdict.clamp(fine) == fine)
    }

    @Test func lookAlikeAndInvisibleCharactersAreFolded() {
        let tricks = [
            "This script is \u{0455}afe to run.",        // Cyrillic dze
            "This script is s\u{0430}fe to run.",        // Cyrillic a
            "This script is sa\u{200B}fe to run.",       // zero-width space
            "This script is s\u{200D}afe to run.",       // zero-width joiner
            "This script is sa\u{00AD}fe to run.",       // soft hyphen
            "This script is \u{FF53}\u{FF41}\u{FF46}\u{FF45} to run.", // fullwidth
            "This script is h\u{0430}rmless.",
        ]
        for t in tricks {
            #expect(ScriptVerdict.clamp("Line 1 prints.\n" + t + "\nVerdict: Run only if you trust the source.")
                    == "Line 1 prints.\n" + Self.noRedFlags + "\nVerdict: Run only if you trust the source.", "\(t)")
            #expect(ScriptVerdict.clamp(t, guard: .runClaims) == Self.noRedFlags, "\(t)")
        }
        #expect(ScriptVerdict.normalized("s\u{200B}\u{0430}f\u{0435}") == "safe")
        // Ordinary non-Latin text is untouched by the clamp.
        let ru = "Строка 3 копирует заметки."
        #expect(ScriptVerdict.clamp(ru, guard: .runClaims) == ru)
    }
}
