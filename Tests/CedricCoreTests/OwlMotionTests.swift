import Foundation
import Testing
@testable import CedricCore

@Suite struct OwlMotionTests {
    @Test func reduceMotionSkipsGesturesAndStillsStates() {
        for a in OwlMotion.Animation.allCases {
            #expect(OwlMotion.render(a, reduceMotion: false) == .play)
        }
        for a in [OwlMotion.Animation.blink, .glance, .lookAtCaret, .polish, .flap, .wave, .nod, .point] {
            #expect(OwlMotion.render(a, reduceMotion: true) == .skip)
        }
        for a in [OwlMotion.Animation.think, .search, .write] {
            #expect(OwlMotion.render(a, reduceMotion: true) == .still)
        }
    }

    @Test func idleDelayIsFourToNineSecondsOrOnlyTheSleepTimer() {
        #expect(OwlMotion.idleDelay(untilSleep: 300, reduceMotion: false, random: 0) == 4)
        #expect(OwlMotion.idleDelay(untilSleep: 300, reduceMotion: false, random: 1) == 9)
        #expect(OwlMotion.idleDelay(untilSleep: 2, reduceMotion: false, random: 1) == 2)
        #expect(OwlMotion.idleDelay(untilSleep: 300, reduceMotion: true, random: 0) == 300)
        #expect(OwlMotion.idleDelay(untilSleep: -5, reduceMotion: true, random: 0) == 0.5)
    }

    @Test func gazeAndPointFaceTheDirection() {
        #expect(OwlMotion.gazeIndex(dx: 10, dy: 0) == 0)
        #expect(OwlMotion.gazeIndex(dx: 10, dy: 10) == 1)
        #expect(OwlMotion.gazeIndex(dx: 0, dy: 5) == 2)
        #expect(OwlMotion.gazeIndex(dx: -3, dy: 0.1) == 4)
        #expect(OwlMotion.gazeIndex(dx: -200, dy: -190) == 5)
        #expect(OwlMotion.gazeIndex(dx: 0, dy: -1) == 6)
        #expect(OwlMotion.gazeIndex(dx: 1, dy: -1) == 7)
        #expect(OwlMotion.gazeIndex(dx: 0, dy: 0) == nil)
        #expect(OwlMotion.pointIndex(dx: 5, dy: 1) == 0)
        #expect(OwlMotion.pointIndex(dx: 1, dy: 50) == 1)
        #expect(OwlMotion.pointIndex(dx: -9, dy: 2) == 2)
        #expect(OwlMotion.pointIndex(dx: 0, dy: -300) == 3)
    }
}
