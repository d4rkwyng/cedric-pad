import Foundation
import Testing
@testable import CedricCore

@Suite struct DocumentKindTests {
    let pdfBytes = Array("%PDF-1.7\n%\u{e2}\u{e3}\n1 0 obj".utf8)

    @Test func pdfByMagicBytesWhateverTheName() {
        #expect(DocumentKind.detect(prefix: pdfBytes, fileName: "report.pdf") == .pdf)
        #expect(DocumentKind.detect(prefix: pdfBytes, fileName: "download") == .pdf)
        #expect(DocumentKind.detect(prefix: pdfBytes, fileName: "attachment.dat") == .pdf)
        #expect(DocumentKind.detect(prefix: pdfBytes, fileName: "notes.txt") == .pdf)
    }

    @Test func textIsText() {
        #expect(DocumentKind.detect(prefix: Array("hello".utf8), fileName: "a.txt") == .text)
        #expect(DocumentKind.detect(prefix: [UInt8](), fileName: "empty.md") == .text)
        // Too short, or almost the header.
        #expect(DocumentKind.detect(prefix: Array("%PDF".utf8), fileName: "x") == .text)
        #expect(DocumentKind.detect(prefix: Array("%PDX-1.4".utf8), fileName: "x") == .text)
        #expect(DocumentKind.detect(prefix: Array("%pdf-1.4".utf8), fileName: "x") == .text)
        // The header later in the file (a source file that mentions it) isn't a PDF.
        #expect(DocumentKind.detect(prefix: Array("let m = \"%PDF-\"".utf8), fileName: "DocumentKind.swift") == .text)
        // A UTF-8 BOM before it: text.
        #expect(DocumentKind.detect(prefix: [0xEF, 0xBB, 0xBF] + Array("%PDF-".utf8), fileName: "x.txt") == .text)
    }

    @Test func pdfNameWithoutHeaderIsStillAPDF() {
        // So a damaged PDF gets the viewer's error, not binary in the editor.
        #expect(DocumentKind.detect(prefix: Array("garbage".utf8), fileName: "broken.pdf") == .pdf)
        #expect(DocumentKind.detect(prefix: [UInt8](), fileName: "SCAN.PDF") == .pdf)
        #expect(DocumentKind.hasPDFExtension("a.Pdf"))
        #expect(!DocumentKind.hasPDFExtension("pdf"))
        #expect(!DocumentKind.hasPDFExtension("a.pdf.txt"))
    }

    @Test func detectReadsTheFile() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let pdf = dir.appendingPathComponent("no-extension")
        try Data(pdfBytes).write(to: pdf)
        let text = dir.appendingPathComponent("plain.txt")
        try Data("just text\n".utf8).write(to: text)
        let short = dir.appendingPathComponent("short")
        try Data("%P".utf8).write(to: short)
        #expect(DocumentKind.detect(url: pdf) == .pdf)
        #expect(DocumentKind.detect(url: text) == .text)
        #expect(DocumentKind.detect(url: short) == .text)
        #expect(DocumentKind.detect(url: dir.appendingPathComponent("missing.txt")) == .text)
        #expect(DocumentKind.detect(url: dir.appendingPathComponent("missing.pdf")) == .pdf)
    }
}

@Suite struct PDFSessionTests {
    @Test func pdfTabRoundTrips() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SessionStore(directory: dir)
        let pdf = SessionTab(path: "/tmp/manual.pdf", pdf: PDFTabState(page: 41, scale: 1.5, showsThumbnails: true))
        let fitted = SessionTab(path: "/tmp/other.pdf", pdf: PDFTabState(page: 0))
        let text = SessionTab(path: "/tmp/a.txt", topLine: 3)
        let session = Session(windows: [SessionWindow(tabs: [text, pdf, fitted], selectedTab: 1)])
        try store.save(session)
        let back = try #require(SessionStore(directory: dir).load())
        #expect(back == session)
        #expect(back.windows[0].tabs[1].pdf == PDFTabState(page: 41, scale: 1.5, showsThumbnails: true))
        #expect(back.windows[0].tabs[2].pdf?.scale == nil)
        #expect(back.windows[0].tabs[0].pdf == nil)
    }

    @Test func textTabsDontWriteAPDFKey() throws {
        let data = try JSONEncoder().encode(SessionTab(path: "/tmp/a.txt"))
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(!json.contains("\"pdf\""))
    }

    @Test func olderSessionsDecodeWithoutPDFState() throws {
        let json = """
        {"version":1,"untitledCounter":0,"windows":[{"selectedTab":0,"tabs":[
          {"id":"\(UUID().uuidString)","path":"/tmp/x.pdf","hasBuffer":false,"encoding":"utf8","lineEnding":"lf",
           "selectionLocation":0,"selectionLength":0,"topLine":0}]}]}
        """
        let s = try JSONDecoder().decode(Session.self, from: Data(json.utf8))
        #expect(s.windows[0].tabs[0].pdf == nil)
    }

    @Test func partialAndBadPDFStateDecodesSafely() throws {
        func decode(_ j: String) throws -> PDFTabState { try JSONDecoder().decode(PDFTabState.self, from: Data(j.utf8)) }
        #expect(try decode("{}") == PDFTabState())
        #expect(try decode(#"{"page":3}"#) == PDFTabState(page: 3))
        #expect(try decode(#"{"page":-4,"scale":0}"#) == PDFTabState(page: 0, scale: nil))
        #expect(try decode(#"{"page":2,"scale":-1,"showsThumbnails":true}"#) == PDFTabState(page: 2, scale: nil, showsThumbnails: true))
    }

    @Test func savedPageIsClampedToTheDocument() {
        #expect(PDFTabState(page: 9).clampedPage(pageCount: 3) == 2)
        #expect(PDFTabState(page: 1).clampedPage(pageCount: 3) == 1)
        #expect(PDFTabState(page: 5).clampedPage(pageCount: 0) == 0)
        #expect(PDFTabState.clampScale(100) == PDFTabState.maxScale)
        #expect(PDFTabState.clampScale(0.001) == PDFTabState.minScale)
        #expect(PDFTabState.clampScale(1.25) == 1.25)
    }

    @Test func closedPDFTabsKeepTheirState() {
        let pdf = SessionTab(path: "/tmp/m.pdf", pdf: PDFTabState(page: 7))
        let r = ClosedTabs.push(pdf, onto: [])
        #expect(r.list.last?.pdf?.page == 7)
    }
}

@Suite struct PDFInputTests {
    @Test func goToPageParsesPageNumbers() {
        #expect(PageNumberInput.parse("1", pageCount: 3) == 0)
        #expect(PageNumberInput.parse(" 3 ", pageCount: 3) == 2)
        #expect(PageNumberInput.parse("4", pageCount: 3) == nil)
        #expect(PageNumberInput.parse("0", pageCount: 3) == nil)
        #expect(PageNumberInput.parse("two", pageCount: 3) == nil)
        #expect(PageNumberInput.parse("", pageCount: 3) == nil)
    }

    @Test func extractedTextGetsLFLineEndings() {
        #expect(PDFText.normalize("a\r\nb\rc\nd") == "a\nb\nc\nd")
        #expect(PDFText.normalize("") == "")
    }
}
