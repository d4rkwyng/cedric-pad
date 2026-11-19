import Foundation
import Testing
@testable import CedricCore

@Suite struct OwlChatMoodTests {
    typealias M = OwlChatMood

    @Test func aConversationGoesListenThinkTalkNod() {
        var m = M.idle
        m = M.next(.opened(engineReady: true), from: m)
        #expect(m == .wave)
        m = M.next(.settled, from: m)
        #expect(m == .idle)
        m = M.next(.typed, from: m)
        #expect(m == .listen)
        m = M.next(.settled, from: m)
        m = M.next(.asked, from: m)
        #expect(m == .think)
        m = M.next(.streaming, from: m)
        #expect(m == .talk)
        m = M.next(.answered, from: m)
        #expect(m == .nod)
        #expect(M.next(.settled, from: m) == .idle)
    }

    @Test func eachEventHasItsPose() {
        #expect(M.next(.opened(engineReady: false), from: .idle) == .sleepy)
        #expect(M.next(.searching, from: .think) == .search)
        #expect(M.next(.streaming, from: .search) == .talk)
        #expect(M.next(.proposing, from: .talk) == .write)
        #expect(M.next(.streaming, from: .write) == .write, "an edit being written stays on its strip")
        #expect(M.next(.applied, from: .idle) == .flap)
        #expect(M.next(.failed, from: .think) == .sleepy)
        #expect(M.next(.stopped, from: .talk) == .idle)
        #expect(M.next(.settled, from: .think) == .think, "only gestures settle")
    }

    @Test func typingNeverInterruptsWorkOrAGesture() {
        for m in [M.think, .search, .talk, .write, .wave, .nod, .flap] {
            #expect(M.next(.typed, from: m) == m)
        }
        #expect(M.next(.typed, from: .sleepy) == .listen, "typing wakes him after an error")
    }

    @Test func listeningAndWavingAreThrottled() {
        let t = Date(timeIntervalSince1970: 1000)
        #expect(M.listenDue(lastListen: nil, now: t))
        #expect(!M.listenDue(lastListen: t, now: t.addingTimeInterval(0.4)))
        #expect(M.listenDue(lastListen: t, now: t.addingTimeInterval(M.listenInterval)))
        #expect(M.waveDue(lastWave: nil, now: t))
        #expect(!M.waveDue(lastWave: t, now: t.addingTimeInterval(5)))
        #expect(M.waveDue(lastWave: t, now: t.addingTimeInterval(M.waveInterval)))
    }

    @Test func displayUsesStripsAndStills() {
        #expect(M.display(.idle, reduceMotion: false) == .still(.idle))
        #expect(M.display(.talk, reduceMotion: false) == .still(.talking))
        #expect(M.display(.sleepy, reduceMotion: false) == .still(.sleepy))
        #expect(M.display(.think, reduceMotion: false) == .loop(.think, every: 0.35))
        #expect(M.display(.search, reduceMotion: false) == .loop(.search, every: 0.4))
        guard case .gesture(.wave, let f, _) = M.display(.wave, reduceMotion: false) else { Issue.record("wave"); return }
        #expect(f.allSatisfy { (0..<4).contains($0) })
        guard case .gesture(.look, let look, _) = M.display(.listen, reduceMotion: false) else { Issue.record("listen"); return }
        #expect(look.allSatisfy { (0..<8).contains($0) })
        guard case .gesture(.nod, _, _) = M.display(.nod, reduceMotion: false) else { Issue.record("nod"); return }
        guard case .gesture(.flap, _, _) = M.display(.flap, reduceMotion: false) else { Issue.record("flap"); return }
    }

    @Test func reduceMotionIsStillPosesOnly() {
        for m in M.allCases {
            guard case .still = M.display(m, reduceMotion: true) else { Issue.record("\(m) moves under Reduce Motion"); continue }
        }
        #expect(M.display(.think, reduceMotion: true) == .still(.thinking))
        #expect(M.display(.search, reduceMotion: true) == .still(.thinking))
        #expect(M.display(.write, reduceMotion: true) == .still(.thinking))
        #expect(M.display(.talk, reduceMotion: true) == .still(.talking))
        #expect(M.display(.sleepy, reduceMotion: true) == .still(.sleepy))
        #expect(M.display(.wave, reduceMotion: true) == .still(.idle))
        #expect(M.display(.listen, reduceMotion: true, gaze: 2) == .still(.idle), "no glance under Reduce Motion")
    }

    @Test func closingThePanelMakesHimTheEditorsOwlAgain() {
        for m in M.allCases { #expect(M.next(.closed, from: m) == .idle) }
    }

    @Test func busyWhileWorkingOrPlayingAGesture() {
        for m in [M.think, .search, .talk, .write] {
            #expect(M.isBusy(m, gesturePlaying: false), "\(m) holds the owl while it lasts")
        }
        for m in [M.wave, .listen, .nod, .flap] {
            #expect(M.isBusy(m, gesturePlaying: true))
            #expect(!M.isBusy(m, gesturePlaying: false), "\(m) lets go once it has played (or was cut short)")
        }
        #expect(!M.isBusy(.idle, gesturePlaying: true), "the owl's own gesture isn't the chat's")
        #expect(!M.isBusy(.sleepy, gesturePlaying: false), "sleepy is a still: hints may show")
    }

    @Test func listeningGlancesTowardThePanel() {
        #expect(M.display(.listen, reduceMotion: false, gaze: 2) == .gesture(.look, frames: [2, 2, 2, 2], every: 0.3))
        #expect(M.display(.listen, reduceMotion: false, gaze: nil) == .gesture(.look, frames: [6, 5, 5, 6], every: 0.3))
        #expect(M.display(.listen, reduceMotion: false, gaze: 9) == M.display(.listen, reduceMotion: false), "an unknown direction: the default glance")
    }
}
