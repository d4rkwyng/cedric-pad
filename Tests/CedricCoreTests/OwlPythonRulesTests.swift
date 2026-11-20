import Foundation
import Testing
@testable import CedricCore

/// Pack 2: Python. Fires, near misses (strings, comments, docstrings), fix.
@Suite struct OwlPythonRulesTests {
    func find(_ id: String, _ text: String, facts: OwlDocumentFacts = OwlDocumentFacts()) -> OwlHint? {
        OwlLanguageRulesTests.check(text, language: "python", fileName: "a.py", facts: facts).first { $0.id == id }
    }

    func apply(_ h: OwlHint, to text: String) -> String {
        (text as NSString).replacingCharacters(in: h.range!, with: h.replacement!)
    }

    @Test func invalidEscapesBecomeRawStrings() throws {
        let text = "import re\nNUM = re.compile(\"\\d+\")\nPATH = 'C:\\temp\\new\\d'\nB = b'\\d'\n"
        let h = try #require(find(PythonRules.escapeID, text))
        #expect(h.kind == .fix && h.title.contains("\\d"))
        // Only invalid escapes: raw. A real escape too (\n): the bad backslashes doubled.
        #expect(apply(h, to: text) == "import re\nNUM = re.compile(r\"\\d+\")\nPATH = 'C:\\temp\\new\\\\d'\nB = rb'\\d'\n")
        let f = "msg = f\"\\w{x}\"\n"
        #expect(apply(try #require(find(PythonRules.escapeID, f)), to: f) == "msg = rf\"\\w{x}\"\n")
        let u = "s = u\"\\d\"\n"   // `ur` isn't valid Python 3: doubled instead
        #expect(apply(try #require(find(PythonRules.escapeID, u)), to: u) == "s = u\"\\\\d\"\n")
        for t in ["re.compile(r\"\\d+\")\n", "s = \"a\\nb\\t\\\\c\\x41\\u00e9\\N{DASH}\\0\"\n", "s = \"\\\\d\"\n", "b = b\"\\x00\"\n",
                  "# re.compile(\"\\d\")\n", "def f():\n    \"\"\"Matches \\d digits.\"\"\"\n", "s = 'it\\'s'\n", "s = \"a\\\nb\"\n"] {
            #expect(find(PythonRules.escapeID, t) == nil, "\(t)")
        }
        // A string cut off by the end of the text, after a backslash: no crash.
        for t in ["s = \"abc\\", "s = 'x\\d", "\"\\"] { _ = find(PythonRules.escapeID, t) }
    }

    @Test func mutableDefaultArguments() throws {
        let text = "def add(item, into=[]):\n    into.append(item)\n    return into\n"
        let h = try #require(find(PythonRules.mutableDefaultID, text))
        #expect(h.kind == .warning && h.replacement == nil)
        #expect((text as NSString).substring(with: h.range!) == "[]")
        let call = "async def f(a, *, opts: dict = dict(), b=1):\n    pass\n"
        #expect((call as NSString).substring(with: try #require(find(PythonRules.mutableDefaultID, call)).range!) == "dict()")
        #expect(find(PythonRules.mutableDefaultID, "def f(x={'a': 1}):\n    pass\n") != nil)
        #expect(OwlLanguageRulesTests.check("def f(x=[]) -> int: ...\n", language: "python", fileName: "a.pyi").allSatisfy { $0.id != PythonRules.mutableDefaultID })
        for t in ["def f(x=None):\n    x = x or []\n", "def f(x=()):\n    pass\n", "def f(x=frozenset()):\n    pass\n",
                  "def f(x=1) -> List[int]:\n    return [x]\n", "# def f(x=[]):\n", "s = \"def f(x=[]):\"\n", "f(x=[])\n",
                  "def f(x=len([])):\n    pass\n", "def f(a, b=a == []):\n    pass\n"] {
            #expect(find(PythonRules.mutableDefaultID, t) == nil, "\(t)")
        }
    }

    @Test func noneComparedWithIs() throws {
        let text = "if x == None:\n    pass\nwhile None != y and z:\n    pass\n"
        let h = try #require(find(PythonRules.noneCompareID, text))
        #expect(apply(h, to: text) == "if x is None:\n    pass\nwhile None is not y and z:\n    pass\n")
        #expect(find(PythonRules.noneCompareID, "if (x == None) or y:\n    pass\n") != nil)
        // SQLAlchemy / pandas compare elementwise inside calls and subscripts.
        for t in ["q.filter(User.name == None)\n", "df[df.a == None]\n", "q.filter(\n    User.name == None,\n)\n",
                  "if x is None:\n    pass\n", "# if x == None\n", "s = \"x == None\"\n", "x = None\n", "d = {'a': x == None}\n"] {
            #expect(find(PythonRules.noneCompareID, t) == nil, "\(t)")
        }
    }

    @Test func isWithALiteral() throws {
        let text = "if x is \"a\" or y is not 0:\n    pass\nif 'b' is z:\n    pass\n"
        let h = try #require(find(PythonRules.isLiteralID, text))
        #expect(apply(h, to: text) == "if x == \"a\" or y != 0:\n    pass\nif 'b' == z:\n    pass\n")
        for t in ["if x is None:\n    pass\n", "if x is True:\n    pass\n", "if a is b:\n    pass\n", "# x is 'a'\n",
                  "s = \"this is 'a' test\"\n", "x2 is y\n", "if t is ():\n    pass\n"] {
            #expect(find(PythonRules.isLiteralID, t) == nil, "\(t)")
        }
    }

    @Test func python2Print() throws {
        let text = "print \"hello\"\nfor i in x:\n    print i,\nprint >>sys.stderr, \"oops\" # note\n"
        let h = try #require(find(PythonRules.printID, text))
        #expect(h.kind == .fix)
        #expect(apply(h, to: text) == "print(\"hello\")\nfor i in x:\n    print(i, end=\" \")\nprint(\"oops\", file=sys.stderr) # note\n")
        // A print that can't be rewritten on its own line: a warning with Show Me.
        let multi = "print \"a\", (1,\n    2)\n"
        let w = try #require(find(PythonRules.printID, multi))
        #expect(w.kind == .warning && w.replacement == nil && w.range != nil)
        for t in ["print(\"hello\")\n", "print (\"x\")\n", "print = logger.info\n", "# print \"x\"\n", "s = \"\"\"\nprint \"x\"\n\"\"\"\n",
                  "x = [\n    print \"a\"\n]\n", "print\n", "print in names\n"] {
            #expect(find(PythonRules.printID, t) == nil, "\(t)")
        }
    }
}
