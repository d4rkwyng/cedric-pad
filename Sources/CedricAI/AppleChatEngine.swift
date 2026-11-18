import Foundation
import CedricCore

// Ask Cedric on Apple Intelligence's on-device model (never Private Cloud
// Compute). Streams with `streamResponse`. Tools use FoundationModels'
// own `Tool` protocol, which runs the call loop itself; `@Generable`
// needs Xcode's macro plugin, so each tool's `Arguments` is the framework's
// `GeneratedContent` and its `parameters` schema is built at run time with
// `DynamicGenerationSchema` (compiles under the Command Line Tools).

#if canImport(FoundationModels) && arch(arm64)
import FoundationModels

public struct AppleChatEngine: OwlChatEngine {
    public init() {}
    public static var isAvailable: Bool { AppleFoundationModelsProvider.isAvailable }
    public var title: String { "Apple Intelligence" }
    public var scoreKey: String { "apple:\(AppleIntelligenceEngine.modelID)" }
    /// 4096-token window shared by instructions, tools, history and answer.
    public var contextBudget: Int { 5_000 }

    public func turn(_ messages: [OwlChatMessage], tools: [OwlToolSpec], toolbox: OwlToolbox?, maxTokens: Int,
                     onText: @escaping @Sendable (String) -> Void) async throws -> OwlTurn {
        guard #available(macOS 26.0, *), Self.isAvailable else { throw LocalAIError.transport("Apple Intelligence unavailable") }
        var system = ""
        var prompt = ""
        for m in messages {
            switch m {
            case .system(let s): system += s
            case .user(let s): prompt += (prompt.isEmpty ? "" : "\n\nUser: ") + s
            case .assistant(let s): prompt += "\n\nYou answered: " + s
            case .toolCalls, .toolResult: break   // Apple runs its own tool loop
            }
        }
        var appleTools: [any Tool] = []
        if let toolbox {
            for spec in tools { if let t = try? AppleOwlTool(spec: spec, toolbox: toolbox) { appleTools.append(t) } }
        }
        let session = LanguageModelSession(model: SystemLanguageModel.default, tools: appleTools, instructions: system)
        let stream = session.streamResponse(to: prompt, options: GenerationOptions(temperature: 0, maximumResponseTokens: maxTokens))
        var sent = ""
        for try await snapshot in stream {
            try Task.checkCancellation()
            let full = snapshot.content
            if full.hasPrefix(sent) {
                let new = String(full.dropFirst(sent.count))
                if !new.isEmpty { onText(new) }
            }
            sent = full
        }
        return .answer(sent)
    }
}

@available(macOS 26.0, *)
struct AppleOwlTool: Tool {
    typealias Arguments = GeneratedContent
    typealias Output = String
    let name: String
    let description: String
    let parameters: GenerationSchema
    let toolbox: OwlToolbox

    init(spec: OwlToolSpec, toolbox: OwlToolbox) throws {
        name = spec.name.rawValue
        description = spec.description
        self.toolbox = toolbox
        var props: [DynamicGenerationSchema.Property] = []
        let required = Set((spec.parameters["required"].flatMap { j -> [String]? in
            if case .array(let a) = j { return a.compactMap(\.string) }
            return nil
        }) ?? [])
        if case .object(let p)? = spec.parameters["properties"] {
            for (key, v) in p.sorted(by: { $0.key < $1.key }) {
                let schema: DynamicGenerationSchema
                switch v["type"]?.string {
                case "integer": schema = DynamicGenerationSchema(type: Int.self)
                case "boolean": schema = DynamicGenerationSchema(type: Bool.self)
                default: schema = DynamicGenerationSchema(type: String.self)
                }
                props.append(.init(name: key, schema: schema, isOptional: !required.contains(key)))
            }
        }
        parameters = try GenerationSchema(root: DynamicGenerationSchema(name: spec.name.rawValue, properties: props), dependencies: [])
    }

    func call(arguments: GeneratedContent) async throws -> String {
        let args = OwlJSON.parse(arguments.jsonString) ?? .object([:])
        return toolbox.run(OwlToolCall(id: "apple", name: name, arguments: args)).text
    }
}

#else

/// No Foundation Models SDK here (CI's toolchain, Intel): never available.
public struct AppleChatEngine: OwlChatEngine {
    public init() {}
    public static var isAvailable: Bool { false }
    public var title: String { "Apple Intelligence" }
    public var scoreKey: String { "apple:apple-on-device" }
    public var contextBudget: Int { 5_000 }
    public func turn(_ messages: [OwlChatMessage], tools: [OwlToolSpec], toolbox: OwlToolbox?, maxTokens: Int,
                     onText: @escaping @Sendable (String) -> Void) async throws -> OwlTurn {
        throw LocalAIError.transport("Apple Intelligence unavailable")
    }
}

#endif
