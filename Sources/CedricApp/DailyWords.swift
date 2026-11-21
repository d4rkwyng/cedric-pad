import AppKit
import CedricCore

/// The day's word count for the stats popover (DailyWords.swift in
/// CedricCore). One per app: words written today, in every document.
///
/// The typing path only resets a timer. The count moves on save, when a
/// tab closes, on quit, and one second after typing pauses. A check run
/// (`CEDRIC_CHECK`) keeps it in memory, so the suite doesn't write the
/// user's real day.
@MainActor
final class DailyWordCounter {
    /// How long typing must pause before today's count moves.
    static let idle: TimeInterval = 1

    private var log: DailyWordLog
    private let defaults: UserDefaults
    private let calendar: Calendar
    private let persists: Bool
    var onChange: (() -> Void)?

    init(defaults: UserDefaults = .standard, calendar: Calendar = .current, now: Date = Date()) {
        self.defaults = defaults
        self.calendar = calendar
        // A check types a lot. That isn't the user's writing day.
        persists = DevEnvironment.values["CEDRIC_CHECK"] == nil
        if persists {
            log = DailyWordLog.load(now: now, calendar: calendar, defaults: defaults)
        } else {
            log = DailyWordLog(ledger: DailyWordLedger(words: DailyWords(day: DailyWords.dayString(for: now, calendar: calendar), words: 0)))
        }
    }

    var wordsToday: Int { log.wordsToday }
    var target: Int? { log.target }
    var day: String { log.day }

    func note(key: String, words: Int, now: Date = Date()) {
        let day = DailyWords.dayString(for: now, calendar: calendar)
        guard log.note(key: key, words: words, on: day) else { return }
        store()
        onChange?()
    }

    /// Open or reload: `words` is the baseline. Today doesn't move.
    func rebaseline(key: String, words: Int) {
        log.rebaseline(key: key, words: words)
    }

    func drop(_ key: String) {
        log.drop(key)
    }

    /// The opening count, if it was taken off the main thread and finished
    /// after a note. Applies the words typed in between, once.
    func rebaseOriginal(key: String, original: Int, now: Date = Date()) {
        let day = DailyWords.dayString(for: now, calendar: calendar)
        guard log.rebaseOriginal(key: key, original: original, on: day) else { return }
        store()
        onChange?()
    }

    func setTarget(_ words: Int?) {
        guard log.setTarget(words) else { return }
        if persists { DailyWordDefaults.setTarget(log.target, in: defaults) }
        onChange?()
    }

    /// A new local day while the app is open: the total shows zero before
    /// the next note. Baselines stay.
    func rollToNow(now: Date = Date()) {
        let day = DailyWords.dayString(for: now, calendar: calendar)
        guard log.roll(to: day) else { return }
        onChange?()
    }

    private func store() {
        guard persists else { return }
        DailyWordDefaults.setWords(log.wordsToday, on: log.day, defaults: defaults)
    }
}

extension EditorWindowController {
    /// After an edit: today's count moves once typing has paused, not on
    /// this keystroke. The status bar's own count is left to do the scan.
    func scheduleDailyWords() {
        editing.dailyTimer?.invalidate()
        let t = Timer(timeInterval: DailyWordCounter.idle, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.commitDailyWords() }
        }
        RunLoop.main.add(t, forMode: .common)
        editing.dailyTimer = t
    }

    /// The document's word count now, into today's total. Uses the status
    /// bar's cached count when it has one, so this isn't a second scan.
    func commitDailyWords() {
        editing.dailyTimer?.invalidate()
        editing.dailyTimer = nil
        guard let app = NSApp.delegate as? AppDelegate else { return }
        let ns = textView.string as NSString
        if ns.length > TextStats.maxCounted {
            app.dailyWords.drop(doc.id.uuidString)
            return
        }
        let words: Int
        if let cached = editing.documentCounts, let c = cached {
            words = c.words
        } else if let c = TextStats.count(ns, range: NSRange(location: 0, length: ns.length)) {
            words = c.words
        } else {
            return
        }
        app.dailyWords.note(key: doc.id.uuidString, words: words)
    }

    /// Open, restore or reload. The words already in the text are the
    /// baseline, not words written today. A short text reuses the count
    /// the status bar just made; a longer one is counted off the main
    /// thread, from a copy, so a keystroke doesn't wait.
    func armDailyBaseline() {
        editing.dailyTimer?.invalidate()
        editing.dailyTimer = nil
        editing.dailyArm &+= 1
        let generation = editing.dailyArm
        guard let app = NSApp.delegate as? AppDelegate else { return }
        let key = doc.id.uuidString
        let ns = textView.string as NSString
        if let cached = editing.documentCounts {
            if let c = cached { app.dailyWords.rebaseline(key: key, words: c.words) }
            else { app.dailyWords.drop(key) }
            return
        }
        if ns.length > TextStats.maxCounted {
            app.dailyWords.drop(key)
            return
        }
        if ns.length <= Self.immediateCountLimit {
            let words = TextStats.count(ns, range: NSRange(location: 0, length: ns.length))?.words ?? 0
            app.dailyWords.rebaseline(key: key, words: words)
            return
        }
        struct Snapshot: @unchecked Sendable { let text: NSString }
        let snap = Snapshot(text: ns.substring(with: NSRange(location: 0, length: ns.length)) as NSString)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let words = TextStats.count(snap.text, range: NSRange(location: 0, length: snap.text.length))?.words ?? 0
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.editing.dailyArm == generation, self.window != nil else { return }
                    (NSApp.delegate as? AppDelegate)?.dailyWords.rebaseOriginal(key: key, original: words)
                }
            }
        }
    }
}
