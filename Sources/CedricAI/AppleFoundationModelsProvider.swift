import Foundation
import CedricCore

// Apple's on-device model (Foundation Models framework, macOS 26+, Apple
// silicon with Apple Intelligence enabled). Only `SystemLanguageModel` is
// used: it runs on the device. The SDK also has a Private Cloud Compute model;
// that is a network service and is deliberately NOT used.
//
// Toolchain note: CI builds with Swift 6.1 against the macOS 15 SDK, which
// has no FoundationModels module, so `canImport` is false there and only the
// placeholder below compiles. With the macOS 26+ SDK the real stub compiles,
// and `isAvailable` still gates at run time (OS version, Apple silicon,
// Apple Intelligence on, model downloaded).

#if canImport(FoundationModels) && arch(arm64)
import FoundationModels

public struct AppleFoundationModelsProvider: OwlHintProvider {
    public var name: String { "apple" }
    public init() {}

    public static var isAvailable: Bool {
        if #available(macOS 26.0, *) {
            return SystemLanguageModel.default.isAvailable
        }
        return false
    }

    public func hints(for context: OwlContext) async -> [OwlHint] {
        guard #available(macOS 26.0, *), SystemLanguageModel.default.isAvailable else { return [] }
        let text = HintPrompt.capped(context.text)
        let messages = HintPrompt.messages(for: context, text: text, model: "apple")
        // A fresh session per request: no transcript is kept between checks.
        let session = LanguageModelSession(instructions: messages[0].content)
        do {
            let response = try await session.respond(to: messages[1].content)
            return HintPrompt.parse(response.content, text: text, source: name)
        } catch {
            return []
        }
    }
}

#else

/// Placeholder where the Foundation Models SDK isn't present (CI's Swift 6.1
/// toolchain, Intel): never available, returns no hints.
public struct AppleFoundationModelsProvider: OwlHintProvider {
    public var name: String { "apple" }
    public init() {}
    public static var isAvailable: Bool { false }
    public func hints(for context: OwlContext) async -> [OwlHint] { [] }
}

#endif
