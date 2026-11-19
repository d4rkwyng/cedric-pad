import Foundation
import Testing
@testable import CedricCore

/// Pack 6: SQL and PowerShell. The SQL lexer, fires, near misses, fix.
@Suite struct OwlSQLPowerShellRulesTests {
    func find(_ id: String, _ text: String, language: String = "sql", facts: OwlDocumentFacts = OwlDocumentFacts()) -> OwlHint? {
        OwlLanguageRulesTests.check(text, language: language, fileName: language == "sql" ? "a.sql" : "a.ps1", facts: facts).first { $0.id == id }
    }

    func apply(_ h: OwlHint, to text: String) -> String {
        (text as NSString).replacingCharacters(in: h.range!, with: h.replacement!)
    }

    @Test func sqlMaskKnowsStringsCommentsAndDollarBodies() throws {
        let sql = "SELECT 'it''s = NULL', \"a b\" -- x = NULL\nFROM t /* = NULL */ WHERE y = $$ = NULL $$ AND z = $1;\n"
        let m = try #require(CodeMask.make(sql as NSString, language: "sql"))
        #expect(!m.code.contains("= NULL") && m.code.contains("AND z = $1"))
        // A window that starts inside a block comment.
        let w = try #require(CodeMask.make(" WHERE a = NULL */\nSELECT 1;\n" as NSString, language: "sql", window: true))
        #expect(!w.code.contains("= NULL") && w.code.contains("SELECT 1"))
        // MySQL's backslash escape.
        let b = try #require(CodeMask.make("SELECT 'O\\'Brien = NULL' FROM t;\n" as NSString, language: "sql"))
        #expect(!b.code.contains("NULL") && b.code.contains("FROM t"))
    }

    @Test func sqlEqualsNull() throws {
        let text = "SELECT * FROM t WHERE a = NULL AND b <> NULL;\nselect * from u where c != null;\n"
        let h = try #require(find(DataRules.sqlNullID, text))
        #expect(h.kind == .fix && h.title.contains("IS NULL"))
        #expect(apply(h, to: text) == "SELECT * FROM t WHERE a IS NULL AND b IS NOT NULL;\nselect * from u where c is not null;\n")
        #expect(find(DataRules.sqlNullID, "SELECT CASE WHEN x = NULL THEN 1 END FROM t;\n") != nil)
        #expect(find(DataRules.sqlNullID, "SELECT * FROM a JOIN b ON a.id = NULL;\n") != nil)
        for t in ["UPDATE t SET a = NULL, b = NULL WHERE id = 1;\n",            // assignment
                  "SELECT * FROM t WHERE a IS NULL;\n",
                  "SELECT 'x = NULL' FROM t WHERE a = 1; -- where b = NULL\n",  // string, comment
                  "CREATE PROCEDURE p @a INT = NULL, @b INT = NULL AS SELECT 1;\n",  // defaults
                  "DECLARE @x INT = NULL;\nSELECT @y = NULL;\n",              // T-SQL assignment
                  "CREATE TABLE t (a INT DEFAULT NULL);\n",
                  "CREATE PROCEDURE p\n  @a [tinyint] NOT NULL = 1,\n  @b [nvarchar](25) = NULL\nAS SELECT 1;\n",  // NOT NULL is a constraint
                  "SET ANSI_NULLS OFF;\nSELECT * FROM t WHERE a = NULL;\n",   // = NULL works then
                  "SELECT * FROM t WHERE a <=> NULL;\n", "x := NULL;\n"] {
            #expect(find(DataRules.sqlNullID, t) == nil, "\(t)")
        }
    }

    @Test func sqlUpdateOrDeleteWithoutWhere() throws {
        let text = "BEGIN;\nDELETE FROM sessions;\nUPDATE users SET active = 0 WHERE id = 3;\nUPDATE users\n  SET plan = 'free';\n"
        let h = try #require(find(DataRules.sqlNoWhereID, text))
        #expect(h.kind == .warning && h.replacement == nil && h.title.hasPrefix("DELETE"))
        #expect((text as NSString).substring(with: h.range!) == "DELETE FROM sessions;")
        #expect(h.detail!.contains("(and 1 more)"))
        // T-SQL batches end at GO; the last statement of the whole file needs no ;.
        #expect(find(DataRules.sqlNoWhereID, "UPDATE t SET a = 1\nGO\n") != nil)
        #expect(find(DataRules.sqlNoWhereID, "delete from t") != nil)
        for t in ["DELETE FROM t WHERE id = 1;\n", "UPDATE t SET a = 1\nWHERE b = 2;\n",
                  "-- DELETE FROM t;\nSELECT 'UPDATE t SET a = 1;';\n",
                  "UPDATE t SET a = 1 FROM t JOIN u ON u.id = t.id;\n", "DELETE FROM t LIMIT 1;\n",
                  "UPDATE STATISTICS dbo.t;\n", "CREATE TRIGGER x BEFORE UPDATE ON t FOR EACH ROW SET NEW.a = 1;\n",
                  "GRANT UPDATE, DELETE ON t TO bob;\n", "ALTER TABLE t ADD FOREIGN KEY (a) REFERENCES u ON DELETE CASCADE;\n",
                  "WITH x AS (SELECT 1) DELETE FROM t;\n", "DELETE FROM t WHERE CURRENT OF c;\n"] {
            #expect(find(DataRules.sqlNoWhereID, t) == nil, "\(t)")
        }
        // A window: an unterminated last statement may go on below; a first one may have started above.
        let win = OwlDocumentFacts(isWholeDocument: false)
        #expect(find(DataRules.sqlNoWhereID, "SELECT 1;\nDELETE FROM t\n", facts: win) == nil)
    }

    @Test func powerShellRedirectionInACondition() throws {
        let text = "if ($a > 5) { 'big' }\nwhile ($i >= $max -and $ok) { $i-- }\nelseif ($x.Count > 0) {}\n"
        let h = try #require(find(PowerShellRules.redirectID, text, language: "powershell"))
        #expect(h.kind == .fix && h.title.contains("-gt"))
        #expect(apply(h, to: text) == "if ($a -gt 5) { 'big' }\nwhile ($i -ge $max -and $ok) { $i-- }\nelseif ($x.Count -gt 0) {}\n")
        for t in ["if ($a -gt 5) {}\n", "if ((Get-Thing 2>$null) -eq 1) {}\n", "if ($a > $null) {}\n",
                  "# if ($a > 5)\n", "Write-Host 'if ($a > 5)'\n", "$a > 5\n", "if ($a 2> 5) {}\n",
                  "if (Test-Path $p) { Get-Item $p > out.txt }\n", "if ($(cmd > $f; $?)) {}\n",
                  "<#\nif ($a > 5) {}\n#>\n", "$s = @'\nif ($a > 5) {}\n'@\n"] {
            #expect(find(PowerShellRules.redirectID, t, language: "powershell") == nil, "\(t)")
        }
    }

    @Test func powerShellBacktickFollowedBySpace() throws {
        let text = "Get-ChildItem -Path C:\\ ` \n    -Recurse `\t\n    -File\n"
        let h = try #require(find(PowerShellRules.backtickID, text, language: "powershell"))
        #expect(h.kind == .fix)
        #expect(apply(h, to: text) == "Get-ChildItem -Path C:\\ `\n    -Recurse `\n    -File\n")
        for t in ["Get-Item `\n    -Path x\n", "# note ` \nx\n", "$s = 'a ` '\n", "Write-Host \"tick `` \"\n",
                  "$x = \"``\" \n", "$h = @\"\nline ` \n\"@\n", "Write-Host a `` \n"] {
            #expect(find(PowerShellRules.backtickID, t, language: "powershell") == nil, "\(t)")
        }
    }
}
