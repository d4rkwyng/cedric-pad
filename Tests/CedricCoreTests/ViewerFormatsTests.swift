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

@Suite struct OfficeDetectionTests {
    let zip: [UInt8] = [0x50, 0x4B, 0x03, 0x04, 20, 0, 0, 0]

    @Test func officeByHeaderAndName() {
        #expect(OfficeFormat.detect(prefix: zip, fileName: "report.docx") == .word)
        #expect(OfficeFormat.detect(prefix: zip, fileName: "budget.xlsx") == .spreadsheet)
        #expect(OfficeFormat.detect(prefix: zip, fileName: "deck.pptx") == .presentation)
        #expect(OfficeFormat.detect(prefix: zip, fileName: "letter.pages") == .pages)
        #expect(OfficeFormat.detect(prefix: zip, fileName: "talk.key") == .keynote)
        #expect(OfficeFormat.detect(prefix: OfficeFormat.oleMagic, fileName: "old.doc") == .word)
        #expect(OfficeFormat.detect(prefix: OfficeFormat.oleMagic, fileName: "old.xls") == .spreadsheet)
        #expect(OfficeFormat.detect(prefix: OfficeFormat.oleMagic, fileName: "download") == .word)
        #expect(DocumentKind.detect(prefix: OfficeFormat.oleMagic, fileName: "download") == .office)
        #expect(DocumentKind.detect(prefix: zip, fileName: "report.docx") == .office)
        // A damaged .docx goes to the viewer too.
        #expect(DocumentKind.detect(prefix: Array("junk".utf8), fileName: "r.docx") == .office)
    }

    @Test func textStaysText() {
        // A PEM key named .key is text; so is an RTF named .doc, and a plain zip.
        #expect(DocumentKind.detect(prefix: Array("-----BEGIN PRIVATE KEY-----".utf8), fileName: "server.key") == .text)
        #expect(DocumentKind.detect(prefix: Array("{\\rtf1\\ansi".utf8), fileName: "letter.doc") == .text)
        #expect(DocumentKind.detect(prefix: zip, fileName: "archive.zip") == .text)
        #expect(DocumentKind.detect(prefix: Array("plain".utf8), fileName: "notes.rtf") == .text)
    }

    @Test func zipContentsTellOOXMLApart() {
        #expect(OfficeFormat.fromZipEntries(["[Content_Types].xml", "_rels/.rels", "word/document.xml"]) == .word)
        #expect(OfficeFormat.fromZipEntries(["[Content_Types].xml", "xl/workbook.xml"]) == .spreadsheet)
        #expect(OfficeFormat.fromZipEntries(["[Content_Types].xml", "ppt/presentation.xml"]) == .presentation)
        #expect(OfficeFormat.fromZipEntries(["Index/Document.iwa", "Metadata/Properties.plist"]) == .pages)
        #expect(OfficeFormat.fromZipEntries(["word/document.xml"]) == nil) // no content types
        #expect(OfficeFormat.fromZipEntries(["src/main.swift"]) == nil)
        #expect(OfficeFormat.forDirectory("Letter.pages") == .pages)
        #expect(OfficeFormat.forDirectory("Notes.rtfd") == .rtfd)
        #expect(OfficeFormat.forDirectory("Folder") == nil)
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pkg = dir.appendingPathComponent("Letter.pages"), folder = dir.appendingPathComponent("src")
        try? FileManager.default.createDirectory(at: pkg, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        #expect(DocumentKind.detect(url: pkg) == .office && OfficeFormat.detect(url: pkg) == .pages)
        #expect(DocumentKind.detect(url: folder) == .text)
        #expect(OfficeFormat.word.hasText && OfficeFormat.rtfd.hasText && !OfficeFormat.spreadsheet.hasText)
    }

    @Test(.offPool) func aZipWithNoExtensionIsReadInside() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let x = try XLSXFixture.make(in: dir, name: "download")
        #expect(DocumentKind.detect(url: x) == .office)
        #expect(OfficeFormat.detect(url: x) == .spreadsheet)
        let plain = try XLSXFixture.zip(in: dir, name: "plain.zip", files: ["a.txt": "hello"])
        #expect(DocumentKind.detect(url: plain) == .text)
    }
}

/// A minimal .xlsx: hand-written parts, zipped with /usr/bin/zip.
enum XLSXFixture {
    static let sheet = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>
    <row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1" t="s"><v>1</v></c><c r="C1" t="inlineStr"><is><t>Note, "quoted"</t></is></c></row>
    <row r="2"><c r="A2" t="s"><v>2</v></c><c r="B2"><v>3.5</v></c><c r="C2" t="b"><v>1</v></c></row>
    <row r="4"><c r="A4" t="str"><f>CONCAT("a","b")</f><v>ab</v></c><c r="B4"><f>SUM(B2:B3)</f><v>7</v></c><c r="D4"><f>NOW()</f></c></row>
    <row r="5"><c r="A5" t="inlineStr"><is><r><t>rich </t></r><r><t>text</t></r></is></c><c r="B5" t="e"><v>#DIV/0!</v></c><c r="C5" t="s"><v>3</v></c></row>
    </sheetData></worksheet>
    """
    static let shared = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" count="4" uniqueCount="4">
    <si><t>Name</t></si><si><t>Price</t></si><si><r><t>Owl</t></r><r><rPr><b/></rPr><t> &amp; Co</t></r></si><si><t xml:space="preserve">two
    lines</t></si></sst>
    """
    static let workbook = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
    <sheets><sheet name="Prices" sheetId="1" r:id="rId1"/><sheet name="Other" sheetId="2" r:id="rId2"/></sheets></workbook>
    """
    static let rels = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
    <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet2.xml"/>
    <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/data.xml"/>
    </Relationships>
    """
    static let types = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="xml" ContentType="application/xml"/></Types>
    """
    /// The CSV the sheet above makes.
    static let expectedCSV = #"""
    Name,Price,"Note, ""quoted"""
    Owl & Co,3.5,TRUE
    ,,
    ab,7,
    rich text,#DIV/0!,"two
    lines"

    """#

    static func zip(in dir: URL, name: String, files: [String: String]) throws -> URL {
        let src = dir.appendingPathComponent("src-\(name)")
        for (path, text) in files {
            let u = src.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: u, atomically: true, encoding: .utf8)
        }
        let out = dir.appendingPathComponent(name)
        // zip adds ".zip" to a name without an extension: make it, then move it.
        let made = dir.appendingPathComponent("made-\(UUID().uuidString).zip")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        p.currentDirectoryURL = src
        // -X: no extra attributes; [Content_Types].xml first, as Office writes it.
        p.arguments = ["-X", "-q", "-r", made.path] + files.keys.sorted { a, b in a.hasPrefix("[") != b.hasPrefix("[") ? a.hasPrefix("[") : a < b }
        p.standardOutput = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        try FileManager.default.moveItem(at: made, to: out)
        return out
    }

    static func make(in dir: URL, name: String = "book.xlsx") throws -> URL {
        try zip(in: dir, name: name, files: [
            "[Content_Types].xml": types, "xl/workbook.xml": workbook, "xl/_rels/workbook.xml.rels": rels,
            "xl/sharedStrings.xml": shared, "xl/worksheets/data.xml": sheet,
            "xl/worksheets/sheet2.xml": "<worksheet><sheetData/></worksheet>",
        ])
    }
}

@Suite struct ZipAndXLSXTests {
    @Test(.offPool) func zipReadsStoredAndDeflatedEntries() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let big = String(repeating: "hoot hoot owl\n", count: 2000)
        let z = try XLSXFixture.zip(in: dir, name: "t.zip", files: ["a/big.txt": big, "tiny.txt": "x"])
        let a = try ZipArchive(url: z)
        #expect(Set(a.entries.map(\.name)).isSuperset(of: ["a/big.txt", "tiny.txt"]))
        #expect(a.entry("a/big.txt")?.method == 8, "zip deflates the big one")
        #expect(String(decoding: try a.contents(of: "a/big.txt"), as: UTF8.self) == big)
        #expect(String(decoding: try a.contents(of: "tiny.txt"), as: UTF8.self) == "x")
        #expect(throws: ZipArchive.ZipError.missing("nope")) { try a.contents(of: "nope") }
        #expect(throws: ZipArchive.ZipError.notAZip) { try ZipArchive(data: Data("not a zip at all, no".utf8)) }
        #expect(throws: ZipArchive.ZipError.notAZip) { try ZipArchive(data: Data()) }
    }

    @Test(.offPool) func firstSheetAsCSV() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let x = try XLSXFixture.make(in: dir)
        let (name, csv) = try XLSXSheet.firstSheetCSV(url: x)
        #expect(name == "Prices")
        #expect(csv == XLSXFixture.expectedCSV, "\(csv)")
    }

    @Test func cellReferences() {
        #expect(XLSXSheet.cellRef("A1")! == (0, 0))
        #expect(XLSXSheet.cellRef("B12")! == (11, 1))
        #expect(XLSXSheet.cellRef("AA3")! == (2, 26))
        #expect(XLSXSheet.cellRef("$C$4")! == (3, 2))
        #expect(XLSXSheet.cellRef("A0") == nil)
        #expect(XLSXSheet.cellRef("12") == nil)
        #expect(XLSXSheet.cellRef("A1B") == nil)
        #expect(XLSXSheet.normalize("xl/worksheets/../worksheets/./s.xml") == "xl/worksheets/s.xml")
    }

    @Test func sheetsWithoutRefsOrSharedStrings() {
        let xml = Data("<worksheet><sheetData><row><c><v>1</v></c><c t=\"s\"><v>9</v></c><c><v>3</v></c></row><row><c t=\"inlineStr\"><is><t>x</t></is></c></row></sheetData></worksheet>".utf8)
        // A shared-string index past the table is an empty cell, not a crash.
        #expect(XLSXSheet.csv(XLSXSheet.cells(xml, shared: [])) == "1,,3\nx,,\n")
        #expect(XLSXSheet.csv([]) == "")
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
    @Test func imageAndOfficeTabsRoundTrip() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SessionStore(directory: dir)
        let img = SessionTab(path: "/tmp/photo.heic", image: ImageTabState(scale: 2, centerX: 0.25, centerY: 0.75))
        let fitted = SessionTab(path: "/tmp/icon.png", image: ImageTabState())
        let doc = SessionTab(path: "/tmp/report.docx", office: OfficeTabState())
        let text = SessionTab(path: "/tmp/a.txt")
        let s = Session(windows: [SessionWindow(tabs: [text, img, fitted, doc], selectedTab: 1)], closedTabs: [img])
        try store.save(s)
        let back = try #require(SessionStore(directory: dir).load())
        #expect(back == s)
        #expect(back.windows[0].tabs[1].image == ImageTabState(scale: 2, centerX: 0.25, centerY: 0.75))
        #expect(back.windows[0].tabs[2].image?.scale == nil)
        #expect(back.windows[0].tabs[3].office != nil && back.windows[0].tabs[3].isViewer)
        #expect(!back.windows[0].tabs[0].isViewer)
        #expect(back.closedTabs?.first?.image?.scale == 2)
    }

    @Test func textTabsWriteNoViewerKeys() throws {
        let json = String(decoding: try JSONEncoder().encode(SessionTab(path: "/tmp/a.txt")), as: UTF8.self)
        #expect(!json.contains("\"image\"") && !json.contains("\"office\""))
    }

    @Test func badImageStateDecodesSafely() throws {
        func decode(_ j: String) throws -> ImageTabState { try JSONDecoder().decode(ImageTabState.self, from: Data(j.utf8)) }
        #expect(try decode("{}") == ImageTabState())
        #expect(try decode(#"{"scale":-2,"centerX":7,"centerY":-1}"#) == ImageTabState(scale: nil, centerX: 1, centerY: 0))
        #expect(try decode(#"{"scale":1000}"#) == ImageTabState(scale: ImageZoom.maxScale))
        // Older sessions (no image key) decode as before.
        let old = #"{"id":"\#(UUID().uuidString)","path":"/tmp/x.png","hasBuffer":false,"encoding":"utf8","lineEnding":"lf","selectionLocation":0,"selectionLength":0,"topLine":0}"#
        let t = try JSONDecoder().decode(SessionTab.self, from: Data(old.utf8))
        #expect(t.image == nil && t.office == nil && !t.isViewer)
    }
}
