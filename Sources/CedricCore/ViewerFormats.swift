import Foundation

/// An image format, told by its signature (the first bytes), for the
/// read-only image tabs. ImageIO decodes them all; this only decides that
/// a file is an image (not text) and names its format for the status bar.
public enum ImageFormat: String, CaseIterable, Sendable {
    case png, jpeg, gif, tiff, bmp, ico, cur, icns, webp, heic, heif, avif, jpeg2000, psd, tga

    /// The name the status bar shows.
    public var displayName: String {
        switch self {
        case .png: "PNG"
        case .jpeg: "JPEG"
        case .gif: "GIF"
        case .tiff: "TIFF"
        case .bmp: "BMP"
        case .ico: "ICO"
        case .cur: "CUR"
        case .icns: "ICNS"
        case .webp: "WebP"
        case .heic: "HEIC"
        case .heif: "HEIF"
        case .avif: "AVIF"
        case .jpeg2000: "JPEG 2000"
        case .psd: "PSD"
        case .tga: "TGA"
        }
    }

    /// Image extensions (SVG is not one: it is text, with a preview).
    static let extensions: [String: ImageFormat] = [
        "png": .png, "apng": .png, "jpg": .jpeg, "jpeg": .jpeg, "jpe": .jpeg, "jfif": .jpeg, "gif": .gif,
        "tif": .tiff, "tiff": .tiff, "dng": .tiff, "bmp": .bmp, "dib": .bmp, "ico": .ico, "cur": .cur, "icns": .icns,
        "webp": .webp, "heic": .heic, "heics": .heic, "heif": .heif, "hif": .heif, "avif": .avif,
        "jp2": .jpeg2000, "j2k": .jpeg2000, "jpf": .jpeg2000, "jpx": .jpeg2000, "psd": .psd, "tga": .tga,
    ]

    /// By extension alone (a damaged image, or TGA, which has no signature).
    public static func forExtension(_ fileName: String) -> ImageFormat? {
        extensions[(fileName as NSString).pathExtension.lowercased()]
    }

    /// The format from a file's first bytes (at least 12 for HEIF/WebP;
    /// 32 to be sure), or nil when they aren't an image's signature.
    public static func detect<D: Collection>(_ prefix: D) -> ImageFormat? where D.Element == UInt8 {
        let b = Array(prefix.prefix(32))
        func starts(_ m: [UInt8], at o: Int = 0) -> Bool { b.count >= o + m.count && Array(b[o..<(o + m.count)]) == m }
        func ascii(_ s: String, at o: Int = 0) -> Bool { starts(Array(s.utf8), at: o) }
        if starts([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return .png }
        if starts([0xFF, 0xD8, 0xFF]) { return .jpeg }
        if ascii("GIF87a") || ascii("GIF89a") { return .gif }
        if starts([0x49, 0x49, 0x2A, 0x00]) || starts([0x4D, 0x4D, 0x00, 0x2A]) { return .tiff }
        if ascii("RIFF"), ascii("WEBP", at: 8) { return .webp }
        if ascii("icns"), b.count >= 8 { return .icns }
        if ascii("8BPS"), b.count >= 6, b[4] == 0, b[5] == 1 || b[5] == 2 { return .psd }
        // JPEG 2000: the JP2 box, or a raw codestream.
        if starts([0x00, 0x00, 0x00, 0x0C, 0x6A, 0x50, 0x20, 0x20, 0x0D, 0x0A, 0x87, 0x0A]) || starts([0xFF, 0x4F, 0xFF, 0x51]) { return .jpeg2000 }
        // ISO base media (HEIF family): size, "ftyp", then the major brand.
        if ascii("ftyp", at: 4), b.count >= 12, let brand = String(bytes: b[8..<12], encoding: .ascii) {
            switch brand {
            case "heic", "heix", "heim", "heis", "hevc", "hevx", "hevm", "hevs": return .heic
            case "mif1", "msf1", "mif2": return .heif
            case "avif", "avis": return .avif
            default: return nil // an MP4 / QuickTime movie, not a still image
            }
        }
        // ICO / CUR: reserved 0, type 1 or 2, a count of 1…255 images, and
        // the first entry's reserved byte 0.
        if b.count >= 10, b[0] == 0, b[1] == 0, b[2] == 1 || b[2] == 2, b[3] == 0, b[4] > 0, b[5] == 0, b[9] == 0 {
            return b[2] == 1 ? .ico : .cur
        }
        // BMP: "BM", reserved zeros at 6…9 and a known DIB header size at 14.
        if ascii("BM"), b.count >= 18, b[6] == 0, b[7] == 0, b[8] == 0, b[9] == 0,
           [12, 16, 40, 52, 56, 64, 108, 124].contains(Int(b[14]) | Int(b[15]) << 8), b[16] == 0, b[17] == 0 {
            return .bmp
        }
        return nil
    }
}

/// Where an image tab was: kept with the session so it comes back at the
/// same zoom, scrolled to the same place.
public struct ImageTabState: Codable, Equatable, Sendable {
    /// The zoom (1 = one image pixel per point); nil when the image is
    /// fitted to the window (the default).
    public var scale: Double?
    /// The point shown in the middle, as a fraction of the image (0…1).
    public var centerX: Double?
    public var centerY: Double?

    public init(scale: Double? = nil, centerX: Double? = nil, centerY: Double? = nil) {
        self.scale = scale
        self.centerX = centerX
        self.centerY = centerY
    }

    private enum CodingKeys: String, CodingKey { case scale, centerX, centerY }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func fraction(_ k: CodingKeys) throws -> Double? {
            try c.decodeIfPresent(Double.self, forKey: k).flatMap { $0.isFinite ? min(max($0, 0), 1) : nil }
        }
        scale = try c.decodeIfPresent(Double.self, forKey: .scale).flatMap { $0.isFinite && $0 > 0 ? ImageZoom.clamp($0) : nil }
        centerX = try fraction(.centerX)
        centerY = try fraction(.centerY)
    }
}

/// The image tab's zoom and display arithmetic.
public enum ImageZoom {
    public static let minScale = 0.01, maxScale = 32.0
    /// ⌘= / ⌘- multiply or divide by this.
    public static let step = 1.25
    public static func clamp(_ s: Double) -> Double { min(max(s, minScale), maxScale) }

    /// Fit to the window: the whole image shown, never enlarged past
    /// actual size (a small icon stays crisp at 100%).
    public static func fitScale(imageWidth: Double, imageHeight: Double, viewWidth: Double, viewHeight: Double) -> Double {
        guard imageWidth > 0, imageHeight > 0, viewWidth > 0, viewHeight > 0 else { return 1 }
        return clamp(min(1, min(viewWidth / imageWidth, viewHeight / imageHeight)))
    }

    /// Images up to this many pixels are decoded whole for display.
    public static let fullDecodeLimit = 40_000_000.0
    /// Bigger ones are decoded down to about this many.
    public static let displayPixelBudget = 32_000_000.0
    /// And never longer than this on a side (a GPU texture's limit on
    /// older Intel Macs).
    public static let maxDisplaySide = 8192

    /// The longest side to decode an image at for display
    /// (CGImageSourceCreateThumbnailAtIndex's max pixel size): the whole
    /// image up to 40 megapixels; a bigger one scaled to ~32 megapixels,
    /// so a 100-megapixel photo costs ~128 MB, not 400; and at most 8192
    /// pixels on a side.
    public static func displayMaxPixelSize(width: Int, height: Int) -> Int {
        let w = Double(max(width, 1)), h = Double(max(height, 1))
        let side = max(w, h)
        guard w * h > fullDecodeLimit else { return min(Int(side), maxDisplaySide) }
        return min(maxDisplaySide, max(1, Int((side * (displayPixelBudget / (w * h)).squareRoot()).rounded(.down))))
    }

    /// "125%", as the status bar shows it.
    public static func percent(_ scale: Double) -> String {
        let p = scale * 100
        return p < 10 && p.rounded() != p ? String(format: "%.1f%%", p) : "\(Int(p.rounded()))%"
    }
}

/// The image tab's status bar text.
public enum ImageInfoText {
    /// "4032 × 3024 px · 2.4 MB · HEIC · Display P3", plus "· 12 frames"
    /// for an animation.
    public static func status(width: Int, height: Int, fileBytes: Int64?, format: String, colorSpace: String?, frames: Int = 1) -> String {
        var parts = ["\(width) × \(height) px"]
        if let fileBytes { parts.append(fileSize(fileBytes)) }
        if !format.isEmpty { parts.append(format) }
        if let colorSpace, !colorSpace.isEmpty { parts.append(colorSpace) }
        if frames > 1 { parts.append("\(frames) frames") }
        return parts.joined(separator: " · ")
    }

    /// Finder's way: 1000-based, "812 bytes", "2.4 MB".
    public static func fileSize(_ bytes: Int64) -> String {
        if bytes < 1000 { return bytes == 1 ? "1 byte" : "\(bytes) bytes" }
        let units = ["KB", "MB", "GB", "TB"]
        var v = Double(bytes) / 1000
        var i = 0
        while v >= 999.95 && i < units.count - 1 { v /= 1000; i += 1 }
        return v < 10 ? String(format: "%.1f %@", v, units[i]) : String(format: "%.0f %@", v, units[i])
    }

    /// A colour model and profile name as the status bar shows them:
    /// "sRGB IEC61966-2.1" → "sRGB"; a grey image without a profile → "Gray".
    public static func colorSpaceName(profile: String?, model: String?) -> String? {
        if let p = profile?.trimmingCharacters(in: .whitespaces), !p.isEmpty {
            if p.hasPrefix("sRGB") { return "sRGB" }
            return p
        }
        switch model {
        case "RGB": return "RGB"
        case "Gray": return "Gray"
        case "CMYK": return "CMYK"
        case "Lab": return "Lab"
        case let m?: return m
        case nil: return nil
        }
    }
}
