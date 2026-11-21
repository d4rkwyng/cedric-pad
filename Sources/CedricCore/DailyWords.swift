import Foundation

/// Words written on one local calendar day, across documents.
///
/// The count is the net of word-count changes since each document was last
/// noted. It never goes below zero: deleting more than was written today
/// stops at zero, and that debt does not carry forward. A new local day
/// (`yyyy-MM-dd` in the calendar you pass, so midnight is local midnight)
/// starts again at zero. Opening a document does not count the words
/// already in it; the first note only records a baseline.
public struct DailyWords: Equatable, Sendable {
    public var day: String
    /// Net words added on `day`. Never negative.
    public var words: Int

    public init(day: String, words: Int) {
        self.day = day
        self.words = max(0, words)
    }

    /// `yyyy-MM-dd` for `date` in `calendar` (that calendar's time zone).
    public static func dayString(for date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// This count as of `day`. A different day is a new day: zero words.
    public func rolled(to day: String) -> DailyWords {
        day == self.day ? DailyWords(day: day, words: words) : DailyWords(day: day, words: 0)
    }

    /// Adds `delta` (a document's new word count minus its previous one)
    /// on `day`. A day change zeroes the count first, so yesterday's words
    /// are not today's. The result is never negative.
    public func adding(delta: Int, on day: String) -> DailyWords {
        let base = rolled(to: day)
        return DailyWords(day: day, words: base.words + delta)
    }
}

/// Per-document baselines plus the day's total. Baselines stay in memory
/// (a relaunch records each open document again, and adds nothing). The
/// total is what gets stored, keyed by the local day.
public struct DailyWordLedger: Equatable, Sendable {
    public var words: DailyWords
    /// Last noted word count, by document key.
    public var counts: [String: Int]
    /// An opening count already applied by `rebasing`, so a late baseline
    /// is counted once.
    public var appliedBaseline: [String: Int]

    public init(words: DailyWords, counts: [String: Int] = [:], appliedBaseline: [String: Int] = [:]) {
        self.words = words
        self.counts = counts
        self.appliedBaseline = appliedBaseline
    }

    /// Notes `current` words for `key` on `day`.
    ///
    /// The first time `key` is seen, `current` becomes the baseline and
    /// the day doesn't move. After that, the day moves by `current` minus
    /// the baseline, then the baseline becomes `current`. A new `day`
    /// zeroes the total first; the baselines stay, so a document that
    /// didn't change adds nothing, and one that grew adds only the growth.
    public func noting(key: String, current: Int, on day: String) -> DailyWordLedger {
        var next = self
        if next.words.day != day { next.words = next.words.rolled(to: day) }
        let delta = next.counts[key].map { current - $0 } ?? 0
        next.counts[key] = current
        if delta != 0 { next.words = next.words.adding(delta: delta, on: day) }
        return next
    }

    /// `current` is where `key` stands now (opened, or reloaded from
    /// disk). The day's total doesn't move: that text wasn't written today.
    public func rebaselined(key: String, words current: Int) -> DailyWordLedger {
        var next = self
        next.counts[key] = current
        // A reload is a new baseline, not a second opening correction.
        next.appliedBaseline[key] = nil
        return next
    }

    /// Stops noting `key` (a document too long to count). The next note
    /// starts a fresh baseline instead of a delta against a stale one.
    public func dropping(_ key: String) -> DailyWordLedger {
        var next = self
        next.counts[key] = nil
        next.appliedBaseline[key] = nil
        return next
    }

    /// `original` is the word count taken when the document was opened,
    /// which may arrive after a note already recorded a later count (the
    /// note then had no baseline, so it added nothing). The difference is
    /// applied now. The same `original` again adds nothing.
    public func rebasing(key: String, original: Int, on day: String) -> DailyWordLedger {
        var next = self
        if next.words.day != day { next.words = next.words.rolled(to: day) }
        if next.appliedBaseline[key] == original {
            if next.counts[key] == nil { next.counts[key] = original }
            return next
        }
        if let noted = next.counts[key] {
            let missed = noted - original
            if missed != 0 { next.words = next.words.adding(delta: missed, on: day) }
        } else {
            next.counts[key] = original
        }
        next.appliedBaseline[key] = original
        return next
    }
}

/// The day's total and the optional target, as stored.
///
/// The count's UserDefaults key is `dailyWords.` plus the local day, so a
/// new day reads as zero without deleting yesterday. The target is
/// `dailyWordTarget` (absent: off). Neither is written into a document.
public struct DailyWordLog: Equatable, Sendable {
    public var ledger: DailyWordLedger
    /// Nil: the daily target is off.
    public var target: Int?

    public init(ledger: DailyWordLedger, target: Int? = nil) {
        self.ledger = ledger
        self.target = target.flatMap { WordGoal.range.contains($0) ? $0 : nil }
    }

    public var wordsToday: Int { ledger.words.words }
    public var day: String { ledger.words.day }

    public static func load(now: Date = Date(), calendar: Calendar = .current, defaults: UserDefaults = .standard) -> DailyWordLog {
        let day = DailyWords.dayString(for: now, calendar: calendar)
        return DailyWordLog(ledger: DailyWordLedger(words: DailyWords(day: day, words: DailyWordDefaults.words(on: day, defaults: defaults))),
                            target: DailyWordDefaults.target(in: defaults))
    }

    /// True when today's total changed (the caller persists that).
    public mutating func note(key: String, words: Int, on day: String) -> Bool {
        let before = ledger.words
        ledger = ledger.noting(key: key, current: words, on: day)
        return ledger.words != before
    }

    public mutating func rebaseline(key: String, words: Int) {
        ledger = ledger.rebaselined(key: key, words: words)
    }

    public mutating func drop(_ key: String) {
        ledger = ledger.dropping(key)
    }

    /// True when applying the late baseline changed today's total.
    public mutating func rebaseOriginal(key: String, original: Int, on day: String) -> Bool {
        let before = ledger.words
        ledger = ledger.rebasing(key: key, original: original, on: day)
        return ledger.words != before
    }

    /// True when the target changed. Nil, zero and anything outside
    /// `WordGoal.range` turn it off.
    public mutating func setTarget(_ words: Int?) -> Bool {
        let next = words.flatMap { WordGoal.range.contains($0) ? $0 : nil }
        guard next != target else { return false }
        target = next
        return true
    }

    /// True when `day` is a new day and the in-memory total was zeroed.
    public mutating func roll(to day: String) -> Bool {
        let next = ledger.words.rolled(to: day)
        guard next != ledger.words else { return false }
        ledger.words = next
        return true
    }
}

public enum DailyWordDefaults {
    public static let targetKey = "dailyWordTarget"

    /// The count for one local day. A missing key is zero: that is the
    /// reset at local midnight.
    public static func countKey(day: String) -> String { "dailyWords.\(day)" }

    public static func words(on day: String, defaults: UserDefaults) -> Int {
        max(0, defaults.integer(forKey: countKey(day: day)))
    }

    public static func setWords(_ words: Int, on day: String, defaults: UserDefaults) {
        defaults.set(max(0, words), forKey: countKey(day: day))
    }

    /// Nil when the key is absent or the number isn't a goal (off).
    public static func target(in defaults: UserDefaults) -> Int? {
        guard defaults.object(forKey: targetKey) != nil else { return nil }
        let n = defaults.integer(forKey: targetKey)
        return WordGoal.range.contains(n) ? n : nil
    }

    public static func setTarget(_ words: Int?, in defaults: UserDefaults) {
        if let words, WordGoal.range.contains(words) {
            defaults.set(words, forKey: targetKey)
        } else {
            defaults.removeObject(forKey: targetKey)
        }
    }
}
