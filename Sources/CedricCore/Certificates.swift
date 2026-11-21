import CryptoKit
import Foundation
import Security

// Certificates: PEM blocks found in text, X.509 certificates read with the
// Security framework (`SecCertificateCreateWithData`,
// `SecCertificateCopyValues`), PKCS#7 bundles (`SecItemImport`, no
// keychain), and a small DER reader for what Security doesn't read (a
// certificate request's subject, extended key usage OIDs). Security is a
// system framework every AppKit process has loaded already, so this costs
// nothing at launch; nothing here runs until a certificate is shown.
// Private keys are never decoded: their blocks are found by their header
// and reported as "Private key — not shown".

/// One `-----BEGIN X----- … -----END X-----` block in a text.
public struct PEMBlock: Equatable, Sendable {
    /// The label: "CERTIFICATE", "PRIVATE KEY", "CERTIFICATE REQUEST", …
    public var label: String
    /// The whole block, BEGIN to END lines included, in UTF-16 offsets.
    public var range: NSRange
    /// The decoded body; nil for a private key (never decoded) or bad base64.
    public var der: Data?

    public var isPrivateKey: Bool { PEM.isPrivateKeyLabel(label) }
}

public enum PEM {
    static let dashes = "-----"
    static let begin = dashes + "BEGIN "
    /// How many blocks `blocks(in:)` reads at most (a CA bundle has ~150).
    public static let maxBlocks = 500

    public static func isPrivateKeyLabel(_ label: String) -> Bool { label.hasSuffix("PRIVATE" + " KEY") }

    /// Whether `text` has a PEM certificate (or a key, request or bundle)
    /// in its first `limit` UTF-16 units. Cheap: a substring search.
    public static func contains(_ text: String, limit: Int = 1 << 20) -> Bool {
        let ns = text as NSString
        return ns.range(of: begin, options: .literal, range: NSRange(location: 0, length: min(limit, ns.length))).location != NSNotFound
    }

    /// The blocks in `text`, in order. An unterminated block is skipped.
    public static func blocks(in text: String, limit: Int = maxBlocks) -> [PEMBlock] {
        let ns = text as NSString
        var out: [PEMBlock] = []
        var at = 0
        while out.count < limit {
            let b = ns.range(of: begin, options: .literal, range: NSRange(location: at, length: ns.length - at))
            guard b.location != NSNotFound else { break }
            let labelStart = NSMaxRange(b)
            let close = ns.range(of: dashes, options: .literal, range: NSRange(location: labelStart, length: ns.length - labelStart))
            guard close.location != NSNotFound, close.location - labelStart < 64 else { at = labelStart; continue }
            let label = ns.substring(with: NSRange(location: labelStart, length: close.location - labelStart))
            let endMarker = dashes + "END " + label + dashes
            let e = ns.range(of: endMarker, options: .literal, range: NSRange(location: NSMaxRange(close), length: ns.length - NSMaxRange(close)))
            guard e.location != NSNotFound else { at = NSMaxRange(close); continue }
            let range = NSRange(location: b.location, length: NSMaxRange(e) - b.location)
            var der: Data?
            if !isPrivateKeyLabel(label) {
                let body = ns.substring(with: NSRange(location: NSMaxRange(close), length: e.location - NSMaxRange(close)))
                // Skip RFC 1421 headers ("Proc-Type: …") and whitespace.
                let b64 = body.split(whereSeparator: \.isNewline).filter { !$0.contains(":") }.joined()
                    .filter { !$0.isWhitespace }
                der = Data(base64Encoded: b64)
            }
            out.append(PEMBlock(label: label, range: range, der: der))
            at = NSMaxRange(e)
        }
        return out
    }

    /// DER as PEM text, 64 characters a line.
    public static func encode(_ der: Data, label: String = "CERTIFICATE") -> String {
        let b64 = der.base64EncodedString()
        var lines: [Substring] = []
        var i = b64.startIndex
        while i < b64.endIndex {
            let j = b64.index(i, offsetBy: 64, limitedBy: b64.endIndex) ?? b64.endIndex
            lines.append(b64[i..<j])
            i = j
        }
        return begin + label + dashes + "\n" + lines.joined(separator: "\n") + "\n" + dashes + "END " + label + dashes + "\n"
    }
}

/// A name and value, both in plain words: ("Common name", "example.com").
public struct CertificateField: Equatable, Sendable {
    public var name: String
    public var value: String
    public init(_ name: String, _ value: String) { self.name = name; self.value = value }
}

/// What Cedric shows about one X.509 certificate.
public struct CertificateInfo: Equatable, Sendable {
    public var summary: String
    public var subject: [CertificateField]
    public var issuer: [CertificateField]
    public var serialNumber: String
    public var notBefore: Date?
    public var notAfter: Date?
    /// DNS names, IP addresses, emails and URIs.
    public var alternativeNames: [String]
    /// "RSA 2048-bit", "EC P-256", "Ed25519".
    public var publicKey: String
    /// "SHA-256 with RSA", "ECDSA with SHA-256", …
    public var signatureAlgorithm: String
    /// From basic constraints; nil when the extension is absent.
    public var isCA: Bool?
    public var keyUsage: [String]
    public var extendedKeyUsage: [String]
    /// Upper-case hex, colon-separated.
    public var sha256: String
    public var sha1: String
    public var der: Data

    public var isSelfIssued: Bool { subject == issuer }

    /// "CN=example.com, O=Example, C=US" style.
    public static func distinguishedName(_ fields: [CertificateField]) -> String {
        fields.map { "\(CertificateNames.short[$0.name] ?? $0.name)=\($0.value)" }.joined(separator: ", ")
    }

    public enum Validity: Equatable, Sendable {
        case notYetValid(days: Int)
        case valid(daysLeft: Int)
        case expired(daysAgo: Int)
    }

    /// Validity at `now`, in whole days (rounded down; "expires in 0 days" is today).
    public func validity(at now: Date = Date()) -> Validity? {
        guard let notAfter else { return nil }
        if let notBefore, now < notBefore { return .notYetValid(days: Int(notBefore.timeIntervalSince(now) / 86_400)) }
        if now > notAfter { return .expired(daysAgo: Int(now.timeIntervalSince(notAfter) / 86_400)) }
        return .valid(daysLeft: Int(notAfter.timeIntervalSince(now) / 86_400))
    }

    /// "Expired", "Expires in 12 days", "Expires today", "Not yet valid".
    public func badge(at now: Date = Date()) -> String {
        switch validity(at: now) {
        case .expired?: return String(localized: "Expired")
        case .notYetValid?: return String(localized: "Not yet valid")
        case .valid(let d)?:
            if d == 0 { return String(localized: "Expires today") }
            if d == 1 { return String(localized: "Expires tomorrow") }
            return String(localized: "Expires in \(d) days")
        case nil: return ""
        }
    }

    /// The details in plain words, in the order the panel and the
    /// certificate tab show them.
    public func rows(dateStyle: (Date) -> String = { $0.formatted(date: .abbreviated, time: .shortened) }) -> [CertificateField] {
        var out: [CertificateField] = []
        out.append(CertificateField(String(localized: "Subject"), CertificateInfo.distinguishedName(subject)))
        out.append(CertificateField(String(localized: "Issued by"),
                                    isSelfIssued ? String(localized: "Itself (self-signed)") : CertificateInfo.distinguishedName(issuer)))
        if let notBefore { out.append(CertificateField(String(localized: "Valid from"), dateStyle(notBefore))) }
        if let notAfter { out.append(CertificateField(String(localized: "Valid until"), dateStyle(notAfter))) }
        if !alternativeNames.isEmpty { out.append(CertificateField(String(localized: "Other names"), alternativeNames.joined(separator: ", "))) }
        if let isCA { out.append(CertificateField(String(localized: "Certificate authority"), isCA ? String(localized: "Yes (can sign other certificates)") : String(localized: "No"))) }
        if !keyUsage.isEmpty { out.append(CertificateField(String(localized: "Key usage"), keyUsage.joined(separator: ", "))) }
        if !extendedKeyUsage.isEmpty { out.append(CertificateField(String(localized: "Used for"), extendedKeyUsage.joined(separator: ", "))) }
        out.append(CertificateField(String(localized: "Public key"), publicKey))
        out.append(CertificateField(String(localized: "Signature"), signatureAlgorithm))
        out.append(CertificateField(String(localized: "Serial number"), serialNumber))
        out.append(CertificateField("SHA-256", sha256))
        out.append(CertificateField("SHA-1", sha1))
        return out
    }

    /// Expired, or expiring within `days`.
    public func needsAttention(at now: Date = Date(), within days: Int = 30) -> Bool {
        switch validity(at: now) {
        case .expired?: return true
        case .valid(let d)?: return d <= days
        default: return false
        }
    }
}

/// One thing found in a certificate file.
public enum CertificateItem: Equatable, Sendable {
    case certificate(CertificateInfo)
    /// A private key's block: found, never decoded or shown.
    case privateKey
    /// A certificate signing request, with its subject when it could be read.
    case request(subject: [CertificateField]?)
    case publicKey
    /// A block Cedric doesn't read (label), or a certificate that doesn't parse.
    case other(String)
    case damaged(String)

    /// The heading for an item that isn't a certificate.
    public var title: String {
        switch self {
        case .certificate(let c): return c.summary
        case .privateKey: return String(localized: "Private key — not shown")
        case .request(let subject):
            return subject.flatMap { s in s.first { $0.name == CertificateNames.attributes["2.5.4.3"] }?.value }
                .map { String(localized: "Certificate request for \($0)") } ?? String(localized: "Certificate request")
        case .publicKey: return String(localized: "Public key")
        case .other(let label): return String(localized: "\(label.capitalized) (not shown)")
        case .damaged(let label): return String(localized: "A \(label.lowercased()) that can’t be read")
        }
    }

    public var certificate: CertificateInfo? {
        if case .certificate(let c) = self { return c }
        return nil
    }
}

/// Names for the OIDs a certificate shows.
public enum CertificateNames {
    public static let attributes: [String: String] = [
        "2.5.4.3": String(localized: "Common name"), "2.5.4.10": String(localized: "Organization"),
        "2.5.4.11": String(localized: "Organizational unit"), "2.5.4.6": String(localized: "Country"),
        "2.5.4.7": String(localized: "Locality"), "2.5.4.8": String(localized: "State or province"),
        "2.5.4.5": String(localized: "Serial number"), "2.5.4.9": String(localized: "Street"),
        "2.5.4.17": String(localized: "Postal code"), "2.5.4.97": String(localized: "Organization identifier"),
        "1.2.840.113549.1.9.1": String(localized: "Email"), "0.9.2342.19200300.100.1.25": String(localized: "Domain component"),
        "0.9.2342.19200300.100.1.1": String(localized: "User ID"),
    ]
    /// Back to the short names for a one-line distinguished name.
    static let short: [String: String] = {
        let codes = ["2.5.4.3": "CN", "2.5.4.10": "O", "2.5.4.11": "OU", "2.5.4.6": "C", "2.5.4.7": "L", "2.5.4.8": "ST",
                     "2.5.4.5": "SERIALNUMBER", "2.5.4.9": "STREET", "2.5.4.17": "postalCode", "2.5.4.97": "organizationIdentifier",
                     "1.2.840.113549.1.9.1": "E", "0.9.2342.19200300.100.1.25": "DC", "0.9.2342.19200300.100.1.1": "UID"]
        var out: [String: String] = [:]
        for (oid, code) in codes { if let name = attributes[oid] { out[name] = code } }
        return out
    }()

    public static let signatures: [String: String] = [
        "1.2.840.113549.1.1.4": "MD5 with RSA", "1.2.840.113549.1.1.5": "SHA-1 with RSA",
        "1.2.840.113549.1.1.11": "SHA-256 with RSA", "1.2.840.113549.1.1.12": "SHA-384 with RSA",
        "1.2.840.113549.1.1.13": "SHA-512 with RSA", "1.2.840.113549.1.1.10": "RSA-PSS",
        "1.2.840.10045.4.1": "ECDSA with SHA-1", "1.2.840.10045.4.3.2": "ECDSA with SHA-256",
        "1.2.840.10045.4.3.3": "ECDSA with SHA-384", "1.2.840.10045.4.3.4": "ECDSA with SHA-512",
        "1.3.101.112": "Ed25519", "1.3.101.113": "Ed448",
    ]

    public static let extendedUsages: [String: String] = [
        "1.3.6.1.5.5.7.3.1": String(localized: "Server authentication (TLS)"),
        "1.3.6.1.5.5.7.3.2": String(localized: "Client authentication (TLS)"),
        "1.3.6.1.5.5.7.3.3": String(localized: "Code signing"), "1.3.6.1.5.5.7.3.4": String(localized: "Email protection"),
        "1.3.6.1.5.5.7.3.8": String(localized: "Time stamping"), "1.3.6.1.5.5.7.3.9": String(localized: "OCSP signing"),
        "2.5.29.37.0": String(localized: "Any purpose"),
    ]

    /// `kSecKeyUsage…` bits as SecCertificateCopyValues reports them.
    public static let keyUsageBits: [(UInt32, String)] = [
        (1 << 0, String(localized: "Digital signature")), (1 << 1, String(localized: "Non-repudiation")),
        (1 << 2, String(localized: "Key encipherment")), (1 << 3, String(localized: "Data encipherment")),
        (1 << 4, String(localized: "Key agreement")), (1 << 5, String(localized: "Certificate signing")),
        (1 << 6, String(localized: "CRL signing")), (1 << 7, String(localized: "Encipher only")),
        (1 << 8, String(localized: "Decipher only")),
    ]
}

public enum Certificates {
    /// The extensions a file's DER form may have.
    public static let derExtensions: Set<String> = ["der", "cer", "crt", "p7b", "p7c"]
    /// Names that are certificate files even when they hold PEM text.
    public static let textExtensions: Set<String> = ["pem", "crt", "cer", "csr", "p7b", "p7c", "ca-bundle"]

    /// Whether a file named this, starting with these bytes, is a binary
    /// (DER) certificate or PKCS#7 bundle: a known extension and an ASN.1
    /// SEQUENCE (0x30) with a valid length byte.
    public static func isDERFile<D: Collection>(prefix: D, fileName: String) -> Bool where D.Element == UInt8 {
        guard derExtensions.contains((fileName as NSString).pathExtension.lowercased()) else { return false }
        let b = Array(prefix.prefix(2))
        return b.count == 2 && b[0] == 0x30 && (b[1] >= 0x80 ? (0x81...0x84).contains(b[1]) : true)
    }

    /// Whether the panel applies to a text tab: a certificate file name, or
    /// a PEM block near the start of the text.
    public static func isCertificateText(_ text: String, fileName: String?) -> Bool {
        if let fileName, textExtensions.contains((fileName as NSString).pathExtension.lowercased()) { return true }
        return PEM.contains(text, limit: 64 * 1024)
    }

    /// Everything in a text: each PEM block, in order.
    public static func items(inText text: String) -> [(range: NSRange, item: CertificateItem)] {
        PEM.blocks(in: text).flatMap { block -> [(NSRange, CertificateItem)] in
            items(in: block).map { (block.range, $0) }
        }
    }

    static func items(in block: PEMBlock) -> [CertificateItem] {
        if block.isPrivateKey { return [.privateKey] }
        guard let der = block.der else { return [.damaged(block.label)] }
        switch block.label {
        case "CERTIFICATE", "X509 CERTIFICATE", "TRUSTED CERTIFICATE":
            return [parse(der).map { .certificate($0) } ?? .damaged(block.label)]
        case "CERTIFICATE REQUEST", "NEW CERTIFICATE REQUEST":
            return [.request(subject: requestSubject(der))]
        case "PKCS7":
            let certs = pkcs7Certificates(der)
            return certs.isEmpty ? [.damaged(block.label)] : certs.map { parse($0).map { .certificate($0) } ?? .damaged("CERTIFICATE") }
        case "PUBLIC KEY", "RSA PUBLIC KEY":
            return [.publicKey]
        default:
            return [.other(block.label)]
        }
    }

    /// A binary file: one DER certificate, or a DER PKCS#7 bundle.
    public static func items(inDER data: Data) -> [CertificateItem] {
        if let c = parse(data) { return [.certificate(c)] }
        let certs = pkcs7Certificates(data)
        if !certs.isEmpty { return certs.map { parse($0).map { .certificate($0) } ?? .damaged("CERTIFICATE") } }
        if let s = requestSubject(data) { return [.request(subject: s)] }
        return []
    }

    /// The certificates in a PKCS#7 bundle (DER or PEM), as DER.
    public static func pkcs7Certificates(_ data: Data) -> [Data] {
        #if os(macOS)
        var format = SecExternalFormat.formatPKCS7
        var type = SecExternalItemType.itemTypeAggregate
        var items: CFArray?
        guard SecItemImport(data as CFData, nil, &format, &type, [], nil, nil, &items) == errSecSuccess,
              let list = items as? [AnyObject] else { return [] }
        return list.compactMap { obj in
            guard CFGetTypeID(obj) == SecCertificateGetTypeID() else { return nil }
            return SecCertificateCopyData(obj as! SecCertificate) as Data
        }
        #else
        return [] // iOS Security has no SecItemImport.
        #endif
    }

    // MARK: One certificate

    /// Reads a DER certificate; nil if Security doesn't take it.
    public static func parse(_ der: Data) -> CertificateInfo? {
        #if os(macOS)
        guard let cert = SecCertificateCreateWithData(nil, der as CFData) else { return nil }
        let values = (SecCertificateCopyValues(cert, nil, nil) as? [String: Any]) ?? [:]
        func value(_ oid: CFString) -> Any? { (values[oid as String] as? [String: Any])?[kSecPropertyKeyValue as String] }
        func section(_ oid: CFString) -> [[String: Any]] { value(oid) as? [[String: Any]] ?? [] }
        func label(_ d: [String: Any]) -> String { d[kSecPropertyKeyLabel as String] as? String ?? "" }
        func names(_ oid: CFString) -> [CertificateField] {
            section(oid).compactMap { d in
                guard let v = d[kSecPropertyKeyValue as String] as? String else { return nil }
                let l = label(d)
                return CertificateField(CertificateNames.attributes[l] ?? l, v)
            }
        }
        func date(_ oid: CFString) -> Date? {
            (value(oid) as? NSNumber).map { Date(timeIntervalSinceReferenceDate: $0.doubleValue) }
        }
        func algorithm(_ oid: CFString) -> String? {
            section(oid).first { label($0) == "Algorithm" }?[kSecPropertyKeyValue as String] as? String
        }

        var serial = ""
        if let s = SecCertificateCopySerialNumberData(cert, nil) as Data? {
            // Leading zero bytes are DER padding, not part of the number.
            var bytes = Array(s)
            while bytes.count > 1, bytes[0] == 0 { bytes.removeFirst() }
            serial = hex(bytes)
        }

        var alt: [String] = []
        for d in section(kSecOIDSubjectAltName) where label(d) != "Critical" {
            if let v = d[kSecPropertyKeyValue as String] as? String { alt.append(v) }
            else if let v = d[kSecPropertyKeyValue as String] as? Data, let s = String(data: v, encoding: .utf8) { alt.append(s) }
        }

        var isCA: Bool?
        if let ca = section(kSecOIDBasicConstraints).first(where: { label($0) == "Certificate Authority" }) {
            isCA = (ca[kSecPropertyKeyValue as String] as? String) == "Yes"
        }

        var usage: [String] = []
        if let bits = (value(kSecOIDKeyUsage) as? NSNumber)?.uint32Value {
            usage = CertificateNames.keyUsageBits.filter { bits & $0.0 != 0 }.map(\.1)
        }
        var extUsage: [String] = []
        if let list = value(kSecOIDExtendedKeyUsage) as? [Any] {
            for item in list {
                guard let d = item as? Data else { continue }
                let oid = DER.oidString(Array(d))
                extUsage.append(CertificateNames.extendedUsages[oid] ?? oid)
            }
        }

        let sigOID = algorithm(kSecOIDX509V1SignatureAlgorithm) ?? ""
        let summary = (SecCertificateCopySubjectSummary(cert) as String?) ?? ""
        return CertificateInfo(
            summary: summary,
            subject: names(kSecOIDX509V1SubjectName),
            issuer: names(kSecOIDX509V1IssuerName),
            serialNumber: serial,
            notBefore: date(kSecOIDX509V1ValidityNotBefore),
            notAfter: date(kSecOIDX509V1ValidityNotAfter),
            alternativeNames: alt,
            publicKey: publicKeyDescription(cert, algorithmOID: algorithm(kSecOIDX509V1SubjectPublicKeyAlgorithm),
                                            keyData: value(kSecOIDX509V1SubjectPublicKey) as? Data),
            signatureAlgorithm: CertificateNames.signatures[sigOID] ?? sigOID,
            isCA: isCA,
            keyUsage: usage,
            extendedKeyUsage: extUsage,
            sha256: hex(Array(SHA256.hash(data: der))),
            sha1: hex(Array(Insecure.SHA1.hash(data: der))),
            der: der)
        #else
        return nil // iOS Security has no SecCertificateCopyValues.
        #endif
    }

    static func publicKeyDescription(_ cert: SecCertificate, algorithmOID: String?, keyData: Data? = nil) -> String {
        var bits = 0
        var type = ""
        if let key = SecCertificateCopyKey(cert), let attrs = SecKeyCopyAttributes(key) as? [String: Any] {
            bits = (attrs[kSecAttrKeySizeInBits as String] as? NSNumber)?.intValue ?? 0
            type = attrs[kSecAttrKeyType as String] as? String ?? ""
        }
        if type == (kSecAttrKeyTypeRSA as String) || algorithmOID == "1.2.840.113549.1.1.1" {
            return bits > 0 ? "RSA \(bits)-bit" : "RSA"
        }
        if type == (kSecAttrKeyTypeECSECPrimeRandom as String) || algorithmOID == "1.2.840.10045.2.1" {
            // A curve given by explicit parameters: Security returns no key;
            // the uncompressed point's length still tells the size.
            if bits == 0, let n = keyData?.count, keyData?.first == 4 { bits = [65: 256, 97: 384, 133: 521][n] ?? 0 }
            switch bits {
            case 256: return "EC P-256"
            case 384: return "EC P-384"
            case 521: return "EC P-521"
            default: return bits > 0 ? "EC \(bits)-bit" : "EC"
            }
        }
        if algorithmOID == "1.3.101.112" { return "Ed25519" }
        if algorithmOID == "1.3.101.113" { return "Ed448" }
        return algorithmOID ?? String(localized: "Unknown")
    }

    static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02X", $0) }.joined(separator: ":")
    }

    // MARK: Certificate requests

    /// A PKCS#10 request's subject: CertificationRequest → info → (version, subject).
    public static func requestSubject(_ der: Data) -> [CertificateField]? {
        let bytes = Array(der)
        guard let outer = DER.element(bytes, at: 0), outer.tag == 0x30,
              let info = DER.children(bytes, outer).first, info.tag == 0x30 else { return nil }
        let parts = DER.children(bytes, info)
        guard parts.count >= 2, parts[0].tag == 0x02, parts[1].tag == 0x30 else { return nil }
        return DER.name(bytes, parts[1])
    }
}

/// Just enough DER to read a Name and an OID.
enum DER {
    struct Element {
        var tag: UInt8
        var contentStart: Int
        var end: Int
    }

    static func element(_ b: [UInt8], at i: Int) -> Element? {
        guard i + 1 < b.count else { return nil }
        let tag = b[i]
        var len = Int(b[i + 1])
        var start = i + 2
        if len & 0x80 != 0 {
            let n = len & 0x7f
            guard n >= 1, n <= 4, start + n <= b.count else { return nil }
            len = 0
            for k in 0..<n { len = len << 8 | Int(b[start + k]) }
            start += n
        }
        guard start + len <= b.count else { return nil }
        return Element(tag: tag, contentStart: start, end: start + len)
    }

    static func children(_ b: [UInt8], _ e: Element) -> [Element] {
        var out: [Element] = []
        var i = e.contentStart
        while i < e.end, let c = element(b, at: i), c.end <= e.end {
            out.append(c)
            i = c.end
        }
        return out
    }

    /// An OID's content bytes as "1.2.840…".
    static func oidString(_ b: [UInt8]) -> String {
        guard let first = b.first else { return "" }
        var parts = [first < 80 ? Int(first) / 40 : 2, first < 80 ? Int(first) % 40 : Int(first) - 80]
        var v = 0
        for byte in b.dropFirst() {
            v = v << 7 | Int(byte & 0x7f)
            if byte & 0x80 == 0 { parts.append(v); v = 0 }
        }
        return parts.map(String.init).joined(separator: ".")
    }

    /// A Name (SEQUENCE OF SET OF {OID, value}) as fields.
    static func name(_ b: [UInt8], _ seq: Element) -> [CertificateField] {
        var out: [CertificateField] = []
        for set in children(b, seq) where set.tag == 0x31 {
            for atv in children(b, set) where atv.tag == 0x30 {
                let kv = children(b, atv)
                guard kv.count == 2, kv[0].tag == 0x06 else { continue }
                let oid = oidString(Array(b[kv[0].contentStart..<kv[0].end]))
                let raw = Data(b[kv[1].contentStart..<kv[1].end])
                let value: String?
                switch kv[1].tag {
                case 0x1E: value = String(data: raw, encoding: .utf16BigEndian)
                default: value = String(data: raw, encoding: .utf8) ?? String(data: raw, encoding: .isoLatin1)
                }
                out.append(CertificateField(CertificateNames.attributes[oid] ?? oid, value ?? ""))
            }
        }
        return out
    }
}
