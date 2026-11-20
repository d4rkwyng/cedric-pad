import AppKit
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import CedricAI
import CedricCore

/// describe_image: the picture rendered, read by Apple Vision on this Mac,
/// summed up as text; the tool's spec, grammar and offer rules. Vision's
/// labels vary between macOS versions and machines, so the tests check
/// the shape and sanity of what comes back, not exact labels.
@Suite(.serialized) struct DescribeImageTests {
    /// A stop sign: a red octagon with STOP in white, 120×120.
    static let stopSign = """
    <svg xmlns="http://www.w3.org/2000/svg" width="120" height="120" viewBox="0 0 120 120">
      <polygon points="35,2 85,2 118,35 118,85 85,118 35,118 2,85 2,35" fill="#c8102e"/>
      <text x="60" y="73" font-family="Helvetica" font-weight="bold" font-size="34" fill="white" text-anchor="middle">STOP</text>
    </svg>
    """

    /// The binoculars icon Derek asked about (Lucide-style strokes), 53×53.
    static let binoculars = OwlToolEval.docs["svg"]!.text

    @Test func anSVGRendersToAPaddedOpaqueBitmapOffTheMainThread() async throws {
        let picture = try await Task.detached { try await OwlSVGImageSource(text: Self.stopSign).render(maxPixels: 1024) }.value
        #expect(picture.width == 120 && picture.height == 120, "the SVG's own size is kept")
        #expect(max(picture.image.width, picture.image.height) <= 520, "drawn at about 512 px, margin included")
        #expect(picture.image.width > 300, "small icons are drawn large enough for Vision")
        #expect(picture.image.alphaInfo == .noneSkipLast, "flattened onto white")
        // The margin: the corner is white, the middle red.
        #expect(OwlVision.colours(picture.image).hasSuffix("on white"))
    }

    @Test func thePipelineDescribesTheStopSign() async throws {
        let picture = try await OwlSVGImageSource(text: Self.stopSign).render(maxPixels: 1024)
        let a = try await OwlVision.offMain { try OwlVision.analyze(picture) }
        #expect(a.width == 120 && a.height == 120)
        #expect(a.labels.count <= OwlVision.maxLabels)
        #expect(a.labels.allSatisfy { $0.confidence >= OwlVision.minConfidence && $0.confidence <= 1 && !$0.name.contains("_") })
        #expect(zip(a.labels, a.labels.dropFirst()).allSatisfy { $0.confidence >= $1.confidence }, "best first")
        #expect(a.text.joined(separator: " ").uppercased().contains("STOP"), "the sign's text is read: \(a.text)")
        #expect(a.colours.contains("red"), "red is named: \(a.colours)")
        let s = OwlVision.summary(a)
        #expect(s.hasPrefix("picture: 120×120, "))
        #expect(s.contains("\nlabels: "))
        #expect(s.contains("\ntext: \""))
        #expect(s.contains("Apple Vision on this Mac"))
        #expect(s.utf8.count < OwlTools.maxOutputBytes)
    }

    @Test func theBinocularsIconComesBackAsCompactText() async throws {
        let r = await OwlVision.describe(OwlSVGImageSource(text: Self.binoculars), timeLimit: 60)
        #expect(r.ok, "\(r.text)")
        #expect(r.text.hasPrefix("picture: 53×53, "), "\(r.text)")
        #expect(r.text.contains("on white"), "line art on a white page: \(r.text)")
        #expect(r.text.contains("text: none"), "no text in the icon: \(r.text)")
        #expect(r.proposal == nil)
        print("describe_image (binoculars.svg): \(r.text.replacingOccurrences(of: "\n", with: " | "))")
    }

    @Test func aPhotoLikeRasterIsScaledDownAndDescribed() async throws {
        let data = try Self.photoLikePNG(width: 2400, height: 1600)
        let picture = try await OwlRasterImageSource(data: data).render(maxPixels: OwlVision.maxPixels)
        #expect(picture.width == 2400 && picture.height == 1600, "the original size is reported")
        #expect(picture.image.width == 1024 && picture.image.height <= 683 && picture.image.height >= 682, "scaled down to 1024 on the long side")
        let r = await OwlVision.describe(OwlRasterImageSource(data: data), timeLimit: 60)
        #expect(r.ok, "\(r.text)")
        #expect(r.text.hasPrefix("picture: 2400×1600, "))
        #expect(r.text.uppercased().contains("OWLINK"), "big text is read: \(r.text)")
        #expect(r.text.contains("blue"), "a sky: \(r.text)")
    }

    @Test func unreadableOrSlowPicturesFailWithAReasonTheModelCanUse() async {
        let bad = await OwlVision.describe(OwlRasterImageSource(data: Data("not an image".utf8)))
        #expect(!bad.ok && bad.text.hasPrefix("error: ") && bad.text.contains("answer from the file's code"))
        let notSVG = await OwlVision.describe(OwlSVGImageSource(text: "plain words"))
        #expect(!notSVG.ok)
        // The render never finishes until released, so only the deadline
        // can end the call: no race against real render speed.
        let held = Held()
        // A safety net only: if the deadline never fires, fail instead of hanging.
        DispatchQueue.global().asyncAfter(deadline: .now() + 10) { held.release() }
        let start = Date()
        let slow = await OwlVision.describe(held, timeLimit: 0.2)
        #expect(!slow.ok && slow.text.contains("too long"), "\(slow.text)")
        #expect(held.started, "the render was under way when the deadline passed")
        #expect(Date().timeIntervalSince(start) < 2, "the deadline returns without waiting for the work")
        held.release()
    }

    @Test func coloursAreNamedPlainly() {
        #expect(OwlVision.colourName(r: 0, g: 0, b: 0) == "black")
        #expect(OwlVision.colourName(r: 255, g: 255, b: 255) == "white")
        #expect(OwlVision.colourName(r: 128, g: 128, b: 128) == "grey")
        #expect(OwlVision.colourName(r: 210, g: 20, b: 30) == "red")
        #expect(OwlVision.colourName(r: 30, g: 90, b: 220) == "blue")
        #expect(OwlVision.colourName(r: 40, g: 160, b: 60) == "green")
        #expect(OwlVision.colourName(r: 250, g: 210, b: 20) == "yellow")
        #expect(OwlVision.colourName(r: 110, g: 60, b: 20) == "brown")
    }

    // MARK: The tool in Ask Cedric

    @Test func specGrammarAndOfferRules() throws {
        let spec = OwlTools.spec(.describeImage)
        #expect(spec.name.rawValue == "describe_image")
        #expect(spec.parameters["required"] == .array([]))
        #expect(spec.description.contains("picture"))
        // The typed grammar (OwlToolGrammar) generates its rule from the empty schema.
        let g = OwlToolGrammar.envelope(OwlTools.specs([.searchDocument, .describeImage]))
        #expect(g.contains("tool-describe-image ::="))
        let m = try GBNFMatcher(g)
        #expect(m.matches(#"{"tool":"describe_image","args":{}}"#))
        #expect(!m.matches(#"{"tool":"describe_image","args":{"path":"stop.svg"}}"#))
        #expect(!OwlToolGrammar.envelope(OwlTools.specs([.searchDocument])).contains("describe_image"))
        #expect(EnvelopeStreamParser.parse(#"{"tool":"describe_image","args":{}}"#) == .toolCalls([OwlToolCall(id: "call_0", name: "describe_image")]))
        // The built-in engine's rules mention it only when it is offered.
        #expect(OwlPrompts.envelopeInstructions(OwlTools.specs([.describeImage, .getLines])).contains("call describe_image"))
        #expect(!OwlPrompts.envelopeInstructions(OwlTools.specs([.getLines])).contains("describe_image"))

        // Offered only with a picture, even when the model gets no other tools.
        let snap = OwlDocumentSnapshot(text: Self.stopSign, generation: 1, fileName: "stop.svg", language: "html")
        let ctx = OwlChatContext.build(snap, scope: .wholeDocument, budget: 6000)!
        let source = OwlSVGImageSource(text: Self.stopSign)
        var req = OwlChatRequest(question: "What is it a picture of?", context: ctx, snapshot: snap, useTools: false, prose: false, imageSource: source)
        #expect(req.tools == [.describeImage])
        req.useTools = true
        #expect(req.tools.filter { $0 == .describeImage }.count == 1)
        req.imageSource = nil
        #expect(!req.tools.contains(.describeImage), "a text file never gets it")
        #expect(OwlPicture.isPicture(fileName: "icon.SVG") && !OwlPicture.isPicture(fileName: "notes.txt") && !OwlPicture.isPicture(fileName: nil))
        // Without a renderer it is refused, with a reason.
        #expect(!OwlTools.run(OwlToolCall(name: "describe_image"), on: snap).ok)
        let text = OwlDocumentSnapshot(text: "hello", generation: 1, fileName: "a.txt")
        #expect(OwlTools.run(OwlToolCall(name: "describe_image"), on: text).text.contains("text, not a picture"))
    }

    @Test func theFileKindTellsTheModelToLook() {
        let look = OwlPrompts.fileKind("icon.svg", canDescribeImage: true)!
        #expect(look.contains("call describe_image") && look.contains("Never say there is no picture"))
        let blind = OwlPrompts.fileKind("icon.svg")!
        #expect(!blind.contains("describe_image") && blind.contains("can't see the rendered image"))
        #expect(OwlPrompts.fileKind("notes.txt", canDescribeImage: true) == nil)
    }

    @Test func theRunnerLooksAtThePictureAndTheAnswerQuotesIt() async throws {
        let snap = OwlDocumentSnapshot(text: Self.stopSign, generation: 1, fileName: "stop.svg", language: "html")
        let ctx = OwlChatContext.build(snap, scope: .wholeDocument, budget: 6000)!
        let req = OwlChatRequest(question: "What is it a picture of?", context: ctx, snapshot: snap, useTools: false, prose: false,
                                 imageSource: OwlSVGImageSource(text: Self.stopSign))
        let events = Locked<[OwlChatEvent]>([])
        let out = try await OwlChatRunner.run(req, engine: FakeChatEngine(delay: 0)) { e in events.mutate { $0.append(e) } }
        #expect(out.toolCalls == 1 && out.rounds == 1)
        #expect(out.answer.contains("describe_image saw") && out.answer.contains("picture: 120×120"), "\(out.answer)")
        #expect(events.mutate { $0 }.contains(.tool(.describeImage, "Looked at the picture")))

        // A text file: never offered, never called.
        let tsnap = OwlDocumentSnapshot(text: "Dear Ms. Lane,\nThanks.\n", generation: 1, fileName: "letter.txt")
        let tctx = OwlChatContext.build(tsnap, scope: .wholeDocument, budget: 6000)!
        let treq = OwlChatRequest(question: "What is it a picture of?", context: tctx, snapshot: tsnap, useTools: true, prose: true)
        let tout = try await OwlChatRunner.run(treq, engine: FakeChatEngine(delay: 0)) { _ in }
        #expect(tout.toolCalls == 0)
    }

    @Test func theToolboxRendersOncePerQuestion() async throws {
        let counter = Counting(OwlSVGImageSource(text: Self.stopSign))
        let snap = OwlDocumentSnapshot(text: Self.stopSign, generation: 1, fileName: "stop.svg")
        let box = OwlToolbox(snapshot: snap, allowed: [.describeImage], imageSource: counter)
        _ = try await box.picture()
        let r = await box.perform(OwlToolCall(name: "describe_image"))
        #expect(r.ok)
        #expect(counter.count == 1)
        #expect(box.callCount == 1, "attaching the picture isn't a tool call")
        // Not allowed for this question: refused, nothing rendered.
        let other = Counting(OwlSVGImageSource(text: Self.stopSign))
        let closed = OwlToolbox(snapshot: snap, allowed: [.getLines], imageSource: other)
        #expect(!(await closed.perform(OwlToolCall(name: "describe_image"))).ok)
        #expect(other.count == 0)
    }

    /// CEDRIC_DESCRIBE_FILES=a.svg:b.jpg prints describe_image's output for
    /// each file (a look at real pictures; no assertions on the labels).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CEDRIC_DESCRIBE_FILES"] != nil))
    func describeFiles() async throws {
        for path in ProcessInfo.processInfo.environment["CEDRIC_DESCRIBE_FILES"]!.split(separator: ":").map(String.init) {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            let source: any OwlImageSource = path.lowercased().hasSuffix(".svg")
                ? OwlSVGImageSource(text: String(decoding: data, as: UTF8.self)) : OwlRasterImageSource(data: data)
            let start = Date()
            let r = await OwlVision.describe(source, timeLimit: 120)
            print("describe-file: \((path as NSString).lastPathComponent) (\(String(format: "%.2f", Date().timeIntervalSince(start))) s): \(r.text.replacingOccurrences(of: "\n", with: " | "))")
        }
    }

    // MARK: Helpers

    /// A render that doesn't return until `release()` and ignores
    /// cancellation, like a Vision call; then fails as unreadable, so a
    /// result that came from it rather than the deadline shows.
    final class Held: OwlImageSource, @unchecked Sendable {
        private let lock = NSLock()
        private var waiter: CheckedContinuation<Void, Never>?
        private var released = false
        private var began = false
        var started: Bool { lock.withLock { began } }
        func render(maxPixels: Int) async throws -> OwlRenderedImage {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                let now: Bool = lock.withLock {
                    began = true
                    if released { return true }
                    waiter = c
                    return false
                }
                if now { c.resume() }
            }
            throw OwlImageError.unreadable
        }
        func release() {
            let c: CheckedContinuation<Void, Never>? = lock.withLock {
                released = true
                defer { waiter = nil }
                return waiter
            }
            c?.resume()
        }
    }

    final class Counting: OwlImageSource, @unchecked Sendable {
        let inner: any OwlImageSource
        private let lock = NSLock()
        private var n = 0
        var count: Int { lock.withLock { n } }
        init(_ inner: any OwlImageSource) { self.inner = inner }
        func render(maxPixels: Int) async throws -> OwlRenderedImage {
            lock.withLock { n += 1 }
            return try await inner.render(maxPixels: maxPixels)
        }
    }

    /// A sky, a green field, a sun and OWLINK in big letters, as PNG.
    static func photoLikePNG(width: Int, height: Int) throws -> Data {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let sky = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                             colors: [CGColor(red: 0.35, green: 0.6, blue: 0.95, alpha: 1), CGColor(red: 0.7, green: 0.85, blue: 1, alpha: 1)] as CFArray,
                             locations: [0, 1])!
        ctx.drawLinearGradient(sky, start: CGPoint(x: 0, y: CGFloat(height)), end: CGPoint(x: 0, y: CGFloat(height) * 0.4), options: [.drawsAfterEndLocation])
        ctx.setFillColor(CGColor(red: 0.2, green: 0.55, blue: 0.2, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height * 2 / 5))
        ctx.setFillColor(CGColor(red: 1, green: 0.85, blue: 0.1, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: width * 3 / 4, y: height * 3 / 4, width: height / 6, height: height / 6))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        ("OWLINK" as NSString).draw(at: NSPoint(x: width / 8, y: height / 2),
                                     withAttributes: [.font: NSFont.boldSystemFont(ofSize: CGFloat(height) / 6), .foregroundColor: NSColor.black])
        NSGraphicsContext.restoreGraphicsState()
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        guard CGImageDestinationFinalize(dest) else { throw OwlImageError.unreadable }
        return out as Data
    }
}
