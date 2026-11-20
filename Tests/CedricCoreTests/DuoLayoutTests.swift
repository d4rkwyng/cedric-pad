import CoreGraphics
import Foundation
import Testing
@testable import CedricCore

/// The iOS app's layout rules for iPhone Duo (fold, rounded corners) and
/// its owl, as pure geometry: FoldLayout, EditorContinuity, OwlBadge and
/// OwlPlacement's y-down helpers.
@Suite struct DuoLayoutTests {
    // An unfolded Duo-like screen in points (not Apple's figures: shapes only).
    let screen = CGRect(x: 0, y: 0, width: 620, height: 880)
    // A fold down the middle, 20 pt with its margins.
    var fold: CGRect { CGRect(x: 300, y: 0, width: 20, height: 880) }

    // MARK: Split

    @Test func splitIsEqualHalvesWithoutAFold() {
        let s = FoldLayout.split(content: CGRect(x: 0, y: 0, width: 401, height: 800), folds: [])
        #expect(s.leading == 200)
        #expect(s.gap == 1)
    }

    @Test func splitSeamSitsOnTheFold() {
        let content = CGRect(x: 0, y: 100, width: 620, height: 700)
        let s = FoldLayout.split(content: content, folds: [fold])
        #expect(s.leading == 300)
        #expect(s.gap == 20)
        // The trailing pane starts right after the fold.
        #expect(content.minX + s.leading + s.gap == fold.maxX)
    }

    @Test func splitSeamOnTheFoldWithAsymmetricSafeArea() {
        // A vertical bar on the leading edge pushes the content right: the
        // seam still lands on the fold, not at the content's middle.
        let content = CGRect(x: 70, y: 0, width: 550, height: 880)
        let s = FoldLayout.split(content: content, folds: [fold])
        #expect(content.minX + s.leading == fold.minX)
        #expect(s.leading == 230)
    }

    @Test func splitRightToLeft() {
        let content = CGRect(x: 0, y: 0, width: 620, height: 880)
        let s = FoldLayout.split(content: content, folds: [fold], rightToLeft: true)
        #expect(s.leading == 300)   // 620 - 320
    }

    @Test func splitIgnoresAZeroWidthFlatFoldAsGap() {
        let flat = CGRect(x: 310, y: 0, width: 0, height: 880)
        let s = FoldLayout.split(content: screen, folds: [flat], spacing: 1)
        #expect(s.gap == 1)
        #expect(abs(s.leading + 0.5 - 310) < 0.01)   // centred on it
    }

    @Test func foldAtTheEdgeOrHorizontalDoesNotSplit() {
        let edge = CGRect(x: 10, y: 0, width: 20, height: 880)
        let flatBand = CGRect(x: 0, y: 430, width: 620, height: 20)
        #expect(FoldLayout.crossingFolds([edge, flatBand], content: screen).isEmpty)
        #expect(FoldLayout.split(content: screen, folds: [edge, flatBand]).leading == (620 - 1) / 2)
    }

    // MARK: Lanes (toast, bubble)

    @Test func laneIsTheWholeAreaWithoutAFold() {
        let area = CGRect(x: 0, y: 50, width: 400, height: 700)
        #expect(FoldLayout.lane(in: area, folds: [], trailing: true) == area)
    }

    @Test func laneKeepsOffTheFold() {
        let area = CGRect(x: 0, y: 50, width: 620, height: 700)
        let t = FoldLayout.lane(in: area, folds: [fold], trailing: true)
        #expect(t.minX == fold.maxX + 8 && t.maxX == area.maxX)
        #expect(!t.intersects(fold))
        let l = FoldLayout.lane(in: area, folds: [fold], trailing: false)
        #expect(l.minX == 0 && l.maxX == fold.minX - 8)
        // Right to left: trailing is the left half.
        #expect(FoldLayout.lane(in: area, folds: [fold], trailing: true, rightToLeft: true) == l)
    }

    // MARK: Safe area (rounded corners, sensors, vertical bars)

    @Test func barFramesInsideTheSafeArea() {
        // Portrait phone: 34 pt home indicator; the status row sits on the
        // margins inside the safe area, not on the view's bottom edge.
        let bounds = CGRect(x: 0, y: 0, width: 402, height: 874)
        let safe = FoldLayout.inset(bounds, top: 62, left: 0, bottom: 34, right: 0)
        #expect(safe == CGRect(x: 0, y: 62, width: 402, height: 778))
        let row = CGRect(x: 16, y: safe.maxY - 4 - 22, width: 370, height: 22)
        #expect(FoldLayout.allInside([row], safe))
        // The old layout: the row 4 pt above the screen's bottom edge, in
        // the rounded corner.
        let old = CGRect(x: 8, y: bounds.maxY - 4 - 22, width: 386, height: 22)
        #expect(!FoldLayout.allInside([old], safe))
        // Landscape with a vertical bar on the leading edge.
        let land = FoldLayout.inset(CGRect(x: 0, y: 0, width: 874, height: 402), top: 0, left: 62, bottom: 21, right: 62)
        #expect(!FoldLayout.allInside([CGRect(x: 10, y: 360, width: 80, height: 20)], land))
        #expect(FoldLayout.allInside([CGRect(x: 70, y: 350, width: 80, height: 20), .zero], land))
    }

    // MARK: Continuity across fold and unfold

    @Test func continuityRestoresSelectionAndScroll() {
        let c = EditorContinuity(selection: NSRange(location: 120, length: 30), contentOffset: CGPoint(x: 0, y: 900), wasEditing: true)
        #expect(c.restoredSelection(length: 1000) == NSRange(location: 120, length: 30))
        #expect(c.restoredOffset(maxOffset: CGPoint(x: 0, y: 2000)) == CGPoint(x: 0, y: 900))
        #expect(c.wasEditing)
    }

    @Test func continuityClampsWhenTheTextShrank() {
        let c = EditorContinuity(selection: NSRange(location: 120, length: 30), contentOffset: CGPoint(x: 40, y: 900), wasEditing: false)
        #expect(c.restoredSelection(length: 130) == NSRange(location: 120, length: 10))
        #expect(c.restoredSelection(length: 50) == NSRange(location: 50, length: 0))
        #expect(c.restoredSelection(length: 0) == NSRange(location: 0, length: 0))
        #expect(c.restoredOffset(maxOffset: CGPoint(x: 0, y: 300)) == CGPoint(x: 0, y: 300))
        #expect(c.restoredOffset(maxOffset: CGPoint(x: -5, y: -10)) == .zero)
    }

    // MARK: Default font size

    @Test func defaultFontSizeBySizeClass() {
        #expect(EditorDefaults.fontSize(regularWidth: true, regularHeight: true) == 15)    // iPad, unfolded Duo
        #expect(EditorDefaults.fontSize(regularWidth: false, regularHeight: true) == 13)   // phone, folded Duo
        #expect(EditorDefaults.fontSize(regularWidth: true, regularHeight: false) == 13)   // big phone landscape
        #expect(EditorDefaults.fontSize(regularWidth: false, regularHeight: false) == 13)
    }

    // MARK: The owl's badge

    @Test func badgeCountsAndPulsesForNewHints() {
        let b = OwlBadge.make(hints: 2, previous: 1, bubbleOpen: false, hintsOn: true, largeDocument: false, reduceMotion: false)
        #expect(!b.hidden && b.count == 2 && b.pulse)
        #expect(b.accessibilityLabel == "Cedric, 2 hints")
        let same = OwlBadge.make(hints: 2, previous: 2, bubbleOpen: false, hintsOn: true, largeDocument: false, reduceMotion: false)
        #expect(same.count == 2 && !same.pulse)
        let fewer = OwlBadge.make(hints: 1, previous: 2, bubbleOpen: false, hintsOn: true, largeDocument: false, reduceMotion: false)
        #expect(fewer.count == 1 && !fewer.pulse && fewer.accessibilityLabel == "Cedric, 1 hint")
        let none = OwlBadge.make(hints: 0, previous: 0, bubbleOpen: false, hintsOn: true, largeDocument: false, reduceMotion: false)
        #expect(none.count == 0 && !none.pulse && !none.hidden && none.accessibilityLabel == "Cedric")
    }

    @Test func badgeReduceMotionKeepsTheCountWithoutThePulse() {
        let b = OwlBadge.make(hints: 3, previous: 0, bubbleOpen: false, hintsOn: true, largeDocument: false, reduceMotion: true)
        #expect(b.count == 3 && !b.pulse)
    }

    @Test func badgeHiddenWhenHintsOffOrLargeAndQuietWithTheBubbleOpen() {
        let off = OwlBadge.make(hints: 2, previous: 0, bubbleOpen: false, hintsOn: false, largeDocument: false, reduceMotion: false)
        #expect(off.hidden && off.count == 0 && !off.pulse)
        let large = OwlBadge.make(hints: 2, previous: 0, bubbleOpen: false, hintsOn: true, largeDocument: true, reduceMotion: false)
        #expect(large.hidden && !large.pulse)
        let open = OwlBadge.make(hints: 2, previous: 1, bubbleOpen: true, hintsOn: true, largeDocument: false, reduceMotion: false)
        #expect(!open.hidden && open.count == 0 && !open.pulse)
    }

    // MARK: OwlPlacement in y-down (UIKit) coordinates

    let owl = CGSize(width: 60, height: 60)
    let area = CGRect(x: 0, y: 100, width: 400, height: 600)   // y-down, below a nav bar

    @Test func flipIsItsOwnInverse() {
        let r = CGRect(x: 10, y: 120, width: 30, height: 40)
        #expect(OwlPlacement.flipped(OwlPlacement.flipped(r, in: area), in: area) == r)
        // Bottom of the area (y-down) is its y-up bottom too.
        #expect(OwlPlacement.flipped(CGRect(x: 0, y: 640, width: 60, height: 60), in: area).minY == 100)
    }

    @Test func defaultIsBottomRightOnScreen() {
        let f = OwlPlacement.default.frameYDown(in: area, size: owl)
        #expect(f.maxX == area.maxX - OwlPlacement.margin.width)
        #expect(f.maxY == area.maxY - OwlPlacement.margin.height)
        #expect(area.contains(f))
    }

    @Test func droppedNearTopLeftSnapsIntoThatCorner() {
        let p = OwlPlacement.snapped(frameYDown: CGRect(x: 30, y: 130, width: 60, height: 60), in: area)
        #expect(p.corner == .topLeft)
        let f = p.frameYDown(in: area, size: owl)
        #expect(f.minX == area.minX + OwlPlacement.margin.width && f.minY == area.minY + OwlPlacement.margin.height)
    }

    @Test func droppedOnTheRightEdgeKeepsItsHeight() {
        // Middle of the right edge: snapped to it, same distance from the bottom.
        let drop = CGRect(x: 330, y: 360, width: 60, height: 60)
        let p = OwlPlacement.snapped(frameYDown: drop, in: area)
        #expect(p.corner.isRight)
        let f = p.frameYDown(in: area, size: owl)
        #expect(f.maxX == area.maxX - OwlPlacement.margin.width)
        #expect(f.minY == drop.minY)
    }

    @Test func savedPlacementKeepsItsCornerWhenTheAreaChanges() {
        // Folded to unfolded: same corner, same insets, still inside.
        let p = OwlPlacement.snapped(frameYDown: CGRect(x: 330, y: 360, width: 60, height: 60), in: area)
        let big = CGRect(x: 0, y: 80, width: 620, height: 760)
        let f = p.frameYDown(in: big, size: owl)
        #expect(big.contains(f))
        #expect(f.maxX == big.maxX - OwlPlacement.margin.width)
        let tiny = CGRect(x: 0, y: 0, width: 200, height: 150)
        #expect(tiny.contains(p.frameYDown(in: tiny, size: owl)))
    }

    @Test func bubbleOpensAboveHimOnScreenPointingDown() {
        let o = OwlPlacement.default.frameYDown(in: area, size: owl)
        let b = OwlPlacement.bubbleYDown(owl: o, size: CGSize(width: 300, height: 120), in: area, avoid: nil)
        #expect(b.frame.maxY <= o.maxY && b.frame.minY < o.minY)   // above him on screen
        #expect(!b.tailOnTop)                                     // tail below the bubble, towards him
        #expect(area.contains(b.frame))
        // Near the top: below him, tail on top.
        let top = OwlPlacement(corner: .topRight, inset: OwlPlacement.margin).frameYDown(in: area, size: owl)
        let b2 = OwlPlacement.bubbleYDown(owl: top, size: CGSize(width: 300, height: 120), in: area, avoid: nil)
        #expect(b2.frame.minY > top.minY && b2.tailOnTop)
    }

    @Test func bubbleKeepsOffTheHintedLines() {
        let o = OwlPlacement.default.frameYDown(in: area, size: owl)
        let size = CGSize(width: 300, height: 120)
        let plain = OwlPlacement.bubbleYDown(owl: o, size: size, in: area, avoid: nil)
        let hinted = CGRect(x: area.minX, y: plain.frame.midY - 6, width: area.width, height: 12)
        let away = OwlPlacement.bubbleYDown(owl: o, size: size, in: area, avoid: hinted)
        #expect(!away.frame.intersects(hinted))
        #expect(area.contains(away.frame))
    }

    @Test func owlAvoidsTheFold() {
        let a = CGRect(x: 0, y: 0, width: 620, height: 800)
        // Dropped onto the fold, centre on its left: moved left of it.
        let left = OwlPlacement.avoidingFolds(CGRect(x: 270, y: 700, width: 60, height: 60), folds: [fold], in: a)
        #expect(left.maxX == fold.minX - 8 && !left.intersects(fold))
        let right = OwlPlacement.avoidingFolds(CGRect(x: 300, y: 700, width: 60, height: 60), folds: [fold], in: a)
        #expect(right.minX == fold.maxX + 8)
        // Not on the fold: untouched.
        let away = CGRect(x: 540, y: 700, width: 60, height: 60)
        #expect(OwlPlacement.avoidingFolds(away, folds: [fold], in: a) == away)
    }
}
