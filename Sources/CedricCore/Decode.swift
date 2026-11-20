import Foundation

/// Decodes a selection offline, for a small popover: a JWT (its header and
/// payload only; the signature is never checked and nothing is sent
/// anywhere), base64 (standard or URL-safe) or a Unix timestamp (seconds
/// or milliseconds). Pure; `now` and the time zone are passed in.
public enum Decode {
    public enum Kind: String, Sendable { case jwt, base64, timestamp }

    public struct Result: Sendable, Equatable {
        public var kind: Kind
        public var title: String
        /// The decoded text (pretty JSON, the text, or the dates).
        public var body: String
    }

    /// The decoding of `selection`, or nil when it isn't one of the kinds.
    public static func decode(_ selection: String, now: Date = Date(), timeZone: TimeZone = .current) -> Result? {
        let t = selection.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'`")))
        guard !t.isEmpty, t.utf16.count <= 64 * 1024 else { return nil }
        if let r = jwt(t, now: now, timeZone: timeZone) { return r }
        if let r = timestamp(t, now: now, timeZone: timeZone) { return r }
        if let r = base64(t) { return r }
        return nil
    }

    // MARK: JWT

    static func jwt(_ t: String, now: Date, timeZone: TimeZone) -> Result? {
        let token = t.hasPrefix("Bearer ") ? String(t.dropFirst(7)) : t
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].hasPrefix("eyJ"), parts.allSatisfy({ $0.allSatisfy(isBase64URL) }),
              let hd = base64Data(String(parts[0]), url: true), let pd = base64Data(String(parts[1]), url: true),
              let header = try? JSONSerialization.jsonObject(with: hd) as? [String: Any], header["alg"] != nil || header["typ"] != nil,
              let payload = try? JSONSerialization.jsonObject(with: pd) as? [String: Any] else { return nil }
        var lines = [String(localized: "Header:"), pretty(header), "", String(localized: "Payload:"), pretty(payload)]
        var times: [String] = []
        for (key, label) in [("exp", String(localized: "Expires")), ("iat", String(localized: "Issued")), ("nbf", String(localized: "Not before"))] {
            guard let v = (payload[key] as? NSNumber)?.doubleValue else { continue }
            let d = Date(timeIntervalSince1970: v)
            times.append("\(label): \(format(d, timeZone: timeZone)) (\(relative(d, now: now)))")
        }
        if !times.isEmpty { lines += [""] + times }
        lines += ["", String(localized: "The signature is not checked: this only shows what the token says.")]
        var title = String(localized: "JWT")
        if let exp = (payload["exp"] as? NSNumber)?.doubleValue {
            title += Date(timeIntervalSince1970: exp) < now ? String(localized: " (expired)") : String(localized: " (not expired)")
        }
        return Result(kind: .jwt, title: title, body: lines.joined(separator: "\n"))
    }

    static func pretty(_ o: Any) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let s = String(data: d, encoding: .utf8) else { return "\(o)" }
        return s
    }

    // MARK: Timestamps

    /// 10 digits (seconds) or 13 (milliseconds), between 1990 and 2100.
    static func timestamp(_ t: String, now: Date, timeZone: TimeZone) -> Result? {
        guard t.allSatisfy(\.isASCII), t.allSatisfy(\.isNumber), t.count == 10 || t.count == 13, let n = Double(t) else { return nil }
        let seconds = t.count == 13 ? n / 1000 : n
        let d = Date(timeIntervalSince1970: seconds)
        guard seconds >= 631_152_000, seconds <= 4_102_444_800 else { return nil }   // 1990…2100
        let iso = ISO8601DateFormatter()
        iso.formatOptions = t.count == 13 ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
        let body = [format(d, timeZone: timeZone) + " (" + relative(d, now: now) + ")", "UTC: " + iso.string(from: d)].joined(separator: "\n")
        return Result(kind: .timestamp, title: t.count == 13 ? String(localized: "Unix time (milliseconds)") : String(localized: "Unix time"), body: body)
    }

    static func format(_ d: Date, timeZone: TimeZone) -> String {
        let f = DateFormatter()
        f.timeZone = timeZone
        f.dateStyle = .medium
        f.timeStyle = .medium
        return f.string(from: d)
    }

    static func relative(_ d: Date, now: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f.localizedString(for: d, relativeTo: now)
    }

    // MARK: Base64

    static func isBase64URL(_ c: Character) -> Bool { c.isASCII && (c.isLetter || c.isNumber || c == "-" || c == "_") }

    static func base64Data(_ s: String, url: Bool) -> Data? {
        var t = url ? s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") : s
        while t.count % 4 != 0 { t += "=" }
        return Data(base64Encoded: t)
    }

    /// Base64 that decodes to readable text (UTF-8, mostly printable). At
    /// least 8 characters, with the shape of base64 (not a plain word).
    static func base64(_ t: String) -> Result? {
        let s = t.filter { !$0.isWhitespace }
        guard s.count >= 8, s.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "+/=-_".contains($0)) }) else { return nil }
        // A word, or a number, isn't base64 worth decoding.
        guard s.contains(where: \.isNumber) || s.contains(where: \.isUppercase) && s.contains(where: \.isLowercase) || s.hasSuffix("=") else { return nil }
        let url = s.contains("-") || s.contains("_")
        guard let d = base64Data(s.trimmingCharacters(in: CharacterSet(charactersIn: "=")), url: url), !d.isEmpty,
              let text = String(data: d, encoding: .utf8) else { return nil }
        let printable = text.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) || $0 == "\n" || $0 == "\t" || $0 == "\r" }.count
        guard Double(printable) >= Double(text.unicodeScalars.count) * 0.95 else { return nil }
        return Result(kind: .base64, title: url ? String(localized: "Base64 (URL-safe)") : String(localized: "Base64"), body: text)
    }
}
