import Foundation

/// The PDF tab's reader controls (the floating capsule): fitting, view-only
/// rotation, page stepping, which control groups fit, and auto-hide timing.
public enum PDFReader {
    /// The zoom that shows a whole page (`rotation` in degrees: a quarter
    /// turn swaps width and height), `margin` points clear on every side.
    public static func fitPageScale(pageWidth: Double, pageHeight: Double, viewWidth: Double, viewHeight: Double,
                                    margin: Double = 8, rotation: Int = 0) -> Double {
        let turned = (rotated(rotation, by: 0) / 90) % 2 == 1
        let pw = turned ? pageHeight : pageWidth, ph = turned ? pageWidth : pageHeight
        guard pw > 0, ph > 0 else { return 1 }
        let w = viewWidth - 2 * margin, h = viewHeight - 2 * margin
        guard w > 0, h > 0 else { return PDFTabState.minScale }
        return PDFTabState.clampScale(Swift.min(w / pw, h / ph))
    }

    /// A page rotation turned by `delta` degrees, as PDFKit takes it: 0, 90, 180 or 270.
    public static func rotated(_ rotation: Int, by delta: Int) -> Int {
        let quarter = Int((Double(rotation) / 90).rounded(.down)) * 90
        return ((quarter + delta) % 360 + 360) % 360
    }

    /// The page `by` pages from `index`, or nil past either end.
    public static func page(_ index: Int, moving by: Int, pageCount: Int) -> Int? {
        let n = index + by
        return n >= 0 && n < pageCount ? n : nil
    }

    /// The label after the page field: "of 9".
    public static func pageLabel(index: Int, pageCount: Int) -> String { String(localized: "of \(pageCount)") }

    /// A run of controls in the capsule; lower `priority` is kept longer
    /// (0: always shown).
    public struct Group: Equatable, Sendable {
        public var width: Double
        public var priority: Int
        public init(width: Double, priority: Int) { self.width = width; self.priority = priority }
    }

    /// Which groups to show in `available` points: the highest-priority
    /// numbers go first until the rest fit; priority 0 always stays.
    public static func visibleGroups(_ groups: [Group], spacing: Double, available: Double) -> [Bool] {
        var shown = groups.map { _ in true }
        func width() -> Double {
            let ws = zip(groups, shown).filter(\.1).map(\.0.width)
            return ws.reduce(0, +) + spacing * Double(Swift.max(0, ws.count - 1))
        }
        while width() > available {
            guard let i = groups.indices.filter({ shown[$0] && groups[$0].priority > 0 })
                    .max(by: { groups[$0].priority < groups[$1].priority }) else { break }
            shown[i] = false
        }
        return shown
    }

    /// When the capsule fades: `delay` seconds after the last mouse move or
    /// scroll, unless the pointer is on it or its page field is being edited.
    public struct AutoHide: Sendable {
        public var delay: Double
        public init(delay: Double = 2) { self.delay = delay }
        public func shouldHide(idle: Double, hovering: Bool, editing: Bool = false) -> Bool {
            !hovering && !editing && idle >= delay
        }
    }
}
