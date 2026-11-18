import Foundation

/// The encodings Cedric reads and writes.
public enum TextEncoding: String, CaseIterable, Codable, Sendable {
    case utf8
    case utf8BOM
    case utf16LE
    case utf16BE
    case latin1

    public var displayName: String {
        switch self {
        case .utf8: return "UTF-8"
        case .utf8BOM: return String(localized: "UTF-8 with BOM")
        case .utf16LE: return "UTF-16 LE"
        case .utf16BE: return "UTF-16 BE"
        case .latin1: return String(localized: "Latin-1 (ISO 8859-1)")
        }
    }

    var bom: [UInt8] {
        switch self {
        case .utf8BOM: return [0xEF, 0xBB, 0xBF]
        case .utf16LE: return [0xFF, 0xFE]
        case .utf16BE: return [0xFE, 0xFF]
        case .utf8, .latin1: return []
        }
    }

    var foundation: String.Encoding {
        switch self {
        case .utf8, .utf8BOM: return .utf8
        case .utf16LE: return .utf16LittleEndian
        case .utf16BE: return .utf16BigEndian
        case .latin1: return .isoLatin1
        }
    }
}

public enum LineEnding: String, CaseIterable, Codable, Sendable {
    case lf, crlf, cr

    public var displayName: String {
        switch self {
        case .lf: return "LF"
        case .crlf: return "CRLF"
        case .cr: return "CR"
        }
    }

    public var string: String {
        switch self {
        case .lf: return "\n"
        case .crlf: return "\r\n"
        case .cr: return "\r"
        }
    }
}

/// A file's text as Cedric edits it: decoded, with line endings
/// normalised to "\n", plus what to write back.
public struct DecodedText: Sendable {
    public var text: String
    public var encoding: TextEncoding
    public var lineEnding: LineEnding
    /// The file mixed line endings; saving writes them all as `lineEnding`.
    public var mixedLineEndings: Bool
}

public enum TextCodec {
    /// Detects the encoding: a BOM, else valid UTF-8, else UTF-16 by its
    /// pattern of zero bytes, else Latin-1 (which decodes any bytes).
    public static func detectEncoding(_ data: Data) -> TextEncoding {
        let head = [UInt8](data.prefix(4))
        if head.starts(with: [0xEF, 0xBB, 0xBF]) { return .utf8BOM }
        if head.starts(with: [0xFF, 0xFE]) { return .utf16LE }
        if head.starts(with: [0xFE, 0xFF]) { return .utf16BE }
        if let guess = guessUTF16(data) { return guess }
        if isValidUTF8(data) { return .utf8 }
        return .latin1
    }

    /// Mostly-ASCII UTF-16 without a BOM: zero bytes in one parity.
    static func guessUTF16(_ data: Data) -> TextEncoding? {
        let sample = data.prefix(4096)
        guard sample.count >= 4, sample.count % 2 == 0 else { return nil }
        var evenZeros = 0, oddZeros = 0
        for (k, byte) in sample.enumerated() where byte == 0 {
            if k % 2 == 0 { evenZeros += 1 } else { oddZeros += 1 }
        }
        let half = sample.count / 2
        if oddZeros * 10 > half * 6, evenZeros * 10 < half { return .utf16LE }
        if evenZeros * 10 > half * 6, oddZeros * 10 < half { return .utf16BE }
        return nil
    }

    static func isValidUTF8(_ data: Data) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            let b = raw.bindMemory(to: UInt8.self)
            var i = 0
            let n = b.count
            while i < n {
                // Fast path: 8 ASCII bytes at a time.
                if i + 8 <= n {
                    let word = UnsafeRawPointer(b.baseAddress! + i).loadUnaligned(as: UInt64.self)
                    if word & 0x8080808080808080 == 0 { i += 8; continue }
                }
                let c = b[i]
                if c < 0x80 { i += 1; continue }
                let len: Int
                if c & 0xE0 == 0xC0 { len = 2; if c < 0xC2 { return false } }
                else if c & 0xF0 == 0xE0 { len = 3 }
                else if c & 0xF8 == 0xF0 { len = 4; if c > 0xF4 { return false } }
                else { return false }
                if i + len > n { return false }
                for k in 1..<len where b[i + k] & 0xC0 != 0x80 { return false }
                if len == 3 {
                    let c1 = b[i + 1]
                    if c == 0xE0 && c1 < 0xA0 { return false }    // overlong
                    if c == 0xED && c1 >= 0xA0 { return false }   // surrogates
                }
                if len == 4 {
                    let c1 = b[i + 1]
                    if c == 0xF0 && c1 < 0x90 { return false }
                    if c == 0xF4 && c1 >= 0x90 { return false }
                }
                i += len
            }
            return true
        }
    }

    /// Decodes `data` (as `encoding`, or the detected one) and normalises
    /// its line endings. Nil if the bytes aren't valid in that encoding.
    public static func decode(_ data: Data, as encoding: TextEncoding? = nil) -> DecodedText? {
        let enc = encoding ?? detectEncoding(data)
        var body = data
        if !enc.bom.isEmpty, data.starts(with: enc.bom) { body = data.dropFirst(enc.bom.count) }
        guard let raw = String(data: body, encoding: enc.foundation) else { return nil }
        let (ending, mixed) = detectLineEnding(raw)
        return DecodedText(text: normalizeLineEndings(raw), encoding: enc, lineEnding: ending, mixedLineEndings: mixed)
    }

    /// The most common line ending, and whether more than one kind occurs.
    /// A file with no line breaks counts as LF.
    public static func detectLineEnding(_ text: String) -> (LineEnding, mixed: Bool) {
        var lf = 0, crlf = 0, cr = 0
        var copy = text
        copy.withUTF8 { b in
            var i = 0
            while i < b.count {
                let c = b[i]
                if c == 13 {
                    if i + 1 < b.count, b[i + 1] == 10 { crlf += 1; i += 2; continue }
                    cr += 1
                } else if c == 10 {
                    lf += 1
                }
                i += 1
            }
        }
        let kinds = [lf, crlf, cr].filter { $0 > 0 }.count
        let ending: LineEnding = crlf > lf && crlf >= cr ? .crlf : cr > lf && cr > crlf ? .cr : .lf
        return (ending, kinds > 1)
    }

    /// CRLF and CR → LF.
    public static func normalizeLineEndings(_ text: String) -> String {
        guard text.utf8.contains(13) else { return text }
        let m = NSMutableString(string: text)
        m.replaceOccurrences(of: "\r\n", with: "\n", options: .literal, range: NSRange(location: 0, length: m.length))
        m.replaceOccurrences(of: "\r", with: "\n", options: .literal, range: NSRange(location: 0, length: m.length))
        return m as String
    }

    /// Encodes LF-normalised text for saving: line endings converted, BOM
    /// added. Nil if a character can't be represented (Latin-1).
    public static func encode(_ text: String, encoding: TextEncoding, lineEnding: LineEnding) -> Data? {
        var s = text
        if lineEnding != .lf {
            let m = NSMutableString(string: text)
            m.replaceOccurrences(of: "\n", with: lineEnding.string, options: .literal, range: NSRange(location: 0, length: m.length))
            s = m as String
        }
        guard let body = s.data(using: encoding.foundation, allowLossyConversion: false) else { return nil }
        // Foundation's .utf16LittleEndian/BigEndian write no BOM; add ours.
        return encoding.bom.isEmpty ? body : Data(encoding.bom) + body
    }

    /// Whether `text` can be saved in `encoding` without loss.
    public static func canEncode(_ text: String, as encoding: TextEncoding) -> Bool {
        switch encoding {
        case .latin1: return text.unicodeScalars.allSatisfy { $0.value < 256 }
        default: return true
        }
    }
}
