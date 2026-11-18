import Foundation
import Testing
@testable import CedricCore

/// Real-world CSV shapes: the sniffed dialect and the grid it gives.
struct CSVSample: Sendable, CustomTestStringConvertible {
    let name: String
    let text: String
    var fileName: String? = nil
    let delimiter: Character
    var skipSpace: Bool? = nil
    let rows: [[String]]
    var testDescription: String { name }
}

private let csvSamples: [CSVSample] = [
    CSVSample(name: "plain comma", text: "name,age,city\nAlice,30,Paris\nBob,25,Rome\n", delimiter: ",", skipSpace: false,
              rows: [["name", "age", "city"], ["Alice", "30", "Paris"], ["Bob", "25", "Rome"]]),
    CSVSample(name: "comma then space", text: "name, age, city\nAlice, 30, Paris\nBob, 25, Rome\n", delimiter: ",", skipSpace: true,
              rows: [["name", "age", "city"], ["Alice", "30", "Paris"], ["Bob", "25", "Rome"]]),
    CSVSample(name: "comma-space, header without spaces", text: "name,age,city\nAlice, 30, Paris\nBob, 25, Rome\nCy, 1, Oslo\n",
              delimiter: ",", skipSpace: true,
              rows: [["name", "age", "city"], ["Alice", "30", "Paris"], ["Bob", "25", "Rome"], ["Cy", "1", "Oslo"]]),
    CSVSample(name: "quoted field first, then space", text: "\"a, b\", c\n\"d\", e\n", delimiter: ",", skipSpace: true,
              rows: [["a, b", "c"], ["d", "e"]]),
    CSVSample(name: "space then quoted field", text: "id, note, n\n1, \"a, b\", 2\n2, \"x \"\"y\"\"\", 3\n", delimiter: ",", skipSpace: true,
              rows: [["id", "note", "n"], ["1", "a, b", "2"], ["2", "x \"y\"", "3"]]),
    CSVSample(name: "spaces kept inside quotes", text: "a, b\n\"  lead\", \" trail  \"\n", delimiter: ",", skipSpace: true,
              rows: [["a", "b"], ["  lead", " trail  "]]),
    CSVSample(name: "several spaces after the comma", text: "a,   b,  c\n1,   2,  3\n", delimiter: ",", skipSpace: true,
              rows: [["a", "b", "c"], ["1", "2", "3"]]),
    CSVSample(name: "an odd space in plain CSV is data", text: "a,b,c\n1,2,3\n4, x,6\n5,6,7\n7,8,9\n", delimiter: ",", skipSpace: false,
              rows: [["a", "b", "c"], ["1", "2", "3"], ["4", " x", "6"], ["5", "6", "7"], ["7", "8", "9"]]),
    CSVSample(name: "TSV spaces are data", text: "a\t b\n 1\t2 \n", delimiter: "\t", skipSpace: false,
              rows: [["a", " b"], [" 1", "2 "]]),
    CSVSample(name: "TSV by extension with commas inside", text: "a, b\tc\n1, 2\t3\n", fileName: "x.tsv", delimiter: "\t", skipSpace: false,
              rows: [["a, b", "c"], ["1, 2", "3"]]),
    CSVSample(name: "semicolon with decimal commas", text: "1,5;2,3\n4,1;7,8\n0,5;9,9\n", delimiter: ";",
              rows: [["1,5", "2,3"], ["4,1", "7,8"], ["0,5", "9,9"]]),
    CSVSample(name: "semicolon header and decimals", text: "Artikel;Preis;Menge\nApfel;1,20;3\nBirne;0,80;12\n", delimiter: ";",
              rows: [["Artikel", "Preis", "Menge"], ["Apfel", "1,20", "3"], ["Birne", "0,80", "12"]]),
    CSVSample(name: "all-number comma CSV stays comma", text: "1,2,3\n4,5,6\n", delimiter: ",",
              rows: [["1", "2", "3"], ["4", "5", "6"]]),
    CSVSample(name: "pipe separated", text: "a|b|c\n1|2|3\n", delimiter: "|", rows: [["a", "b", "c"], ["1", "2", "3"]]),
    CSVSample(name: "pipe table with rule row", text: "| name | qty |\n|------|----:|\n| nut  |   4 |\n| bolt |  10 |\n", delimiter: "|",
              rows: [["name", "qty"], ["nut", "4"], ["bolt", "10"]]),
    CSVSample(name: "single column", text: "word\napple\npear\n", delimiter: ",", rows: [["word"], ["apple"], ["pear"]]),
    CSVSample(name: "header only", text: "id;name;email\n", delimiter: ";", rows: [["id", "name", "email"]]),
    CSVSample(name: "header only, no newline", text: "id,name", delimiter: ",", rows: [["id", "name"]]),
    CSVSample(name: "CRLF", text: "a, b\r\n1, 2\r\n", delimiter: ",", skipSpace: true, rows: [["a", "b"], ["1", "2"]]),
    CSVSample(name: "byte-order mark", text: "\u{FEFF}name;age\nAl;3\n", delimiter: ";", rows: [["name", "age"], ["Al", "3"]]),
    CSVSample(name: "trailing delimiter", text: "a,b,\n1,2,\n", delimiter: ",", rows: [["a", "b", ""], ["1", "2", ""]]),
    CSVSample(name: "blank lines, leading and between", text: "\n\na;b\n\n1;2\n   \n3;4\n", delimiter: ";",
              rows: [["a", "b"], ["1", "2"], ["3", "4"]]),
    CSVSample(name: "ragged rows", text: "a,b,c\n1,2\n1,2,3\n1,2,3,4\n1,2,3\n", delimiter: ",",
              rows: [["a", "b", "c"], ["1", "2"], ["1", "2", "3"], ["1", "2", "3", "4"], ["1", "2", "3"]]),
    CSVSample(name: "quoted newlines", text: "id,text\n1,\"line one\nline two, still\"\n2,x\n", delimiter: ",",
              rows: [["id", "text"], ["1", "line one\nline two, still"], ["2", "x"]]),
    CSVSample(name: "Excel sep= hint", text: "sep=;\na;b,c\n1;2,5\n", delimiter: ";", rows: [["a", "b,c"], ["1", "2,5"]]),
    CSVSample(name: "Excel sep= hint, CRLF, pipe", text: "sep=|\r\nx|y\r\n", delimiter: "|", rows: [["x", "y"]]),
    CSVSample(name: "semicolons inside quoted text", text: "id,quote\n1,\"a; b; c; d\"\n2,\"e; f; g; h\"\n", delimiter: ",",
              rows: [["id", "quote"], ["1", "a; b; c; d"], ["2", "e; f; g; h"]]),
    CSVSample(name: "commas inside quoted text, semicolon file", text: "\"Smith, J\";\"Paris, FR\"\n\"Doe, A\";\"Rome, IT\"\n", delimiter: ";",
              rows: [["Smith, J", "Paris, FR"], ["Doe, A", "Rome, IT"]]),
    CSVSample(name: "inch marks in unquoted fields", text: "item,size\nfloppy,5\" disk\nzip,3\" x\n", delimiter: ",",
              rows: [["item", "size"], ["floppy", "5\" disk"], ["zip", "3\" x"]]),
    CSVSample(name: "tab sniffed without extension", text: "a\tb\tc\n1\t2\t3\n", delimiter: "\t", rows: [["a", "b", "c"], ["1", "2", "3"]]),
    CSVSample(name: "prose with one comma per line in a TSV-like file", text: "k\tv\nx\tHello, world\ny\tBye, all\n", delimiter: "\t",
              rows: [["k", "v"], ["x", "Hello, world"], ["y", "Bye, all"]]),
    CSVSample(name: "empty fields with comma-space", text: "a, b, c\n1, , 3\n, 2, \n", delimiter: ",", skipSpace: true,
              rows: [["a", "b", "c"], ["1", "", "3"], ["", "2", ""]]),
]

@Suite struct CSVDialectTests {
    @Test(arguments: csvSamples) func sample(_ s: CSVSample) {
        let text = s.text as NSString
        let d = CSV.dialect(for: text, fileName: s.fileName)
        #expect(d.delimiter == s.delimiter.utf16.first!, "delimiter")
        if let skip = s.skipSpace { #expect(d.skipInitialSpace == skip, "skipInitialSpace") }
        #expect(CSV.parse(text, dialect: d).rows == s.rows)
    }

    @Test func veryWideRow() {
        let header = (0..<3000).map { "c\($0)" }.joined(separator: ", ")
        let row = (0..<3000).map { "\($0)" }.joined(separator: ", ")
        let text = (header + "\n" + row + "\n") as NSString
        let d = CSV.dialect(for: text)
        #expect(d.delimiter == 44 && d.skipInitialSpace)
        let t = CSV.parse(text, dialect: d)
        #expect(t.columnCount == 3000)
        #expect(t.rows[1][2999] == "2999")
        // A first line longer than the 64 K the sniffer reads still sniffs.
        let huge = ((0..<20_000).map { "v\($0)" }.joined(separator: ";") + "\n") as NSString
        #expect(CSV.delimiter(for: huge) == 59)
    }

    @Test func fieldOffsetFollowsTheDialect() {
        let text = "id, note\n1, \"a, b\", z\n" as NSString
        let d = CSV.dialect(for: text)
        let t = CSV.parse(text, dialect: d)
        let r = t.rowStarts[1]
        #expect(CSV.fieldOffset(in: text, rowStart: r, column: 0, dialect: d) == r)
        #expect(CSV.fieldOffset(in: text, rowStart: r, column: 1, dialect: d) == text.range(of: "a, b").location) // inside the quote
        #expect(CSV.fieldOffset(in: text, rowStart: r, column: 2, dialect: d) == text.range(of: "z").location)
        // A pipe table: the grid's first column is the second field.
        let pipe = "| k | v |\n| a | b |\n" as NSString
        let pd = CSV.dialect(for: pipe)
        #expect(pd.edgeDelimiters)
        #expect(CSV.fieldOffset(in: pipe, rowStart: 10, column: 0, dialect: pd) == 12)
        #expect(CSV.fieldOffset(in: pipe, rowStart: 10, column: 1, dialect: pd) == 16)
        // sep= hint: the records start after it.
        let sep = "sep=;\na;b\n" as NSString
        #expect(CSV.parse(sep, dialect: CSV.dialect(for: sep)).rowStarts == [6])
        #expect(CSV.parse(sep, dialect: CSV.dialect(for: sep)).rowLines == [1])
    }
}
