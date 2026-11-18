import Foundation
import Testing
@testable import CedricCore

@Suite struct LanguageIndentTests {
    let spaces4 = Indentation(usesTabs: false, width: 4)
    let tabs4 = Indentation(usesTabs: true, width: 4)

    @Test func yamlAlwaysSpaces() {
        // Nothing saved, nothing in the file: 2 spaces, and Tab types them.
        #expect(LanguageIndent.resolve(language: .yaml, manual: nil, detected: nil, default: spaces4, defaultSaved: false) == (Indentation(usesTabs: false, width: 2), true))
        // Even with tabs saved as the default, picked for the tab, or in the file.
        #expect(LanguageIndent.resolve(language: .yaml, manual: nil, detected: nil, default: tabs4, defaultSaved: true).tabTypesSpaces)
        #expect(LanguageIndent.resolve(language: .yaml, manual: tabs4, detected: nil, default: tabs4, defaultSaved: true).indentation.usesTabs == false)
        #expect(LanguageIndent.resolve(language: .yaml, manual: nil, detected: tabs4, default: spaces4, defaultSaved: false).indentation.usesTabs == false)
        #expect(LanguageIndent.resolve(language: .yaml, manual: nil, detected: spaces4, default: spaces4, defaultSaved: false) == (spaces4, true))
    }

    @Test func pythonFourSpaces() {
        #expect(LanguageIndent.resolve(language: .python, manual: nil, detected: nil, default: spaces4, defaultSaved: false) == (spaces4, true))
        // A saved tab default, a file indented with tabs, or the tab's own pick win.
        #expect(LanguageIndent.resolve(language: .python, manual: nil, detected: nil, default: tabs4, defaultSaved: true) == (tabs4, false))
        #expect(LanguageIndent.resolve(language: .python, manual: nil, detected: tabs4, default: spaces4, defaultSaved: false) == (tabs4, false))
        #expect(LanguageIndent.resolve(language: .python, manual: tabs4, detected: nil, default: spaces4, defaultSaved: false) == (tabs4, false))
        // Other languages as before: an unsaved default types a tab.
        #expect(LanguageIndent.resolve(language: .swift, manual: nil, detected: nil, default: spaces4, defaultSaved: false) == (spaces4, false))
        #expect(LanguageIndent.resolve(language: .ruby, manual: nil, detected: nil, default: spaces4, defaultSaved: false) == (Indentation(usesTabs: false, width: 2), false))
    }

    @Test func pythonDedentsAfterReturn() {
        func nl(_ s: String) -> String {
            let caret = (s as NSString).range(of: "‸").location
            let t = s.replacingOccurrences(of: "‸", with: "") as NSString
            let start = t.lineRange(for: NSRange(location: caret, length: 0)).location
            return AutoEdit.newline(in: t, lineStart: start, caret: caret, after: caret, language: .python).text
        }
        #expect(nl("def f():\n    return 1‸") == "\n")
        #expect(nl("        pass‸") == "\n    ")
        #expect(nl("    raise ValueError()‸") == "\n")
        #expect(nl("    break‸") == "\n")
        #expect(nl("\t\tcontinue‸") == "\n\t")
        // Not a keyword on its own.
        #expect(nl("    returned = 1‸") == "\n    ")
        #expect(nl("    passes()‸") == "\n    ")
        // Other languages keep the indent.
        let t = "    return 1" as NSString
        #expect(AutoEdit.newline(in: t, lineStart: 0, caret: 12, after: 12, language: .swift).text == "\n    ")
    }

    @Test func pythonClausesLineUp() {
        func c(_ head: String, _ above: String) -> String? {
            LanguageIndent.pythonClauseIndent(head: head, above: above.components(separatedBy: "\n").reversed(), tabWidth: 4)
        }
        #expect(c("    else", "if a:\n    x = 1") == "")
        #expect(c("        elif b", "def f():\n    if a:\n        x = 1") == "    ")
        #expect(c("        except ValueError as e", "try:\n    try:\n        y()\n    except E:\n        pass") == "    ")
        #expect(c("    finally", "try:\n    y()") == "")
        // Already lined up, or nothing to line up with.
        #expect(c("else", "if a:\n    x = 1") == nil)
        #expect(c("    else", "x = 1\n    y = 2") == nil)
        // Not a clause keyword on its own.
        #expect(c("    elsewhere", "if a:\n    x") == nil)
        #expect(c("    else x", "if a:\n    x") == nil)
        // A statement at a lower column ends the if's block first.
        #expect(c("        else", "if a:\n    b = 1\nc = 2\n        d") == nil)
    }
}
