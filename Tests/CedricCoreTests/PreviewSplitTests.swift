import CoreGraphics
import Foundation
import Testing
@testable import CedricCore

/// The iOS preview's resizable split (stops, snapping, VoiceOver steps,
/// persistence per size class), its text zoom and the scroll sync used by
/// Focus Preview: pure rules in PreviewSplit.swift.
@Suite struct PreviewSplitTests {
    // Shapes only, as in DuoLayoutTests: an unfolded Duo-like screen with a
    // 20 pt fold down the middle, and an iPad-like one without.
    let duo = CGRect(x: 0, y: 0, width: 620, height: 880)
    var fold: CGRect { CGRect(x: 300, y: 0, width: 20, height: 880) }
    let pad = CGRect(x: 0, y: 0, width: 1200, height: 800)

    // MARK: Stops

    @Test func stopsWithoutAFoldAreThirdsAndHalf() {
        let s = PreviewSplit.stops(content: pad, folds: [])
        let want: [SplitPosition] = [.fraction(1.0 / 3), .fraction(0.5), .fraction(2.0 / 3)]
        #expect(s.map(\.position) == want)
    }

    @Test func foldReplacesTheHalfStopNextToIt() {
        let s = PreviewSplit.stops(content: duo, folds: [fold])
        let want: [SplitPosition] = [.fraction(1.0 / 3), .fold, .fraction(2.0 / 3)]
        #expect(s.map(\.position) == want)
        #expect(abs(s[1].fraction - 300.0 / 620) < 1e-9)
    }

    @Test func offCentreFoldKeepsTheHalfStop() {
        // A fold well away from the middle (an asymmetric safe area): 1/2 stays a stop too.
        let content = CGRect(x: 0, y: 0, width: 900, height: 600)
        let f = CGRect(x: 300, y: 0, width: 20, height: 600)
        let s = PreviewSplit.stops(content: content, folds: [f])
        let want: [SplitPosition] = [.fold, .fraction(0.5), .fraction(2.0 / 3)]
        #expect(s.map(\.position) == want)
    }

    @Test func foldAtTheEdgeIsNoStop() {
        let edge = CGRect(x: 40, y: 0, width: 20, height: 880)
        #expect(PreviewSplit.foldFraction(content: duo, folds: [edge]) == nil)
        #expect(!PreviewSplit.stops(content: duo, folds: [edge]).contains { $0.position == .fold })
    }

    // MARK: Panes

    @Test func foldPositionIsFoldLayoutsSplit() {
        let p = PreviewSplit.panes(.fold, content: duo, folds: [fold])
        let f = FoldLayout.split(content: duo, folds: [fold])
        #expect(p.leading == f.leading && p.gap == f.gap)
        #expect(p.leading == 300 && p.gap == 20)
    }

    @Test func foldPositionWithoutAFoldIsHalves() {
        let p = PreviewSplit.panes(.fold, content: CGRect(x: 0, y: 0, width: 401, height: 10), folds: [])
        #expect(p.leading == 200 && p.gap == 1)
        #expect(PreviewSplit.fraction(of: .fold, content: pad, folds: []) == 0.5)
    }

    @Test func fractionPanes() {
        let p = PreviewSplit.panes(.fraction(1.0 / 3), content: pad, folds: [])
        #expect(p.leading == 400)
        #expect(p.gap == 1)
    }

    @Test func fractionsKeepAMinimumPane() {
        #expect(PreviewSplit.clamp(0.01, width: 1200) == Double(PreviewSplit.minPane) / 1200)
        #expect(PreviewSplit.clamp(0.99, width: 1200) == 1 - Double(PreviewSplit.minPane) / 1200)
        // A narrow screen: a quarter each side at least.
        #expect(PreviewSplit.clamp(0, width: 400) == 0.25)
        #expect(PreviewSplit.clamp(0.3, width: 0) == 0.5)
    }

    @Test func seamXFollowsLayoutDirection() {
        // Within the 1 pt gap's half.
        #expect(abs(PreviewSplit.seamX(.fraction(0.25), content: pad, folds: []) - 300) <= 0.5)
        #expect(abs(PreviewSplit.seamX(.fraction(0.25), content: pad, folds: [], rightToLeft: true) - 900) <= 0.5)
        #expect(PreviewSplit.seamX(.fold, content: duo, folds: [fold]) == fold.midX)
        #expect(PreviewSplit.seamX(.fold, content: duo, folds: [fold], rightToLeft: true) == fold.midX)
    }

    @Test func dragLocationToFraction() {
        #expect(PreviewSplit.fraction(seamAt: 300, content: pad) == 0.25)
        #expect(PreviewSplit.fraction(seamAt: 300, content: pad, rightToLeft: true) == 0.75)
        let offset = CGRect(x: 100, y: 0, width: 1000, height: 10)
        #expect(PreviewSplit.fraction(seamAt: 600, content: offset) == 0.5)
        #expect(PreviewSplit.fraction(seamAt: -500, content: offset) == PreviewSplit.clamp(0, width: 1000))
    }

    // MARK: Snapping

    @Test func snapsToANearStop() {
        // 1/3 of 1200 = 400; released at 420 (20 pt away).
        #expect(PreviewSplit.snap(420.0 / 1200, content: pad, folds: []) == .fraction(1.0 / 3))
        #expect(PreviewSplit.snap(790.0 / 1200, content: pad, folds: []) == .fraction(2.0 / 3))
    }

    @Test func staysWhereReleasedAwayFromStops() {
        let f = 500.0 / 1200
        #expect(PreviewSplit.snap(f, content: pad, folds: []) == .fraction(f))
    }

    @Test func foldIsAStrongSnap() {
        // 60 pt from the fold's seam: further than a normal snap, still the fold.
        let f = (300.0 - 60) / 620
        #expect(PreviewSplit.snap(f, content: duo, folds: [fold]) == .fold)
        // ... and it wins over a fraction stop closer than its own reach.
        let wide = CGRect(x: 0, y: 0, width: 1200, height: 800)
        let foldAt450 = CGRect(x: 440, y: 0, width: 20, height: 800)
        // The 1/3 stop (400) is 4 pt from 404; the fold seam (440) 36 pt: fold wins.
        #expect(PreviewSplit.snap(404.0 / 1200, content: wide, folds: [foldAt450]) == .fold)
    }

    @Test func farFromTheFoldSnapsElsewhere() {
        let f = (300.0 - 110) / 620
        #expect(PreviewSplit.snap(f, content: duo, folds: [fold]) == .fraction(1.0 / 3))
    }

    @Test func snapClampsTheEnds() {
        #expect(PreviewSplit.snap(0, content: pad, folds: []) == .fraction(PreviewSplit.clamp(0, width: 1200)))
    }

    // MARK: VoiceOver steps

    @Test func stepsWalkTheStops() {
        var p = SplitPosition.fraction(1.0 / 3)
        p = PreviewSplit.step(p, by: 1, content: duo, folds: [fold])
        #expect(p == .fold)
        p = PreviewSplit.step(p, by: 1, content: duo, folds: [fold])
        #expect(p == .fraction(2.0 / 3))
        // At the end it stays.
        #expect(PreviewSplit.step(p, by: 1, content: duo, folds: [fold]) == p)
        p = PreviewSplit.step(p, by: -1, content: duo, folds: [fold])
        #expect(p == .fold)
    }

    @Test func stepFromBetweenStops() {
        #expect(PreviewSplit.step(.fraction(0.4), by: 1, content: pad, folds: []) == .fraction(0.5))
        #expect(PreviewSplit.step(.fraction(0.4), by: -1, content: pad, folds: []) == .fraction(1.0 / 3))
        // The fold on a screen without one is the half.
        #expect(PreviewSplit.step(.fold, by: 1, content: pad, folds: []) == .fraction(2.0 / 3))
    }

    @Test func previewPercent() {
        #expect(PreviewSplit.previewPercent(.fraction(1.0 / 3), content: pad, folds: []) == 67)
        #expect(PreviewSplit.previewPercent(.fold, content: pad, folds: []) == 50)
    }

    // MARK: Persistence

    @Test func storeDefaultsToTheFold() {
        let (d, name) = TestDefaults.make("cedric-tests-")
        defer { TestDefaults.remove(name) }
        #expect(PreviewSplitStore(defaults: d).position(regularWidth: true, regularHeight: true) == .fold)
    }

    @Test func storeKeepsAPositionPerSizeClass() {
        let (d, name) = TestDefaults.make("cedric-tests-")
        defer { TestDefaults.remove(name) }
        let s = PreviewSplitStore(defaults: d)
        s.set(.fraction(2.0 / 3), regularWidth: true, regularHeight: true)
        s.set(.fraction(1.0 / 3), regularWidth: true, regularHeight: false)
        #expect(s.position(regularWidth: true, regularHeight: true) == .fraction(2.0 / 3))
        #expect(s.position(regularWidth: true, regularHeight: false) == .fraction(1.0 / 3))
        #expect(s.position(regularWidth: false, regularHeight: true) == .fold)
        // A fresh store on the same defaults reads it back (a relaunch).
        #expect(PreviewSplitStore(defaults: d).position(regularWidth: true, regularHeight: true) == .fraction(2.0 / 3))
        // The fold (a reset) removes the key.
        s.set(.fold, regularWidth: true, regularHeight: true)
        #expect(d.object(forKey: PreviewSplitStore.key(regularWidth: true, regularHeight: true)) == nil)
        #expect(s.position(regularWidth: true, regularHeight: true) == .fold)
    }

    @Test func storeIgnoresJunk() {
        let (d, name) = TestDefaults.make("cedric-tests-")
        defer { TestDefaults.remove(name) }
        let key = PreviewSplitStore.key(regularWidth: true, regularHeight: true)
        d.set(Data("nope".utf8), forKey: key)
        #expect(PreviewSplitStore(defaults: d).position(regularWidth: true, regularHeight: true) == .fold)
        d.set(try! JSONEncoder().encode(SplitPosition.fraction(7)), forKey: key)
        #expect(PreviewSplitStore(defaults: d).position(regularWidth: true, regularHeight: true) == .fold)
    }

    // MARK: Zoom

    @Test func zoomStepsAndClamps() {
        // ⌘+ and ⌘− use the Mac's ladder.
        #expect(PreviewZoom.step(1, in: true) == 1.1)
        #expect(PreviewZoom.step(1.1, in: false) == 1)
        // A pinched value between rungs steps to the next rung.
        #expect(PreviewZoom.step(1.35, in: true) == 1.5)
        #expect(PreviewZoom.clamped(.nan) == 1)
        #expect(PreviewZoom.clamped(0.1) == 0.5)
        #expect(PreviewZoom.pinched(1, scale: 1.33) == 1.35)
        #expect(PreviewZoom.pinched(1, scale: 10) == 3)
    }

    @Test func zoomTimesDynamicType() {
        #expect(PreviewZoom.pageZoom(user: 1, dynamicTypeScale: 1) == 1)
        #expect(abs(PreviewZoom.pageZoom(user: 1.5, dynamicTypeScale: 23.0 / 17) - 1.5 * 23 / 17) < 1e-9)
        #expect(PreviewZoom.pageZoom(user: 1, dynamicTypeScale: 0) == 1)
        #expect(PreviewZoom.pageZoom(user: 3, dynamicTypeScale: 3.5) == 5)
    }

    @Test func zoomPersists() {
        let (d, name) = TestDefaults.make("cedric-tests-")
        defer { TestDefaults.remove(name) }
        #expect(PreviewZoom.load(d) == 1)
        PreviewZoom.save(1.3, d)
        #expect(PreviewZoom.load(d) == 1.3)
        PreviewZoom.save(1, d)
        #expect(d.object(forKey: PreviewZoom.defaultsKey) == nil)
        d.set(99.0, forKey: PreviewZoom.defaultsKey)
        #expect(PreviewZoom.load(d) == 3)
    }

    // MARK: Scroll sync

    @Test func scrollFractionRoundTrips() {
        // Text: 2000 tall, 600 visible, 10 top inset, 80 bottom.
        let f = ScrollSync.fraction(offset: 735, contentHeight: 2000, visibleHeight: 600, insetTop: 10, insetBottom: 80)
        #expect(abs(f - 0.5) < 1e-9)
        // The same place in a preview of another height.
        #expect(ScrollSync.offset(fraction: f, contentHeight: 5000, visibleHeight: 800) == 2100)
        #expect(ScrollSync.offset(fraction: f, contentHeight: 2000, visibleHeight: 600, insetTop: 10, insetBottom: 80) == 735)
    }

    @Test func scrollFractionEdges() {
        #expect(ScrollSync.fraction(offset: 0, contentHeight: 300, visibleHeight: 600) == 0)
        #expect(ScrollSync.fraction(offset: -10, contentHeight: 2000, visibleHeight: 600, insetTop: 10) == 0)
        #expect(ScrollSync.fraction(offset: 99_999, contentHeight: 2000, visibleHeight: 600) == 1)
        #expect(ScrollSync.offset(fraction: 0.7, contentHeight: 300, visibleHeight: 600, insetTop: 10) == -10)
    }

    // MARK: Viewport

    @Test func iOSPageHasAViewportTheMacPageNot() {
        let ios = PreviewHTML.page(body: "", palette: EditorPalettes.light, csp: "default-src 'none'", viewport: true)
        #expect(ios.contains("width=device-width"))
        let mac = PreviewHTML.page(body: "", palette: EditorPalettes.light, csp: "default-src 'none'")
        #expect(!mac.contains("viewport"))
    }
}
