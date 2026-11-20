import Foundation
import Testing
@testable import CedricCore

@Suite struct ReadableWidthTests {
    @Test func onForProseOffForCode() {
        #expect(ReadableWidth.defaultOn(for: .markdown))
        #expect(ReadableWidth.defaultOn(for: .plain))
        for l in [Language.swift, .python, .json, .yaml, .shell, .csv] { #expect(!ReadableWidth.defaultOn(for: l)) }
    }

    @Test func columnsClampedTo60Through100() {
        #expect(ReadableWidth.clamp(10) == 60)
        #expect(ReadableWidth.clamp(72) == 72)
        #expect(ReadableWidth.clamp(500) == 100)
        #expect(ReadableWidth.defaultColumns == 72)
    }

    @Test func columnCentredNeverUnderTheNormalInset() {
        // 72 characters of 7.8 pt with 5 pt padding: 572 pt.
        let col = ReadableWidth.columnWidth(columns: 72, charWidth: 7.8, padding: 5)
        #expect(col == 572)
        // A 1,000 pt view: 214 pt each side.
        #expect(ReadableWidth.inset(viewWidth: 1000, column: col) == 214)
        // Narrower than the column: the editor's usual 4 pt.
        #expect(ReadableWidth.inset(viewWidth: 500, column: col) == ReadableWidth.minimumInset)
        // Out-of-range columns are clamped first.
        #expect(ReadableWidth.columnWidth(columns: 200, charWidth: 10, padding: 0) == 1000)
    }
}
