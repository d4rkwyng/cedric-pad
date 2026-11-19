import Foundation
import Testing
@testable import CedricCore

/// Where the text goes, said honestly for each engine and grammar setting.
@Suite struct AIPrivacyWordingTests {
    @Test func localEngine() {
        let w = AIPrivacyWording(engine: .local, autoGrammar: false)
        #expect(w.introSentence == "It stays on this Mac.")
        #expect(w.settingsSentence.contains("nothing leaves it") && w.settingsSentence.contains("until you ask"))
        let auto = AIPrivacyWording(engine: .local, autoGrammar: true)
        #expect(auto.settingsSentence.contains("automatic AI grammar") && !auto.settingsSentence.contains("until you ask"))
    }

    @Test func serverEngineNamesTheServer() {
        let w = AIPrivacyWording(engine: .server(host: "studio.local"), autoGrammar: false)
        #expect(w.introSentence == "What you ask goes to the AI server you set up (studio.local), nowhere else.")
        #expect(!w.introSentence.contains("this Mac"))
        #expect(w.settingsSentence == "Text is sent to the AI server you set up (studio.local) only when you ask.")
        let auto = AIPrivacyWording(engine: .server(host: nil), autoGrammar: true)
        #expect(auto.settingsSentence.hasPrefix("Text is sent to the AI server you set up when you ask"))
        #expect(auto.settingsSentence.contains("without asking"))
        #expect(!auto.settingsSentence.contains("only when you ask"))
    }

    @Test func noEngine() {
        let w = AIPrivacyWording(engine: .none, autoGrammar: true)
        #expect(w.settingsSentence.contains("Nothing is sent until an engine is set up"))
    }

    @Test func everyCombinationIsDistinct() {
        let all = [AIPrivacyWording.Engine.local, .server(host: "h")].flatMap { e in [false, true].map { AIPrivacyWording(engine: e, autoGrammar: $0).settingsSentence } }
        #expect(Set(all).count == 4)
    }
}
