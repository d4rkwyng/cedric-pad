import Foundation

/// How the editor's owl follows Ask Cedric, as pure rules (the app's
/// `OwlController` follows them; there is one owl, wherever the user put
/// him, and none inside the panel): which mood a chat event puts him in,
/// how that mood is drawn (a gesture played once, a state looped while it
/// lasts, or a still pose), what a gesture settles back to, and how often
/// typing in the question field may make him listen.
public enum OwlChatMood: String, Sendable, CaseIterable {
    case idle, wave, listen, think, search, talk, write, nod, flap, sleepy

    /// What happened in the panel.
    public enum Cue: Sendable, Equatable {
        /// The panel came on screen; `engineReady` false: no AI engine.
        case opened(engineReady: Bool)
        /// A key in the question field.
        case typed
        /// A question went out: waiting for the model.
        case asked
        /// The model ran search_document.
        case searching
        /// Answer text arrived.
        case streaming
        /// The model proposed an edit.
        case proposing
        /// The answer finished.
        case answered
        /// The user stopped it.
        case stopped
        /// An error, or no engine.
        case failed
        /// Apply of a proposed edit.
        case applied
        /// A gesture finished playing.
        case settled
        /// The panel closed: he is the editor's owl again.
        case closed
    }

    /// The mood after `cue`, from `current`.
    public static func next(_ cue: Cue, from current: OwlChatMood) -> OwlChatMood {
        switch cue {
        case .opened(let ready): return ready ? .wave : .sleepy
        case .typed:
            // Never interrupts the work, a gesture under way, or another listen.
            return [.idle, .sleepy].contains(current) ? .listen : current
        case .asked: return .think
        case .searching: return .search
        case .streaming:
            // An edit being written stays on its strip until the answer is done.
            return current == .write ? .write : .talk
        case .proposing: return .write
        case .answered: return .nod
        case .stopped: return .idle
        case .failed: return .sleepy
        case .applied: return .flap
        case .settled: return current.isGesture ? .idle : current
        case .closed: return .idle
        }
    }

    /// Played once, then back to idle.
    public var isGesture: Bool { [.wave, .listen, .nod, .flap].contains(self) }
    /// Lasts while the model works.
    public var isWorking: Bool { [.think, .search, .talk, .write].contains(self) }

    /// The art: `Resources/Owl/owl-<name>.png`, or the strip `owl-<name>-strip.png`.
    public enum Still: String, Sendable { case idle, talking, thinking, sleepy }
    public enum Strip: String, Sendable { case wave, look, think, search, write, nod, flap }

    public enum Display: Sendable, Equatable {
        /// One image until the next mood.
        case still(Still)
        /// Strip frames once, `every` seconds apart, then the idle pose.
        case gesture(Strip, frames: [Int], every: Double)
        /// Strip frames on a loop while the mood lasts.
        case loop(Strip, every: Double)
    }

    /// The chat is driving him: his own idle animations and hint gestures
    /// wait (a gesture counts only while it plays).
    public static func isBusy(_ mood: OwlChatMood, gesturePlaying: Bool) -> Bool {
        mood.isWorking || (mood.isGesture && gesturePlaying)
    }

    /// How a mood is drawn. Reduce Motion: still poses only, never a strip
    /// (gestures show the pose they settle to; work shows thinking or
    /// talking). `gaze`: the look-strip frame toward the panel, for the
    /// listening glance (nil: down and down-left, toward the editor's
    /// bottom corner where he sits by default).
    public static func display(_ mood: OwlChatMood, reduceMotion: Bool, gaze: Int? = nil) -> Display {
        if reduceMotion {
            switch mood {
            case .think, .search, .write: return .still(.thinking)
            case .talk: return .still(.talking)
            case .sleepy: return .still(.sleepy)
            default: return .still(.idle)
            }
        }
        switch mood {
        case .idle: return .still(.idle)
        case .sleepy: return .still(.sleepy)
        case .talk: return .still(.talking)
        case .wave: return .gesture(.wave, frames: [0, 1, 2, 3, 2, 3], every: 0.16)
        // A glance toward the panel's question field, held (look strip).
        case .listen:
            if let g = gaze, (0..<8).contains(g) { return .gesture(.look, frames: [g, g, g, g], every: 0.3) }
            return .gesture(.look, frames: [6, 5, 5, 6], every: 0.3)
        case .nod: return .gesture(.nod, frames: [0, 1, 1, 2], every: 0.11)
        case .flap: return .gesture(.flap, frames: [1, 2, 3, 0, 1, 2, 3], every: 0.07)
        case .think: return .loop(.think, every: 0.35)
        case .search: return .loop(.search, every: 0.4)
        case .write: return .loop(.write, every: 0.3)
        }
    }

    /// Seconds between listens while typing.
    public static let listenInterval: TimeInterval = 1.5

    /// Typing makes him listen at most once per `listenInterval`.
    public static func listenDue(lastListen: Date?, now: Date) -> Bool {
        guard let lastListen else { return true }
        return now.timeIntervalSince(lastListen) >= listenInterval
    }

    /// Seconds before opening the panel waves again: reopening it straight
    /// after closing it isn't a hello.
    public static let waveInterval: TimeInterval = 60

    public static func waveDue(lastWave: Date?, now: Date) -> Bool {
        guard let lastWave else { return true }
        return now.timeIntervalSince(lastWave) >= waveInterval
    }
}
