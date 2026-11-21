#if os(macOS)
import AppKit
#endif
import CoreGraphics
import ImageIO
import Vision
import CedricCore

// describe_image: Ask Cedric looks at the picture the open document draws.
// The picture is rendered on this Mac (an SVG by the preview's renderer,
// in the app) and read by Apple's on-device Vision framework: what it
// looks like (VNClassifyImageRequest), any text in it
// (VNRecognizeTextRequest) and faces (VNDetectFaceRectanglesRequest);
// plus its size and main colours, counted here. No network, and only the
// open document. Vision's models load only when the tool runs, never on
// launch or while typing.

/// A picture for describe_image: a bitmap, and the picture's own size.
public struct OwlRenderedImage: @unchecked Sendable {
    /// At most `OwlVision.maxPixels` on its long side; opaque.
    public let image: CGImage
    /// The picture's own size (an SVG's CSS size, a raster's pixels).
    public let width: Int
    public let height: Int
    /// Where the drawing is in `image`, without the white margin.
    public let content: CGRect

    public init(image: CGImage, width: Int, height: Int, content: CGRect? = nil) {
        self.image = image; self.width = width; self.height = height
        self.content = content ?? CGRect(x: 0, y: 0, width: image.width, height: image.height)
    }

    /// `drawing` flattened onto white with a margin of `padding` (a
    /// fraction of its long side): an icon drawn to its edges is easier
    /// for Vision to recognise with one.
    public static func padded(_ drawing: CGImage, padding: Double, width: Int, height: Int) -> OwlRenderedImage? {
        guard let flat = OwlVision.flatten(drawing, padding: padding) else { return nil }
        let pad = (flat.width - drawing.width) / 2
        return OwlRenderedImage(image: flat, width: width, height: height,
                                content: CGRect(x: pad, y: pad, width: drawing.width, height: drawing.height))
    }
}

/// Where describe_image gets the open document's picture. Rendering
/// happens only when the tool runs.
public protocol OwlImageSource: Sendable {
    func render(maxPixels: Int) async throws -> OwlRenderedImage
}

/// Raster image data (PNG, JPEG, HEIC, TIFF…), decoded by ImageIO
/// straight to a downscaled bitmap.
public struct OwlRasterImageSource: OwlImageSource {
    public let data: Data
    public init(data: Data) { self.data = data }
    public func render(maxPixels: Int) async throws -> OwlRenderedImage {
        try OwlVision.decode(data, maxPixels: maxPixels)
    }
}

#if os(macOS)
/// SVG text drawn by AppKit's own SVG support (NSImage): the app's
/// fallback when the preview's WebKit renderer can't snapshot, and the
/// renderer the tests use. Safe off the main thread.
public struct OwlSVGImageSource: OwlImageSource {
    public let text: String
    /// Margin around the drawing, a fraction of its long side.
    public let padding: Double
    public init(text: String, padding: Double = 0.12) { self.text = text; self.padding = padding }

    public func render(maxPixels: Int) async throws -> OwlRenderedImage {
        try draw(side: Double(min(maxPixels, 512)) / (1 + 2 * padding))
    }

    /// Drawn with its long side `side` pixels, then flattened onto white with the margin.
    public func draw(side: Double) throws -> OwlRenderedImage {
        guard text.utf8.count <= 8 << 20 else { throw OwlImageError.tooLarge }
        guard let img = NSImage(data: Data(text.utf8)), img.size.width > 0, img.size.height > 0 else { throw OwlImageError.unreadable }
        let scale = side / max(img.size.width, img.size.height)
        let w = max(1, Int((img.size.width * scale).rounded())), h = max(1, Int((img.size.height * scale).rounded()))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw OwlImageError.unreadable }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        img.draw(in: NSRect(x: 0, y: 0, width: w, height: h))
        NSGraphicsContext.restoreGraphicsState()
        guard let cg = ctx.makeImage(),
              let picture = OwlRenderedImage.padded(cg, padding: padding, width: Int(img.size.width.rounded()), height: Int(img.size.height.rounded()))
        else { throw OwlImageError.unreadable }
        return picture
    }
}
#endif

public enum OwlImageError: Error, Equatable {
    case unreadable, tooLarge, timedOut
}

public enum OwlVision {
    /// The long side handed to Vision: larger pictures are scaled down.
    public static let maxPixels = 1024
    /// Raster data larger than this isn't read.
    public static let maxInputBytes = 64 << 20
    /// Rendering plus analysis (warm: well under a second; the first use
    /// in a new build of the app loads Vision's models, a second or two).
    public static let timeLimit: TimeInterval = 20
    /// Labels below this are dropped; below `sureConfidence` they are
    /// reported as weak guesses.
    public static let minConfidence: Float = 0.1
    public static let sureConfidence: Float = 0.5
    public static let maxLabels = 5

    public struct Label: Sendable, Equatable {
        public var name: String
        public var confidence: Float
    }

    public struct Analysis: Sendable, Equatable {
        public var width: Int
        public var height: Int
        public var labels: [Label]
        public var text: [String]
        public var faces: Int
        public var colours: String
    }

    // MARK: Rendering

    /// Raster `data` as an opaque bitmap at most `maxPixels` on its long side.
    public static func decode(_ data: Data, maxPixels: Int) throws -> OwlRenderedImage {
        guard data.count <= maxInputBytes else { throw OwlImageError.tooLarge }
        guard let src = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(src) > 0 else { throw OwlImageError.unreadable }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        var w = (props?[kCGImagePropertyPixelWidth] as? Int) ?? 0
        var h = (props?[kCGImagePropertyPixelHeight] as? Int) ?? 0
        if let o = props?[kCGImagePropertyOrientation] as? Int, o >= 5 { swap(&w, &h) }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceThumbnailMaxPixelSize: maxPixels,
                                     kCGImageSourceShouldCacheImmediately: true]
        guard let thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary),
              let flat = flatten(thumb, padding: 0) else { throw OwlImageError.unreadable }
        return OwlRenderedImage(image: flat, width: w > 0 ? w : thumb.width, height: h > 0 ? h : thumb.height)
    }

    /// `image` drawn over white (transparent parts become white, as in
    /// the preview), with `padding` (a fraction of the long side) around
    /// it: an icon drawn to its edges is easier to recognise with a margin.
    public static func flatten(_ image: CGImage, padding: Double) -> CGImage? {
        let pad = Int((Double(max(image.width, image.height)) * padding).rounded())
        let w = image.width + 2 * pad, h = image.height + 2 * pad
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: pad, y: pad, width: image.width, height: image.height))
        return ctx.makeImage()
    }

    // MARK: Analysis

    /// Vision's labels, text and faces, and the main colours. Synchronous
    /// and slow (tens of milliseconds warm, seconds cold): call it off
    /// the main thread (`describe` does).
    public static func analyze(_ picture: OwlRenderedImage) throws -> Analysis {
        let classify = VNClassifyImageRequest()
        let text = VNRecognizeTextRequest()
        // .fast: .accurate's first use in each new build of the app compiles
        // a model for about a minute (measured 47–65 s on macOS 27); .fast
        // starts in well under a second and reads an image's labels and
        // headings well enough.
        text.recognitionLevel = .fast
        text.usesLanguageCorrection = false
        let faces = VNDetectFaceRectanglesRequest()
        try VNImageRequestHandler(cgImage: picture.image, options: [:]).perform([classify, text, faces])
        let labels = (classify.results ?? [])
            .filter { $0.confidence >= minConfidence }
            .sorted { $0.confidence > $1.confidence }
            .prefix(maxLabels)
            .map { Label(name: $0.identifier.replacingOccurrences(of: "_", with: " "), confidence: $0.confidence) }
        let lines = (text.results ?? []).compactMap { obs -> String? in
            guard let c = obs.topCandidates(1).first, c.confidence >= 0.3 else { return nil }
            let s = c.string.trimmingCharacters(in: .whitespacesAndNewlines)
            return s.isEmpty ? nil : s
        }
        return Analysis(width: picture.width, height: picture.height, labels: Array(labels), text: lines,
                        faces: faces.results?.count ?? 0, colours: colours(picture.image.cropping(to: picture.content) ?? picture.image))
    }

    /// One compact paragraph for the model.
    public static func summary(_ a: Analysis) -> String {
        func pct(_ c: Float) -> String { String(format: "%.2f", c) }
        let sure = a.labels.filter { $0.confidence >= sureConfidence }
        let weak = a.labels.filter { $0.confidence < sureConfidence }
        var out = "picture: \(a.width)×\(a.height), \(a.colours)\n"
        out += "labels: " + (sure.isEmpty ? "none confident" : sure.map { "\($0.name) \(pct($0.confidence))" }.joined(separator: ", ")) + "\n"
        if !weak.isEmpty { out += "weak guesses: " + weak.prefix(3).map { "\($0.name) \(pct($0.confidence))" }.joined(separator: ", ") + "\n" }
        var text = a.text.joined(separator: " / ")
        if text.count > 300 { text = String(text.prefix(300)) + "…" }
        out += "text: " + (text.isEmpty ? "none" : "\"\(text)\"") + "\n"
        if a.faces > 0 { out += "faces: \(a.faces)\n" }
        out += "(Apple Vision on this Mac. Its labels are a photo classifier's guesses: often wrong for icons and line art; "
            + "weigh them against the file's own code.)"
        return out
    }

    /// The tool: renders `source`, analyses it off the main thread, all
    /// within `timeLimit`.
    public static func describe(_ source: any OwlImageSource, timeLimit: TimeInterval = timeLimit) async -> OwlToolResult {
        let looked = String(localized: "Looked at the picture")
        func fail(_ why: String) -> OwlToolResult { OwlToolResult(text: "error: " + why, proposal: nil, summary: why, ok: false) }
        do {
            let a = try await withDeadline(timeLimit) {
                let picture = try await source.render(maxPixels: maxPixels)
                return try await offMain { try analyze(picture) }
            }
            return OwlToolResult(text: OwlTools.cap(summary(a)), proposal: nil, summary: looked, ok: true)
        } catch OwlImageError.timedOut {
            return fail("looking at the picture took too long; answer from the file's code")
        } catch OwlImageError.tooLarge {
            return fail("the picture is too large to look at; answer from the file's code")
        } catch {
            return fail("the picture could not be rendered; answer from the file's code")
        }
    }

    /// Runs `work` on a global queue, not the cooperative pool (Vision
    /// blocks its thread).
    static func offMain<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { c in
            DispatchQueue.global(qos: .userInitiated).async { c.resume(with: Result { try work() }) }
        }
    }

    /// `work`'s result, or `OwlImageError.timedOut` after `seconds`, or
    /// `CancellationError` as soon as the caller is cancelled (Stop). Not a
    /// task group: that would wait for a Vision call that can't be
    /// interrupted. The work is cancelled and a late result dropped.
    /// The deadline's own queue. Not a global one: `offMain` fills those
    /// with Vision calls that block (on a machine with few cores or a
    /// software GPU all of them), and a timer queued behind them fires
    /// only after the work it should cut short. A private serial queue
    /// gets a thread of its own.
    static let deadlineQueue = DispatchQueue(label: "OwlVision.deadline", qos: .userInitiated)

    static func withDeadline<T: Sendable>(_ seconds: TimeInterval, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        let once = ResumeOnce<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<T, Error>) in
                once.set(c)
                let task = Task {
                    do { once.resume(.success(try await work())) } catch { once.resume(.failure(error)) }
                }
                once.onFinish = { task.cancel() }
                deadlineQueue.asyncAfter(deadline: .now() + seconds) { once.resume(.failure(OwlImageError.timedOut)) }
            }
        } onCancel: {
            once.resume(.failure(CancellationError()))
        }
    }

    // MARK: Colours

    /// "mostly black on white", "red, grey and brown on light blue": the
    /// background (the commonest colour along the border) and the
    /// commonest other colours, from a 64×64 sample (nearest pixel, not
    /// blended: smoothed edges would add greys and tints that aren't there).
    public static func colours(_ image: CGImage) -> String {
        let n = 64
        var px = [UInt8](repeating: 255, count: n * n * 4)
        let drawn: Bool = px.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.interpolationQuality = .none
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: n, height: n))
            return true
        }
        guard drawn else { return "colours unknown" }
        var names: [String] = []
        names.reserveCapacity(n * n)
        for i in 0..<(n * n) { names.append(colourName(r: px[i * 4], g: px[i * 4 + 1], b: px[i * 4 + 2])) }
        var border: [String: Int] = [:]
        for y in 0..<n { for x in 0..<n where x == 0 || y == 0 || x == n - 1 || y == n - 1 { border[names[y * n + x], default: 0] += 1 } }
        let background = border.max { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }!.key
        var others: [String: Int] = [:]
        for c in names where c != background { others[c, default: 0] += 1 }
        let otherTotal = others.values.reduce(0, +)
        // Under 2% of the picture: a plain background.
        guard otherTotal * 50 >= n * n else { return "plain \(background)" }
        let main = others.filter { $0.value * 10 >= otherTotal }
            .sorted { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }.prefix(3).map(\.key)
        let fg: String
        switch main.count {
        case 0: fg = "mixed colours"
        case 1: fg = "mostly \(main[0])"
        default: fg = main.dropLast().joined(separator: ", ") + " and " + main.last!
        }
        return "\(fg) on \(background)"
    }

    /// A plain colour name for an sRGB pixel.
    public static func colourName(r: UInt8, g: UInt8, b: UInt8) -> String {
        let rf = Double(r) / 255, gf = Double(g) / 255, bf = Double(b) / 255
        let mx = max(rf, gf, bf), mn = min(rf, gf, bf)
        let l = (mx + mn) / 2
        let d = mx - mn
        let s = d == 0 ? 0 : d / (1 - abs(2 * l - 1))
        if l < 0.12 { return "black" }
        if l > 0.93 && s < 0.5 || l > 0.97 { return "white" }
        if s < 0.15 || d < 0.08 { return l < 0.35 ? "dark grey" : l > 0.75 ? "light grey" : "grey" }
        var h: Double
        if mx == rf { h = (gf - bf) / d } else if mx == gf { h = (bf - rf) / d + 2 } else { h = (rf - gf) / d + 4 }
        h = (h * 60).truncatingRemainder(dividingBy: 360)
        if h < 0 { h += 360 }
        let name: String
        switch h {
        case ..<15, 345...: name = l < 0.3 ? "dark red" : l > 0.75 ? "pink" : "red"
        case ..<40: name = l < 0.4 ? "brown" : "orange"
        case ..<65: name = l < 0.35 ? "olive" : "yellow"
        case ..<165: name = l < 0.3 ? "dark green" : "green"
        case ..<195: name = "cyan"
        case ..<255: name = l < 0.3 ? "dark blue" : l > 0.7 ? "light blue" : "blue"
        case ..<290: name = "purple"
        default: name = "pink"
        }
        return name
    }
}

/// A continuation resumed once, by whichever comes first; a resume that
/// comes before the continuation is set is kept for it.
final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var early: Result<T, Error>?
    private var done = false
    var onFinish: (@Sendable () -> Void)? {
        get { lock.withLock { _onFinish } }
        set { lock.withLock { _onFinish = newValue } }
    }
    private var _onFinish: (@Sendable () -> Void)?

    func set(_ c: CheckedContinuation<T, Error>) {
        let pending: Result<T, Error>? = lock.withLock {
            if let early { done = true; return early }
            continuation = c
            return nil
        }
        if let pending { c.resume(with: pending) }
    }

    func resume(_ r: Result<T, Error>) {
        let (c, finish): (CheckedContinuation<T, Error>?, (@Sendable () -> Void)?) = lock.withLock {
            guard !done else { return (nil, nil) }
            guard let c = continuation else {
                if early == nil { early = r }
                return (nil, nil)
            }
            done = true
            continuation = nil
            return (c, _onFinish)
        }
        c?.resume(with: r)
        finish?()
    }
}
