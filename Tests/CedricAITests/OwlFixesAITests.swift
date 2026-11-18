import Foundation
import Testing
@testable import CedricAI
import CedricCore

/// Build 7 owl test pass: the AI parser and verifier findings (F-M4, F-M5).
@Suite struct OwlFixesAITests {
    func json(_ hints: [[String: Any]]) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: ["hints": hints]), encoding: .utf8)!
    }

    func fix(_ find: String, _ replacement: String, line: Int = 1, title: String = "Spelling") -> [String: Any] {
        ["kind": "fix", "category": "other", "title": title, "detail": "d", "line": line,
         "find": find, "replacement": replacement, "confidence": 0.9]
    }

    static let email = "Hi Sam,\ntheir are two options and I couldnt decide.\nIt is definately the best.\n"

    // F-M4: a one-word (or two-word) prose fix keeps its Fix it.
    @Test func oneWordProseFixesKeepFixIt() {
        for (find, rep, line) in [("their are", "there are", 2), ("couldnt", "couldn't", 2), ("definately", "definitely", 3)] {
            let h = HintPrompt.parse(json([fix(find, rep, line: line)]), text: Self.email, source: "s", language: "plain")
            #expect(h.count == 1, "\(find)")
            #expect(h.first?.replacement == rep, "\(find)")
            #expect(h.first.flatMap { $0.range.map { (Self.email as NSString).substring(with: $0) } } == find)
        }
        // Still dropped: an unrelated word, and code that isn't a respelling.
        let wild = HintPrompt.parse(json([fix("definately", "banana", line: 3)]), text: Self.email, source: "s", language: "plain")
        #expect(wild.count == 1 && wild[0].replacement == nil)
        let js = "if (value == 0) {\n  return true;\n}\n"
        let code = HintPrompt.parse(json([fix("if (value == 0)", "return value === 0")]), text: js, source: "s", language: "javascript")
        #expect(code.count == 1 && code[0].replacement == nil)
        let ident = HintPrompt.parse(json([fix("value", "valve")]), text: js, source: "s", language: "javascript")
        #expect(ident.first?.replacement == nil) // code identifiers aren't prose respellings
    }

    // F-M5: `db` used on the right of `=` is not declared there.
    @Test func useOnTheRightIsNotADeclaration() {
        let app = "const express = require('express');\nconst app = express();\n\napp.get('/u/:id', async (req, res) => {\n  const user = await db.find(req.params.id);\n  res.json(user);\n});\n"
        #expect(!HintVerifier.isDeclared("db", in: app))
        let hint: [String: Any] = ["kind": "warning", "category": "undefined", "title": "`db` is not defined",
                                   "detail": "The variable `db` is used but never declared or imported.", "line": 5,
                                   "find": "db.find", "replacement": "", "confidence": 0.9]
        #expect(HintPrompt.parse(json([hint]), text: app, source: "s", language: "javascript").count == 1)
        // Real declarations still count.
        for decl in ["const db = connect();", "let db;", "var a = 1, db = 2;", "const { db, cache } = deps;",
                     "const [db] = pool;", "import db from './db';", "import { db } from './db';",
                     "function load(db, id) {}", "async (db) => db.close()", "from storage import db",
                     "import db", "def run(db):", "func open(db: Database) {}", "let db: Database = .shared",
                     "class db {}", "for (const db of dbs) {}", "db = connect()"] {
            #expect(HintVerifier.isDeclared("db", in: decl), "\(decl)")
        }
        for use in ["const user = await db.find(id);", "let x = db;", "var rows = query(db, sql);",
                    "const total = items.length + db.count;", "import { other } from './db';"] {
            #expect(!HintVerifier.isDeclared("db", in: use), "\(use)")
        }
    }
}
