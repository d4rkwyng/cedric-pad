import Foundation
import Testing
@testable import CedricCore

@Suite struct PDFReaderTests {
    @Test func fitPageUsesTheTighterSide() {
        // A portrait page in a wide view: height decides.
        #expect(PDFReader.fitPageScale(pageWidth: 612, pageHeight: 792, viewWidth: 1000, viewHeight: 396, margin: 0) == 0.5)
        // A wide view, a tall narrow one: width decides.
        #expect(PDFReader.fitPageScale(pageWidth: 600, pageHeight: 800, viewWidth: 300, viewHeight: 2000, margin: 0) == 0.5)
        // The margin comes off both sides.
        #expect(PDFReader.fitPageScale(pageWidth: 100, pageHeight: 100, viewWidth: 220, viewHeight: 220, margin: 10) == 2)
        // Degenerate sizes: actual size, clamped.
        #expect(PDFReader.fitPageScale(pageWidth: 0, pageHeight: 792, viewWidth: 1000, viewHeight: 400, margin: 0) == 1)
        #expect(PDFReader.fitPageScale(pageWidth: 612, pageHeight: 792, viewWidth: 1, viewHeight: 1, margin: 0) == PDFTabState.minScale)
    }

    @Test func fitPageSwapsSidesWhenRotated() {
        // Turned a quarter: the page's width is now its height.
        #expect(PDFReader.fitPageScale(pageWidth: 612, pageHeight: 792, viewWidth: 792, viewHeight: 306, margin: 0, rotation: 90) == 0.5)
    }

    @Test func rotationStaysInWholeTurns() {
        #expect(PDFReader.rotated(0, by: 90) == 90)
        #expect(PDFReader.rotated(270, by: 90) == 0)
        #expect(PDFReader.rotated(0, by: -90) == 270)
        #expect(PDFReader.rotated(90, by: -90) == 0)
        #expect(PDFReader.rotated(45, by: 90) == 90) // not a quarter turn: snapped
    }

    @Test func overlayDropsLowestPriorityGroupsToFit() {
        let groups = [PDFReader.Group(width: 100, priority: 0), PDFReader.Group(width: 80, priority: 2),
                      PDFReader.Group(width: 60, priority: 1), PDFReader.Group(width: 40, priority: 3)]
        #expect(PDFReader.visibleGroups(groups, spacing: 10, available: 1000) == [true, true, true, true])
        // 100+80+60+40 + 3*10 = 310; at 300 the priority-3 group goes.
        #expect(PDFReader.visibleGroups(groups, spacing: 10, available: 300) == [true, true, true, false])
        // Then priority 2, then 1; priority 0 always stays.
        #expect(PDFReader.visibleGroups(groups, spacing: 10, available: 175) == [true, false, true, false])
        #expect(PDFReader.visibleGroups(groups, spacing: 10, available: 20) == [true, false, false, false])
    }

    @Test func autoHideTiming() {
        let h = PDFReader.AutoHide(delay: 2)
        #expect(!h.shouldHide(idle: 1.9, hovering: false))
        #expect(h.shouldHide(idle: 2, hovering: false))
        #expect(!h.shouldHide(idle: 60, hovering: true))
        #expect(!h.shouldHide(idle: 60, hovering: false, editing: true))
    }

    @Test func pageNavigation() {
        #expect(PDFReader.page(0, moving: -1, pageCount: 5) == nil)
        #expect(PDFReader.page(0, moving: 1, pageCount: 5) == 1)
        #expect(PDFReader.page(4, moving: 1, pageCount: 5) == nil)
        #expect(PDFReader.page(2, moving: -1, pageCount: 5) == 1)
        #expect(PDFReader.pageLabel(index: 2, pageCount: 9) == "of 9")
    }
}
