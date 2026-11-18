import Foundation
import Testing
@testable import CedricCore

@Suite struct EncodingTests {
    @Test func utf8() {
        let d = TextCodec.decode(Data("héllo\nwörld".utf8))
        #expect(d?.encoding == .utf8)
        #expect(d?.text == "héllo\nwörld")
    }

    @Test func utf8BOM() {
        let d = TextCodec.decode(Data([0xEF, 0xBB, 0xBF]) + Data("hi".utf8))
        #expect(d?.encoding == .utf8BOM)
        #expect(d?.text == "hi")
    }

    @Test func utf16WithBOM() {
        let le = TextCodec.encode("ça va\n", encoding: .utf16LE, lineEnding: .lf)!
        #expect(Array(le.prefix(2)) == [0xFF, 0xFE])
        #expect(TextCodec.decode(le)?.encoding == .utf16LE)
        #expect(TextCodec.decode(le)?.text == "ça va\n")
        let be = TextCodec.encode("ça va", encoding: .utf16BE, lineEnding: .lf)!
        #expect(Array(be.prefix(2)) == [0xFE, 0xFF])
        #expect(TextCodec.decode(be)?.text == "ça va")
    }

    @Test func utf16WithoutBOMBySniffing() {
        let le = "plain ascii text\n".data(using: .utf16LittleEndian)!
        #expect(TextCodec.detectEncoding(le) == .utf16LE)
        let be = "plain ascii text\n".data(using: .utf16BigEndian)!
        #expect(TextCodec.detectEncoding(be) == .utf16BE)
        #expect(TextCodec.decode(be)?.text == "plain ascii text\n")
    }

    @Test func latin1Fallback() {
        let bytes = Data([0x63, 0x61, 0x66, 0xE9]) // "café" in Latin-1: invalid UTF-8
        let d = TextCodec.decode(bytes)
        #expect(d?.encoding == .latin1)
        #expect(d?.text == "café")
    }

    @Test func utf8Validation() {
        #expect(TextCodec.isValidUTF8(Data("plain ascii that is longer than eight bytes".utf8)))
        #expect(TextCodec.isValidUTF8(Data("emoji 😀 and ü".utf8)))
        #expect(!TextCodec.isValidUTF8(Data([0xC0, 0x80])))            // overlong
        #expect(!TextCodec.isValidUTF8(Data([0xED, 0xA0, 0x80])))      // surrogate
        #expect(!TextCodec.isValidUTF8(Data([0x61, 0xE2, 0x82])))      // truncated
        #expect(!TextCodec.isValidUTF8(Data([0xF5, 0x80, 0x80, 0x80])))
    }

    @Test func latin1RefusesUnrepresentable() {
        #expect(TextCodec.encode("snowman ☃", encoding: .latin1, lineEnding: .lf) == nil)
        #expect(!TextCodec.canEncode("☃", as: .latin1))
        #expect(TextCodec.canEncode("é", as: .latin1))
    }
}

@Suite struct LineEndingTests {
    @Test func detection() {
        #expect(TextCodec.detectLineEnding("a\nb\n") == (.lf, false))
        #expect(TextCodec.detectLineEnding("a\r\nb\r\n") == (.crlf, false))
        #expect(TextCodec.detectLineEnding("a\rb\r") == (.cr, false))
        #expect(TextCodec.detectLineEnding("no breaks") == (.lf, false))
        let mixed = TextCodec.detectLineEnding("a\r\nb\r\nc\n")
        #expect(mixed.0 == .crlf)
        #expect(mixed.mixed)
    }

    @Test func decodeNormalisesAndEncodeRestores() {
        let d = TextCodec.decode(Data("one\r\ntwo\r\n".utf8))!
        #expect(d.text == "one\ntwo\n")
        #expect(d.lineEnding == .crlf)
        #expect(!d.mixedLineEndings)
        let back = TextCodec.encode(d.text, encoding: d.encoding, lineEnding: d.lineEnding)!
        #expect(String(decoding: back, as: UTF8.self) == "one\r\ntwo\r\n")
    }

    @Test func classicMacCR() {
        let d = TextCodec.decode(Data("a\rb".utf8))!
        #expect(d.text == "a\nb")
        #expect(d.lineEnding == .cr)
    }

    @Test func roundTripAllCombinations() {
        let text = "line one ü\nline two\n"
        for enc in TextEncoding.allCases {
            for le in LineEnding.allCases {
                let data = TextCodec.encode(text, encoding: enc, lineEnding: le)!
                let d = TextCodec.decode(data)!
                #expect(d.text == text, "\(enc) \(le)")
                #expect(d.lineEnding == le, "\(enc) \(le)")
                // Latin-1 and UTF-8 look alike only when the text is ASCII; ü makes them differ.
                #expect(d.encoding == enc, "\(enc) \(le)")
            }
        }
    }
}

@Suite struct FindTests {
    let text = "Cat cat CAT concat\ncat123" as NSString

    @Test func literalCaseInsensitive() throws {
        let re = try FindEngine.regex("cat", FindOptions())
        #expect(FindEngine.matches(re, in: text).count == 5)
    }

    @Test func caseSensitiveWholeWord() throws {
        let re = try FindEngine.regex("cat", FindOptions(caseSensitive: true, wholeWord: true))
        #expect(FindEngine.matches(re, in: text).map(\.range) == [NSRange(location: 4, length: 3)])
    }

    @Test func literalEscapesRegexCharacters() throws {
        let re = try FindEngine.regex("a.b", FindOptions())
        #expect(FindEngine.matches(re, in: "axb a.b" as NSString).map(\.range.location) == [4])
    }

    @Test func regexAndGroups() throws {
        let (out, n) = try FindEngine.replaceAll(in: "x=1, y=22", pattern: #"(\w)=(\d+)"#, with: "$2:$1", options: FindOptions(regex: true))
        #expect(out == "1:x, 22:y")
        #expect(n == 2)
    }

    @Test func literalReplacementKeepsDollar() throws {
        let (out, _) = try FindEngine.replaceAll(in: "a a", pattern: "a", with: "$1", options: FindOptions())
        #expect(out == "$1 $1")
    }

    @Test func nextWrapsAndPrevious() throws {
        let re = try FindEngine.regex("cat", FindOptions(caseSensitive: true))
        #expect(FindEngine.next(re, in: text, from: 0)?.location == 4)
        #expect(FindEngine.next(re, in: text, from: 16)?.location == 19)
        #expect(FindEngine.next(re, in: text, from: 23)?.location == 4)          // wraps
        #expect(FindEngine.next(re, in: text, from: 23, wrap: false) == nil)
        #expect(FindEngine.next(re, in: text, from: 19, backwards: true)?.location == 15)
        #expect(FindEngine.next(re, in: text, from: 4, backwards: true)?.location == 19) // wraps back
    }

    @Test func anchorsMatchLines() throws {
        let re = try FindEngine.regex("^cat", FindOptions(regex: true, caseSensitive: true))
        #expect(FindEngine.matches(re, in: text).map(\.range.location) == [19])
    }

    @Test func invalidPattern() {
        #expect(throws: FindEngine.FindError.invalidPattern("(")) { try FindEngine.regex("(", FindOptions(regex: true)) }
        #expect(throws: FindEngine.FindError.emptyPattern) { try FindEngine.regex("", FindOptions()) }
    }
}
