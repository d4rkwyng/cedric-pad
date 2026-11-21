import Foundation
import CoreGraphics

/// Where the seam between text and Markdown preview sits on a wide screen:
/// on the fold (an unfolded iPhone Duo; halves without one), or at a
/// fraction of the content's width given to the text (the leading pane).
public enum SplitPosition: Equatable, Codable, Sendable {
    case fold
    case fraction(Double)
}

/// The resizable split's rules as pure geometry: the stops it snaps to
/// (1/3, 1/2, 2/3 and the fold, the default and a strong snap), what a
/// drag or a VoiceOver increment lands on, and the pane widths. `content`
/// is the split's rect; a fraction is the leading pane's share of its width.
public enum PreviewSplit {
    public static let fractions: [Double] = [1.0 / 3, 1.0 / 2, 2.0 / 3]
    /// A pane is never narrower than this (or a quarter of a narrow screen).
    public static let minPane: CGFloat = 160
    /// A drag ending this close (points) to a stop lands on it.
    public static let snapDistance: CGFloat = 28
    /// ... and this close to the fold (the strong snap).
    public static let foldSnapDistance: CGFloat = 64
    /// A fraction stop this close to the fold is the fold.
    public static let mergeDistance: CGFloat = 16

    public struct Stop: Equatable, Sendable {
        public var position: SplitPosition
        public var fraction: Double
    }

    /// The fold's seam as a fraction (FoldLayout's leading width over the
    /// content width), nil without a fold crossing the content.
    public static func foldFraction(content: CGRect, folds: [CGRect], rightToLeft: Bool = false) -> Double? {
        guard content.width > 0, !FoldLayout.crossingFolds(folds, content: content).isEmpty else { return nil }
        return Double(FoldLayout.split(content: content, folds: folds, rightToLeft: rightToLeft).leading / content.width)
    }

    /// The stops, leading pane narrowest first. The fold replaces a stop
    /// that falls within `mergeDistance` of it.
    public static func stops(content: CGRect, folds: [CGRect], rightToLeft: Bool = false) -> [Stop] {
        let w = Double(content.width)
        var out = fractions.map { Stop(position: .fraction($0), fraction: $0) }
        if let f = foldFraction(content: content, folds: folds, rightToLeft: rightToLeft) {
            out.removeAll { abs($0.fraction - f) * w < Double(mergeDistance) }
            out.append(Stop(position: .fold, fraction: f))
        }
        return out.sorted { $0.fraction < $1.fraction }
    }

    /// The leading pane's share for `position` (the fold without a fold: 1/2).
    public static func fraction(of position: SplitPosition, content: CGRect, folds: [CGRect], rightToLeft: Bool = false) -> Double {
        switch position {
        case .fold: return foldFraction(content: content, folds: folds, rightToLeft: rightToLeft) ?? 0.5
        case .fraction(let f): return clamp(f, width: content.width)
        }
    }

    /// The fraction kept inside the pane minimum on both sides.
    public static func clamp(_ f: Double, width: CGFloat) -> Double {
        guard width > 0 else { return 0.5 }
        let m = Double(min(minPane, width / 4) / width)
        return min(max(f, m), 1 - m)
    }

    /// The leading pane's width and the gap, as FoldLayout.split gives
    /// them: on the fold, the gap is the fold region; elsewhere `spacing`.
    public static func panes(_ position: SplitPosition, content: CGRect, folds: [CGRect], spacing: CGFloat = 1,
                             rightToLeft: Bool = false) -> (leading: CGFloat, gap: CGFloat) {
        if case .fold = position {
            return FoldLayout.split(content: content, folds: folds, spacing: spacing, rightToLeft: rightToLeft)
        }
        let f = fraction(of: position, content: content, folds: folds, rightToLeft: rightToLeft)
        return (max(0, (CGFloat(f) * content.width - spacing / 2).rounded()), spacing)
    }

    /// The seam's x (its middle) for `position`, in content's coordinates' space.
    public static func seamX(_ position: SplitPosition, content: CGRect, folds: [CGRect], spacing: CGFloat = 1,
                             rightToLeft: Bool = false) -> CGFloat {
        let p = panes(position, content: content, folds: folds, spacing: spacing, rightToLeft: rightToLeft)
        let fromLeading = p.leading + p.gap / 2
        return rightToLeft ? content.maxX - fromLeading : content.minX + fromLeading
    }

    /// The leading pane's share when the seam is dragged to `x` (clamped).
    public static func fraction(seamAt x: CGFloat, content: CGRect, rightToLeft: Bool = false) -> Double {
        guard content.width > 0 else { return 0.5 }
        let fromLeading = rightToLeft ? content.maxX - x : x - content.minX
        return clamp(Double(fromLeading / content.width), width: content.width)
    }

    /// Where a drag released at `fraction` lands: the fold if near it
    /// (strong), else the nearest stop if near one, else where it is.
    public static func snap(_ fraction: Double, content: CGRect, folds: [CGRect], rightToLeft: Bool = false) -> SplitPosition {
        let w = Double(content.width)
        let f = clamp(fraction, width: content.width)
        let all = stops(content: content, folds: folds, rightToLeft: rightToLeft)
        if let fold = all.first(where: { $0.position == .fold }), abs(fold.fraction - f) * w <= Double(foldSnapDistance) {
            return .fold
        }
        if let near = all.min(by: { abs($0.fraction - f) < abs($1.fraction - f) }), abs(near.fraction - f) * w <= Double(snapDistance) {
            return near.position
        }
        return .fraction(f)
    }

    /// The next stop from `position`: `+1` gives the leading pane (the
    /// text) more room, `-1` less. Stays put at the ends.
    public static func step(_ position: SplitPosition, by direction: Int, content: CGRect, folds: [CGRect],
                            rightToLeft: Bool = false) -> SplitPosition {
        let all = stops(content: content, folds: folds, rightToLeft: rightToLeft)
        let f = fraction(of: position, content: content, folds: folds, rightToLeft: rightToLeft)
        let eps = 0.5 / max(1, Double(content.width))
        if direction > 0 {
            return all.first { $0.fraction > f + eps }?.position ?? position
        }
        return all.last { $0.fraction < f - eps }?.position ?? position
    }

    /// The preview's (trailing pane's) share in whole percent, for VoiceOver.
    public static func previewPercent(_ position: SplitPosition, content: CGRect, folds: [CGRect], rightToLeft: Bool = false) -> Int {
        Int(((1 - fraction(of: position, content: content, folds: folds, rightToLeft: rightToLeft)) * 100).rounded())
    }
}

/// The split's position, kept per size class (an unfolded Duo or an iPad
/// is regular both ways; an iPad in a narrow-tall window, not). Absent:
/// the fold (halves without one).
public struct PreviewSplitStore {
    public static let keyPrefix = "ios.previewSplit."
    let defaults: UserDefaults

    public init(defaults: UserDefaults) { self.defaults = defaults }

    public static func key(regularWidth: Bool, regularHeight: Bool) -> String {
        keyPrefix + (regularWidth ? "wR" : "wC") + (regularHeight ? "hR" : "hC")
    }

    public func position(regularWidth: Bool, regularHeight: Bool) -> SplitPosition {
        guard let d = defaults.data(forKey: Self.key(regularWidth: regularWidth, regularHeight: regularHeight)),
              let p = try? JSONDecoder().decode(SplitPosition.self, from: d) else { return .fold }
        if case .fraction(let f) = p, !(f > 0 && f < 1) { return .fold }
        return p
    }

    public func set(_ p: SplitPosition, regularWidth: Bool, regularHeight: Bool) {
        let key = Self.key(regularWidth: regularWidth, regularHeight: regularHeight)
        if p == .fold { defaults.removeObject(forKey: key); return }
        defaults.set(try? JSONEncoder().encode(p), forKey: key)
    }
}

/// The iOS preview's text size: the person's zoom (pinch, or ⌘+ and ⌘−
/// in Focus Preview: the Mac's ladder), kept for the app, times the
/// Dynamic Type scale. Applied as WKWebView's pageZoom (CSS zoom, so the
/// text reflows).
extension PreviewZoom {
    public static let defaultsKey = "ios.previewZoom"

    public static func clamped(_ z: Double) -> Double {
        guard z.isFinite, z > 0 else { return 1 }
        return Swift.min(Swift.max(z, min), max)
    }

    /// After a pinch of `scale` from `start`, in 5% steps (fewer reflows).
    public static func pinched(_ start: Double, scale: Double) -> Double {
        clamped(((start * scale) * 20).rounded() / 20)
    }

    /// The page zoom: the person's zoom on top of Dynamic Type's scale.
    public static func pageZoom(user: Double, dynamicTypeScale: Double) -> Double {
        let dt = dynamicTypeScale.isFinite && dynamicTypeScale > 0 ? dynamicTypeScale : 1
        return Swift.min(Swift.max(clamped(user) * dt, 0.5), 5)
    }

    public static func load(_ d: UserDefaults) -> Double {
        let v = d.double(forKey: defaultsKey)
        return v == 0 ? 1 : clamped(v)
    }

    public static func save(_ z: Double, _ d: UserDefaults) {
        let c = clamped(z)
        if c == 1 { d.removeObject(forKey: defaultsKey) } else { d.set(c, forKey: defaultsKey) }
    }
}

/// Text and preview scroll to the same place when Focus Preview opens and
/// closes: the share of the scrollable distance, top inset included.
public enum ScrollSync {
    /// 0 at the top, 1 at the bottom (0 when nothing scrolls).
    public static func fraction(offset: CGFloat, contentHeight: CGFloat, visibleHeight: CGFloat,
                                insetTop: CGFloat = 0, insetBottom: CGFloat = 0) -> Double {
        let range = contentHeight + insetTop + insetBottom - visibleHeight
        guard range > 0 else { return 0 }
        return min(max(Double((offset + insetTop) / range), 0), 1)
    }

    public static func offset(fraction: Double, contentHeight: CGFloat, visibleHeight: CGFloat,
                              insetTop: CGFloat = 0, insetBottom: CGFloat = 0) -> CGFloat {
        let range = contentHeight + insetTop + insetBottom - visibleHeight
        guard range > 0, fraction.isFinite else { return -insetTop }
        return CGFloat(min(max(fraction, 0), 1)) * range - insetTop
    }
}
