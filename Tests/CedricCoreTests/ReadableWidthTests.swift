import Foundation
import Testing
@testable import CedricCore

@Suite struct ReadableWidthTests {
    @Test func offForEveryLanguage() {
        #expect(!ReadableWidth.defaultOn(for: .markdown))
        #expect(!ReadableWidth.defaultOn(for: .plain))
        for l in Language.allCases { #expect(!ReadableWidth.defaultOn(for: l)) }
    }

    @Test func gutterSitsBesideTheColumnWhenTheMarginAllows() {
        // A 214 pt inset and a 48 pt gutter: the numbers start at 166, not at the window edge.
        #expect(ReadableWidth.overlaidGutterMinX(textMinX: 214, gutterWidth: 48, sidebarWidth: 0) == 166)
        // The normal 4 pt inset is narrower than the gutter: stay at the edge.
        #expect(ReadableWidth.overlaidGutterMinX(textMinX: 4, gutterWidth: 48, sidebarWidth: 0) == nil)
        // The gutter must not cover the sidebar.
        #expect(ReadableWidth.overlaidGutterMinX(textMinX: 80, gutterWidth: 48, sidebarWidth: 40) == nil)
        #expect(ReadableWidth.overlaidGutterMinX(textMinX: 200, gutterWidth: 48, sidebarWidth: 40) == 152)
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
