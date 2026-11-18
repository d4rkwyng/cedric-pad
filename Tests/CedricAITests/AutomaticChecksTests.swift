import Foundation
import Testing
@testable import CedricAI
import CedricCore

/// "Editor first" on Intel: automatic AI checks are off by default there,
/// and with them off nothing asks the model unless the user does.
@Suite struct AutomaticChecksSettingsTests {
    @Test func offByDefaultOnIntelOnElsewhere() {
        #if arch(x86_64)
        #expect(LocalAISettings.defaultAutomaticChecks == false)
        #else
        #expect(LocalAISettings.defaultAutomaticChecks == true)
        #endif
        #expect(LocalAISettings.default.automaticChecks == LocalAISettings.defaultAutomaticChecks)
    }

    @Test func savedChoiceWinsAndOldSettingsGetTheDefault() throws {
        var s = LocalAISettings(enabled: true, automaticChecks: !LocalAISettings.defaultAutomaticChecks)
        let data = try JSONEncoder().encode(s)
        #expect(try JSONDecoder().decode(LocalAISettings.self, from: data).automaticChecks == !LocalAISettings.defaultAutomaticChecks)
        // Settings saved before the option existed.
        var dict = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        dict["automaticChecks"] = nil
        let old = try JSONSerialization.data(withJSONObject: dict)
        s = try JSONDecoder().decode(LocalAISettings.self, from: old)
        #expect(s.automaticChecks == LocalAISettings.defaultAutomaticChecks)
    }
}

@Suite struct ManualSchedulerTests {
    @Test func manualNeverFiresOnItsOwnButChecksWhenAsked() async {
        let clock = FakeClock(), provider = FakeProvider()
        let delivered = Box<[Int]>([])
        let s = OwlScheduler(provider: provider, config: .init(automatic: false), clock: clock, power: FakePower(),
                             deliver: { ctx, _ in delivered.mutate { $0.append(ctx.editGeneration) } })
        let doc = UUID()
        await s.contextChanged(context(gen: 1, doc: doc))
        await s.setAppActive(false)
        await s.setAppActive(true)
        clock.advance(10_000)
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(provider.calls.isEmpty)
        #expect(clock.pendingSleepers == 0)            // no timer armed at all
        // Asked: at once, typing pause and interval notwithstanding.
        #expect(await s.checkNow(context(gen: 2, doc: doc)))
        #expect(await eventually { delivered.value == [2] })
        #expect(await s.checkNow(context(gen: 2, doc: doc)))   // asked again: allowed
        #expect(await eventually { provider.calls == [2, 2] })
        // Never for a large document.
        await s.setLargeDocument(doc, true)
        #expect(await s.checkNow(context(gen: 3, doc: doc)) == false)
        try? await Task.sleep(nanoseconds: 30_000_000)
        #expect(provider.calls == [2, 2])
    }
}

@MainActor
@Suite(.serialized) struct ManualBridgeTests {
    @Test func automaticOffAsksOnlyWhenTheUserDoes() async {
        let registry = OwlProviderRegistry()
        let provider = SlowProvider()
        let bridge = LocalAIOwlBridge(registry: registry, makeProvider: { _ in provider })
        let got = Box(0)
        bridge.onHints = { _, _ in got.mutate { $0 += 1 } }
        var s = BridgeTests.fast
        s.automaticChecks = false
        await bridge.apply(s)
        #expect(bridge.isActive && !bridge.isAutomatic)
        #expect(bridge.statusLine()?.hasSuffix("checks only when you ask") == true)
        for g in 1...3 { bridge.contextChanged(context(gen: g)) }
        try? await Task.sleep(nanoseconds: 400_000_000)
        #expect(provider.calls == 0)
        let doc = UUID()
        #expect(bridge.checkNow(context("if i <= n {}", gen: 4, doc: doc)))
        #expect(await eventually { @MainActor in got.value == 1 })
        #expect(provider.calls == 1)
        // Paused (source back to Rules) or a large document: not even when asked.
        bridge.setPaused(true)
        #expect(!bridge.checkNow(context(gen: 5, doc: doc)))
        bridge.setPaused(false)
        bridge.setLargeDocument(doc, true)
        #expect(!bridge.checkNow(context(gen: 6, doc: doc)))
        try? await Task.sleep(nanoseconds: 200_000_000)
        #expect(provider.calls == 1)
    }
}
