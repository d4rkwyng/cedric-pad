import Foundation
import Testing
@testable import CedricCore

@Suite struct ImageDetectionTests {
    static let png: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13] + Array("IHDR".utf8)
    static let jpeg: [UInt8] = [0xFF, 0xD8, 0xFF, 0xE0, 0, 16] + Array("JFIF".utf8)
    static func ftyp(_ brand: String) -> [UInt8] { [0, 0, 0, 24] + Array("ftyp\(brand)".utf8) + [0, 0, 0, 0] }

    @Test func imagesByTheirSignatureWhateverTheName() {
        let cases: [([UInt8], ImageFormat)] = [
            (Self.png, .png), (Self.jpeg, .jpeg), (Array("GIF89a".utf8) + [1, 0, 1, 0], .gif), (Array("GIF87a".utf8) + [1, 0], .gif),
            ([0x49, 0x49, 0x2A, 0x00, 8, 0, 0, 0], .tiff), ([0x4D, 0x4D, 0x00, 0x2A, 0, 0, 0, 8], .tiff),
            (Array("RIFF".utf8) + [0x24, 0, 0, 0] + Array("WEBPVP8 ".utf8), .webp),
            (Self.ftyp("heic"), .heic), (Self.ftyp("mif1"), .heif), (Self.ftyp("avif"), .avif),
            (Array("icns".utf8) + [0, 0, 0x10, 0], .icns),
            ([0, 0, 1, 0, 1, 0, 16, 16, 0, 0, 1, 0, 32, 0], .ico), ([0, 0, 2, 0, 1, 0, 32, 32, 0, 0], .cur),
            (Array("BM".utf8) + [0x46, 0, 0, 0, 0, 0, 0, 0, 0x36, 0, 0, 0, 40, 0, 0, 0], .bmp),
            (Array("8BPS".utf8) + [0, 1, 0, 0], .psd),
            ([0, 0, 0, 0x0C, 0x6A, 0x50, 0x20, 0x20, 0x0D, 0x0A, 0x87, 0x0A], .jpeg2000),
        ]
        for (bytes, format) in cases {
            #expect(ImageFormat.detect(bytes) == format, "\(format)")
            #expect(DocumentKind.detect(prefix: bytes, fileName: "download") == .image, "\(format) with no extension")
            #expect(DocumentKind.detect(prefix: bytes, fileName: "notes.txt") == .image, "\(format) named .txt")
        }
    }

    @Test func lookalikesAreText() {
        // "BM" text, a movie's ftyp, almost-signatures.
        #expect(DocumentKind.detect(prefix: Array("BMW owners club notes\n".utf8), fileName: "bmw.txt") == .text)
        #expect(DocumentKind.detect(prefix: Self.ftyp("isom"), fileName: "clip") == .text)
        #expect(DocumentKind.detect(prefix: Self.ftyp("qt  "), fileName: "clip") == .text)
        #expect(DocumentKind.detect(prefix: Array("GIF88a".utf8), fileName: "x") == .text)
        #expect(DocumentKind.detect(prefix: Array("RIFF....WAVE".utf8), fileName: "x") == .text)
        #expect(DocumentKind.detect(prefix: [0x89, 0x50, 0x4E, 0x47], fileName: "x") == .text)
        #expect(DocumentKind.detect(prefix: Array("icns".utf8), fileName: "x") == .text) // too short
        #expect(DocumentKind.detect(prefix: [UInt8](), fileName: "empty") == .text)
        // SVG is text (it has the preview), even named .svg.
        #expect(DocumentKind.detect(prefix: Array("<svg xmlns=\"http://www.w3.org/2000/svg\"".utf8), fileName: "logo.svg") == .text)
        // PDF still wins.
        #expect(DocumentKind.detect(prefix: Array("%PDF-1.7".utf8), fileName: "scan.png") == .pdf)
    }

    @Test func imageNamesWithoutASignatureGoToTheViewer() {
        // A damaged .png gets the viewer's error, not binary in the editor; TGA has no signature at all.
        #expect(DocumentKind.detect(prefix: Array("garbage".utf8), fileName: "broken.PNG") == .image)
        #expect(DocumentKind.detect(prefix: [0, 0, 2, 0, 0, 0, 0, 0], fileName: "old.tga") == .image)
        #expect(ImageFormat.forExtension("a.JPEG") == .jpeg)
        #expect(ImageFormat.forExtension("a.svg") == nil)
        #expect(ImageFormat.forExtension("png") == nil)
    }

    @Test func detectReadsTheFile() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let img = dir.appendingPathComponent("photo-no-ext")
        try Data(Self.jpeg + [UInt8](repeating: 0, count: 64)).write(to: img)
        #expect(DocumentKind.detect(url: img) == .image)
        #expect(DocumentKind.detect(url: dir.appendingPathComponent("missing.gif")) == .image)
    }
}

@Suite struct ImageZoomTests {
    @Test func fitNeverEnlarges() {
        #expect(ImageZoom.fitScale(imageWidth: 4000, imageHeight: 2000, viewWidth: 1000, viewHeight: 1000) == 0.25)
        #expect(ImageZoom.fitScale(imageWidth: 1000, imageHeight: 4000, viewWidth: 1000, viewHeight: 1000) == 0.25)
        #expect(ImageZoom.fitScale(imageWidth: 16, imageHeight: 16, viewWidth: 1000, viewHeight: 700) == 1)
        #expect(ImageZoom.fitScale(imageWidth: 0, imageHeight: 16, viewWidth: 1000, viewHeight: 700) == 1)
        #expect(ImageZoom.fitScale(imageWidth: 1_000_000, imageHeight: 10, viewWidth: 100, viewHeight: 100) == ImageZoom.minScale)
        #expect(ImageZoom.clamp(100) == ImageZoom.maxScale)
    }

    @Test func bigImagesAreDecodedSmaller() {
        #expect(ImageZoom.displayMaxPixelSize(width: 4000, height: 3000) == 4000)
        #expect(ImageZoom.displayMaxPixelSize(width: 6000, height: 6000) == 6000) // 36 MP: whole
        let side = ImageZoom.displayMaxPixelSize(width: 12000, height: 12000)
        #expect(side == 5656, "\(side)")
        let s2 = ImageZoom.displayMaxPixelSize(width: 12000, height: 8000) // 96 MP
        #expect(Double(s2) * Double(s2) * 8000 / 12000 <= ImageZoom.displayPixelBudget)
        #expect(ImageZoom.displayMaxPixelSize(width: 0, height: 0) == 1)
        // A long panorama: within the GPU's texture size.
        #expect(ImageZoom.displayMaxPixelSize(width: 20000, height: 1500) == ImageZoom.maxDisplaySide)
    }

    @Test func statusText() {
        #expect(ImageInfoText.status(width: 4032, height: 3024, fileBytes: 2_412_000, format: "HEIC", colorSpace: "Display P3")
                == "4032 × 3024 px · 2.4 MB · HEIC · Display P3")
        #expect(ImageInfoText.status(width: 10, height: 10, fileBytes: 812, format: "GIF", colorSpace: nil, frames: 12)
                == "10 × 10 px · 812 bytes · GIF · 12 frames")
        #expect(ImageInfoText.fileSize(1) == "1 byte")
        #expect(ImageInfoText.fileSize(45_300) == "45 KB")
        #expect(ImageInfoText.fileSize(999_999) == "1.0 MB")
        #expect(ImageInfoText.fileSize(3_200_000_000) == "3.2 GB")
        #expect(ImageInfoText.colorSpaceName(profile: "sRGB IEC61966-2.1", model: "RGB") == "sRGB")
        #expect(ImageInfoText.colorSpaceName(profile: nil, model: "Gray") == "Gray")
        #expect(ImageInfoText.colorSpaceName(profile: "  ", model: nil) == nil)
        #expect(ImageZoom.percent(1.25) == "125%")
        #expect(ImageZoom.percent(0.054) == "5.4%")
        #expect(ImageZoom.percent(0.1) == "10%")
    }
}

@Suite struct ViewerSessionTests {
    @Test func imageTabsRoundTrip() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SessionStore(directory: dir)
        let img = SessionTab(path: "/tmp/photo.heic", image: ImageTabState(scale: 2, centerX: 0.25, centerY: 0.75))
        let fitted = SessionTab(path: "/tmp/icon.png", image: ImageTabState())
        let text = SessionTab(path: "/tmp/a.txt")
        let s = Session(windows: [SessionWindow(tabs: [text, img, fitted], selectedTab: 1)], closedTabs: [img])
        try store.save(s)
        let back = try #require(SessionStore(directory: dir).load())
        #expect(back == s)
        #expect(back.windows[0].tabs[1].image == ImageTabState(scale: 2, centerX: 0.25, centerY: 0.75))
        #expect(back.windows[0].tabs[2].image?.scale == nil)
        #expect(back.windows[0].tabs[2].isViewer)
        #expect(!back.windows[0].tabs[0].isViewer)
        #expect(back.closedTabs?.first?.image?.scale == 2)
    }

    @Test func textTabsWriteNoViewerKeys() throws {
        let json = String(decoding: try JSONEncoder().encode(SessionTab(path: "/tmp/a.txt")), as: UTF8.self)
        #expect(!json.contains("\"image\""))
    }

    @Test func badImageStateDecodesSafely() throws {
        func decode(_ j: String) throws -> ImageTabState { try JSONDecoder().decode(ImageTabState.self, from: Data(j.utf8)) }
        #expect(try decode("{}") == ImageTabState())
        #expect(try decode(#"{"scale":-2,"centerX":7,"centerY":-1}"#) == ImageTabState(scale: nil, centerX: 1, centerY: 0))
        #expect(try decode(#"{"scale":1000}"#) == ImageTabState(scale: ImageZoom.maxScale))
        // Older sessions (no image key) decode as before.
        let old = #"{"id":"\#(UUID().uuidString)","path":"/tmp/x.png","hasBuffer":false,"encoding":"utf8","lineEnding":"lf","selectionLocation":0,"selectionLength":0,"topLine":0}"#
        let t = try JSONDecoder().decode(SessionTab.self, from: Data(old.utf8))
        #expect(t.image == nil && !t.isViewer)
    }
}
