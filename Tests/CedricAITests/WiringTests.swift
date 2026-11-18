import Foundation
import Testing
@testable import CedricAI
import CedricCore

/// The settings sheet's model and the registry/scheduler wiring the app
/// uses (`LocalAIOwlBridge`), with fake providers and the stub server.
@Suite struct SettingsTests {
    @Test func offByDefaultWithNinetySecondInterval() {
        let s = LocalAISettings.default
        #expect(s.enabled == false)
        #expect(s.minInterval == 90)
        #expect(s.backend == .builtIn)   // Cedric's own engine: no server needed
        #expect(s.baseURL.absoluteString == "http://localhost:1234/v1")
        #expect(s.isUsable == false)
        #expect(LocalAISettings.intervalChoices.contains(90))
        #expect(LocalAISettings.privacyNote == "Sends only the visible text (up to 8 KB) to the address above. Never the cloud.")
        #expect(LocalAISettings.weakModelNote == "Small models give weaker hints.")
    }

    @Test func presetsSetTheirURLAndResetTheModel() {
        var s = LocalAISettings(enabled: true, model: "qwen3-4b")
        s.selectBackend(.ollama)
        #expect(s.baseURL.absoluteString == "http://localhost:11434/v1")
        #expect(s.model == nil)
        s.baseURL = URL(string: "http://studio.local:1234/v1")!
        s.selectBackend(.custom)
        #expect(s.baseURL.absoluteString == "http://studio.local:1234/v1")   // Custom keeps what's there
        s.selectBackend(.lmStudio)
        #expect(s.baseURL.absoluteString == "http://localhost:1234/v1")
        #expect(LocalAISettings.Backend.allCases.map(\.title) == ["Built-in (on this Mac)", "LM Studio on this Mac", "Ollama on this Mac",
                                                                "Another Mac on your network (URL)", "Apple Intelligence (on this Mac, private)"])
    }

    @Test func customURLParsing() {
        #expect(LocalAISettings.parseEndpoint("studio.local:1234")?.absoluteString == "http://studio.local:1234/v1")
        #expect(LocalAISettings.parseEndpoint(" http://192.168.1.20:11434/ ")?.absoluteString == "http://192.168.1.20:11434/v1")
        #expect(LocalAISettings.parseEndpoint("http://10.0.0.5:8080/v1/")?.absoluteString == "http://10.0.0.5:8080/v1")
        #expect(LocalAISettings.parseEndpoint("https://api.openai.com/v1") == nil)
        #expect(LocalAISettings.parseEndpoint("8.8.8.8:1234") == nil)
        #expect(LocalAISettings.parseEndpoint("") == nil)
    }

    @Test func savesAndLoadsFromDefaults() throws {
        let suite = "cedric-tests-\(UUID().uuidString)"
        let d = try #require(UserDefaults(suiteName: suite))
        defer { d.removePersistentDomain(forName: suite) }
        #expect(LocalAISettings.load(from: d, defaultBackend: .builtIn) == .default)
        var s = LocalAISettings(enabled: true, backend: .ollama, model: "qwen2.5-coder:3b", minInterval: 120)
        s.save(to: d)
        #expect(LocalAISettings.load(from: d) == s)
        s.enabled = false
        s.save(to: d)
        #expect(LocalAISettings.load(from: d).enabled == false)
    }
}

/// A provider that answers after `delay` (real time) with one hint at
/// `range` in the context text, or hangs until cancelled.
final class SlowProvider: OwlHintProvider, @unchecked Sendable {
    let name: String
    let delay: TimeInterval
    private let lock = NSLock()
    private var _calls = 0
    init(name: String = "local:test-qwen", delay: TimeInterval = 0.05) { self.name = name; self.delay = delay }
    var calls: Int { lock.withLock { _calls } }

    func hints(for context: OwlContext) async -> [OwlHint] {
        lock.withLock { _calls += 1 }
        try? await Task.sleep(nanoseconds: UInt64(delay * 1e9))
        if Task.isCancelled { return [] }
        let r = (context.text as NSString).range(of: "<=")
        return [OwlHint(id: "ai-\(context.editGeneration)", kind: .fix, title: "Off by one",
                        range: r.location == NSNotFound ? nil : r, replacement: "<", source: name)]
    }
}

@MainActor
@Suite(.serialized) struct BridgeTests {
    @MainActor final class Rig {
        let registry = OwlProviderRegistry()
        let bridge: LocalAIOwlBridge
        let factoryBox = Box(0)
        var thinking: [(UUID, Bool)] = []
        var hints: [(OwlContext, [OwlHint])] = []

        init(provider: (any OwlHintProvider)?) {
            let box = factoryBox
            bridge = LocalAIOwlBridge(registry: registry, makeProvider: { _ in box.mutate { $0 += 1 }; return provider })
            bridge.onThinking = { [unowned self] id, on in thinking.append((id, on)) }
            bridge.onHints = { [unowned self] c, h in hints.append((c, h)) }
        }
    }

    static let fast = LocalAISettings(enabled: true, backend: .lmStudio, model: "test-qwen", minInterval: 0.1, pauseDelay: 0.05, timeout: 0.5)

    @Test func disabledRegistersNothingAndNeverAsks() async {
        let rig = Rig(provider: SlowProvider())
        await rig.bridge.apply(.default)
        #expect(rig.factoryBox.value == 0)
        #expect(!rig.registry.hasAIProvider)
        #expect(!rig.bridge.isActive)
    }

    @Test func enabledRegistersAnAIEntryThatAnswersNothing() async {
        let provider = SlowProvider()
        let rig = Rig(provider: provider)
        await rig.bridge.apply(Self.fast)
        #expect(rig.registry.hasAIProvider)
        #expect(rig.bridge.providerName == "local:test-qwen")
        #expect(rig.registry.entries.map(\.provider.name) == ["local:test-qwen"])
        // The coordinator's own query never reaches the model.
        let coordinator = OwlCoordinator(registry: rig.registry, defaults: UserDefaults(suiteName: "cedric-bridge-\(UUID())")!)
        coordinator.source = .rulesAndAI
        for p in rig.registry.providers(for: .rulesAndAI) { #expect(await p.hints(for: context()).isEmpty) }
        #expect(provider.calls == 0)
        // Off again: unregistered.
        var off = Self.fast; off.enabled = false
        await rig.bridge.apply(off)
        #expect(!rig.registry.hasAIProvider)
        #expect(!rig.bridge.isActive)
    }

    @Test func refusesPublicEndpointsAndMissingModels() async {
        let rig = Rig(provider: SlowProvider())
        var s = Self.fast
        s.baseURL = URL(string: "https://api.example.com/v1")!
        await rig.bridge.apply(s)
        #expect(!rig.registry.hasAIProvider)
        #expect(rig.factoryBox.value == 0)
        #expect(rig.bridge.lastProblem != nil)
        let none = Rig(provider: nil)
        await none.bridge.apply(Self.fast)
        #expect(!none.registry.hasAIProvider)
        #expect(none.bridge.lastProblem != nil)
    }

    @Test func editThinksThenDeliversThenStopsThinking() async {
        let rig = Rig(provider: SlowProvider(delay: 0.1))
        await rig.bridge.apply(Self.fast)
        let doc = UUID()
        let text = "for i in 0...n {\n  if i <= items.count { }\n}\n"
        let ctx = OwlContext(fileName: "a.swift", language: "swift", text: text, textStart: 5000,
                             visibleRange: NSRange(location: 0, length: 10), selection: nil, documentID: doc, editGeneration: 3)
        rig.bridge.contextChanged(ctx)
        #expect(await eventually { @MainActor in rig.thinking.count == 2 })
        #expect(rig.thinking.map(\.1) == [true, false])
        #expect(rig.thinking.allSatisfy { $0.0 == doc })
        #expect(rig.hints.count == 1)
        let (c, h) = rig.hints[0]
        #expect(c.textStart == 5000 && c.editGeneration == 3)
        #expect(h.first?.source == "local:test-qwen")
        let docRange = h.first.flatMap { OwlCoordinator.documentRange($0, context: c) }
        #expect(docRange == NSRange(location: 5000 + (text as NSString).range(of: "<=").location, length: 2))
        #expect(rig.bridge.thinking.isEmpty)
    }

    @Test func timeoutGoesBackToIdleWithoutHints() async {
        let rig = Rig(provider: SlowProvider(delay: 5))
        var s = Self.fast; s.timeout = 0.2
        await rig.bridge.apply(s)
        rig.bridge.contextChanged(context(gen: 1))
        #expect(await eventually { @MainActor in rig.thinking.count == 2 })
        #expect(rig.thinking.map(\.1) == [true, false])
        #expect(rig.hints.isEmpty)
    }

    @Test func pausedOrInactiveNeverAsks() async {
        let provider = SlowProvider()
        let rig = Rig(provider: provider)
        await rig.bridge.apply(Self.fast)
        rig.bridge.setPaused(true)          // source back to Rules
        rig.bridge.contextChanged(context(gen: 1))
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(provider.calls == 0)
        rig.bridge.setPaused(false)
        rig.bridge.setAppActive(false)
        rig.bridge.contextChanged(context(gen: 2))
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(provider.calls == 0)
        rig.bridge.setAppActive(true)
        #expect(await eventually { provider.calls == 1 })
    }

    @Test func turningOffMidRequestClearsThinking() async {
        let rig = Rig(provider: SlowProvider(delay: 5))
        await rig.bridge.apply(Self.fast)
        rig.bridge.contextChanged(context(gen: 1))
        #expect(await eventually { @MainActor in rig.thinking.count == 1 })
        var off = Self.fast; off.enabled = false
        await rig.bridge.apply(off)
        #expect(rig.thinking.map(\.1) == [true, false])
        #expect(rig.bridge.thinking.isEmpty)
    }

    @Test func realFactoryAutoPicksFromTheServer() async {
        let server = StubServer()
        server.json("/v1/models", ["data": [["id": "qwen/qwen3.8-27b"], ["id": "qwen2.5-coder-1.5b-instruct-mlx"],
                                            ["id": "qwen2.5-coder-3b-instruct"]]])
        let registry = OwlProviderRegistry()
        let session = server.session
        let bridge = LocalAIOwlBridge(registry: registry, makeProvider: { await LocalAIOwl.makeProvider(settings: $0, session: session) })
        var s = LocalAISettings(enabled: true, backend: .custom, baseURL: server.baseURL)
        await bridge.apply(s)
        #expect(bridge.providerName == "local:qwen2.5-coder-3b-instruct")
        s.model = "qwen2.5-coder-1.5b-instruct-mlx"
        await bridge.apply(s)
        #expect(registry.entries.map(\.provider.name) == ["local:qwen2.5-coder-1.5b-instruct-mlx"])
    }
}

@Suite struct EngineAndPromptTests {
    @Test func enginesForEachPlace() async {
        var s = LocalAISettings(enabled: true)
        s.backend = .builtIn
        let built = AIEngines.engine(for: s)
        #expect(built.isAvailable && built.unavailableReason == nil && !built.needsAddress)
        s.backend = .apple
        let apple = AIEngines.engine(for: s)
        #expect(!apple.needsAddress)
        #expect(apple.isAvailable == AppleFoundationModelsProvider.isAvailable)
        for b in [LocalAISettings.Backend.lmStudio, .ollama, .custom] {
            s.backend = b
            #expect(AIEngines.engine(for: s).needsAddress && AIEngines.engine(for: s).isAvailable)
        }
    }

    @MainActor @Test func bridgeExplainsUnavailableEngine() async {
        let registry = OwlProviderRegistry()
        let bridge = LocalAIOwlBridge(registry: registry, makeProvider: { _ in nil })
        await bridge.apply(LocalAISettings(enabled: true, backend: .builtIn))
        #expect(!registry.hasAIProvider)
        #expect(bridge.lastProblem?.contains("No model downloaded") == true)
        await bridge.apply(LocalAISettings(enabled: true, backend: .lmStudio))
        #expect(bridge.lastProblem?.contains("start the server") == true)
    }

    @Test func everyEngineSharesTheOwlPrompts() {
        let msgs = HintPrompt.messages(for: context("let x = 1"), text: "let x = 1", model: "qwen3-4b")
        #expect(msgs[0].content == OwlPrompts.system(for: .codeHints))
        #expect(msgs[0].content.hasPrefix(OwlPrompts.persona))
        #expect(msgs[0].content.contains("Cedric"))
        #expect(msgs[1].content.hasSuffix("/no_think"))
    }
}
