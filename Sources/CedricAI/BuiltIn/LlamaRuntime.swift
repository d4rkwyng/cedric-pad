import Foundation
import llama
import CLlamaLoader

/// The real runtime: llama.cpp (the pinned XCFramework, MIT) running a GGUF
/// model in-process. Apple silicon offloads every layer to Metal; Intel
/// Macs run on the CPU (ggml's Metal path on Intel GPUs is not something we
/// test or rely on), which works but is slow.
public struct LlamaRuntime: BuiltInRuntime {
    public static let contextTokens: Int32 = 4096
    static let batchTokens: Int32 = 512

    public init() {}

    /// True on Intel: the built-in engine runs on the CPU there.
    public static var isSlowHardware: Bool {
        #if arch(x86_64)
        return true
        #else
        return false
        #endif
    }

    /// llama.cpp, loaded on the first model load (not linked: see
    /// CLlamaLoader.h), with its backend initialised.
    nonisolated(unsafe) private static let api: Result<cedric_llama_api, BuiltInError> = {
        var err = [CChar](repeating: 0, count: 512)
        guard let p = cedric_llama_load(&err, err.count) else { return .failure(.loadFailed(String(cString: err))) }
        let L = p.pointee
        L.llama_log_set!({ _, _, _ in }, nil)   // llama.cpp is chatty on stderr; keep it quiet
        L.llama_backend_init!()
        return .success(L)
    }()

    /// Loads llama.cpp now (it is not linked); nil if it works, else why
    /// not. For Scripts/launch-check.sh (the bundled framework must load).
    public static func loadCheck() -> String? {
        if case .failure(let e) = api { return "\(e)" }
        return nil
    }

    public func load(modelAt url: URL) async throws -> any LoadedModel {
        guard FileManager.default.fileExists(atPath: url.path) else { throw BuiltInError.notInstalled }
        // Only a catalog model whose bytes are still the catalog's
        // (ModelStore.verifiedForLoad; hashed again after any change).
        guard let model = ModelCatalog.bundled()?.models.first(where: { $0.fileName == url.lastPathComponent }) else {
            throw BuiltInError.loadFailed("not a model from OwlInk's list")
        }
        let store = ModelStore(directory: url.deletingLastPathComponent())
        return try await withCheckedThrowingContinuation { cont in
            LlamaModel.queue.async {
                guard store.verifiedForLoad(model) else {
                    cont.resume(throwing: BuiltInError.loadFailed("the model file doesn't match its checksum; delete it and download it again"))
                    return
                }
                do {
                    let model = try LlamaModel(path: url.path, api: Self.api.get())
                    LlamaModel.registerForExit(model)
                    cont.resume(returning: model)
                } catch { cont.resume(throwing: error) }
            }
        }
    }
}

/// A loaded GGUF model plus one context. Every llama.cpp call happens on
/// `queue`, so the C state is never touched from two threads.
final class LlamaModel: LoadedModel, @unchecked Sendable {
    static let queue: DispatchQueue = {
        let q = DispatchQueue(label: "net.mindtricks.cedric.llama", qos: .userInitiated)
        q.setSpecific(key: queueKey, value: true)
        return q
    }()

    private var model: OpaquePointer?
    private var context: OpaquePointer?
    private let vocab: OpaquePointer?
    private let template: String?
    private let cancelLock = NSLock()
    private var cancelFlag = false

    /// llama.cpp's functions (CLlamaLoader).
    private let L: cedric_llama_api

    init(path: String, api: cedric_llama_api) throws {
        L = api
        var mp = L.llama_model_default_params!()
        #if arch(x86_64)
        mp.n_gpu_layers = 0
        #else
        mp.n_gpu_layers = 999
        #endif
        guard let m = L.llama_model_load_from_file!(path, mp) else {
            throw BuiltInError.loadFailed("llama.cpp could not read the model file")
        }
        var cp = L.llama_context_default_params!()
        cp.n_ctx = UInt32(LlamaRuntime.contextTokens)
        cp.n_batch = UInt32(LlamaRuntime.batchTokens)
        #if arch(x86_64)
        let threads = Int32(max(1, Self.physicalCores()))
        cp.n_threads = threads
        cp.n_threads_batch = threads
        #endif
        guard let c = L.llama_init_from_model!(m, cp) else {
            L.llama_model_free!(m)
            throw BuiltInError.loadFailed("llama.cpp could not create a context")
        }
        model = m
        context = c
        vocab = L.llama_model_get_vocab!(m)
        template = L.llama_model_chat_template!(m, nil).map { String(cString: $0) }
    }

    func unload() {
        Self.queue.async { [self] in freeOnQueue() }
    }

    private func freeOnQueue() {
        if let context { L.llama_free!(context) }
        if let model { L.llama_model_free!(model) }
        context = nil
        model = nil
        Self.liveLock.withLock { Self.live[ObjectIdentifier(self)] = nil }
    }

    // MARK: Exit
    //
    // ggml's Metal device is a C++ static; if the process exits while a
    // context still holds Metal buffers, its destructor aborts (SIGABRT,
    // a crash report on every quit). So every model is freed first, from
    // an atexit handler registered after the device exists (atexit
    // handlers and C++ static destructors run in reverse order, so ours
    // runs before ggml's).

    nonisolated(unsafe) private static var live: [ObjectIdentifier: LlamaModel] = [:]
    private static let liveLock = NSLock()
    nonisolated(unsafe) private static var exitHookInstalled = false

    static func registerForExit(_ model: LlamaModel) {
        liveLock.withLock {
            live[ObjectIdentifier(model)] = model
            if !exitHookInstalled {
                exitHookInstalled = true
                atexit { LlamaModel.freeAllNow() }
            }
        }
    }

    /// Frees every loaded model synchronously (exit, app termination).
    static func freeAllNow() {
        let models = liveLock.withLock { Array(live.values) }
        for m in models { m.cancelLock.withLock { m.cancelFlag = true } }
        let free = { for m in models { m.freeOnQueue() } }
        if DispatchQueue.getSpecific(key: queueKey) != nil { free() } else { queue.sync(execute: free) }
    }

    private static let queueKey = DispatchSpecificKey<Bool>()

    func generate(_ request: GenerationRequest) async throws -> GenerationResult {
        try await generate(request, stream: nil)
    }

    func generate(_ request: GenerationRequest, onText: @escaping @Sendable (String) -> Void) async throws -> GenerationResult {
        try await generate(request, stream: onText)
    }

    private func generate(_ request: GenerationRequest, stream: (@Sendable (String) -> Void)?) async throws -> GenerationResult {
        cancelLock.withLock { cancelFlag = false }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                Self.queue.async { [self] in
                    do { cont.resume(returning: try run(request, stream: stream)) } catch { cont.resume(throwing: error) }
                }
            }
        } onCancel: {
            cancelLock.withLock { cancelFlag = true }
        }
    }

    private var isCancelled: Bool { cancelLock.withLock { cancelFlag } }

    // MARK: On `queue`

    private func run(_ request: GenerationRequest, stream: (@Sendable (String) -> Void)? = nil) throws -> GenerationResult {
        guard let context, let vocab else { throw BuiltInError.notInstalled }
        let prompt = formatChat(request.conversation)
        var tokens = tokenize(prompt)
        let limit = Int(LlamaRuntime.contextTokens) - request.maxTokens
        guard tokens.count <= limit else { throw BuiltInError.promptTooLong(tokens: tokens.count, limit: limit) }

        L.llama_memory_clear!(L.llama_get_memory!(context), true)
        let sampler = makeSampler(grammar: request.grammar)
        defer { L.llama_sampler_free!(sampler) }

        // Prefill in batches.
        let t0 = Date()
        var i = 0
        while i < tokens.count {
            if isCancelled { throw BuiltInError.cancelled }
            let n = min(Int(LlamaRuntime.batchTokens), tokens.count - i)
            let rc = tokens.withUnsafeMutableBufferPointer { buf in
                L.llama_decode!(context, L.llama_batch_get_one!(buf.baseAddress! + i, Int32(n)))
            }
            guard rc == 0 else { throw BuiltInError.generationFailed("decode \(rc)") }
            i += n
        }
        let promptSeconds = Date().timeIntervalSince(t0)

        // Generate.
        let t1 = Date()
        var bytes: [UInt8] = []
        var generated = 0
        var piece = [CChar](repeating: 0, count: 256)
        var decoder = UTF8StreamDecoder()
        while generated < request.maxTokens {
            if isCancelled { throw BuiltInError.cancelled }
            var token = L.llama_sampler_sample!(sampler, context, -1)
            if L.llama_vocab_is_eog!(vocab, token) { break }
            let n = L.llama_token_to_piece!(vocab, token, &piece, Int32(piece.count), 0, false)
            if n > 0 {
                let new = piece[0..<Int(n)].map { UInt8(bitPattern: $0) }
                bytes.append(contentsOf: new)
                if let stream { let t = decoder.append(new); if !t.isEmpty { stream(t) } }
            }
            generated += 1
            let rc = L.llama_decode!(context, L.llama_batch_get_one!(&token, 1))
            guard rc == 0 else { throw BuiltInError.generationFailed("decode \(rc)") }
        }
        tokens.removeAll()
        if let stream { let t = decoder.flush(); if !t.isEmpty { stream(t) } }
        return GenerationResult(text: String(decoding: bytes, as: UTF8.self),
                                promptTokens: Int(i), completionTokens: generated,
                                promptSeconds: promptSeconds, generateSeconds: Date().timeIntervalSince(t1))
    }

    private func makeSampler(grammar: String?) -> UnsafeMutablePointer<llama_sampler> {
        let chain = L.llama_sampler_chain_init!(L.llama_sampler_chain_default_params!())!
        if let grammar, let g = L.llama_sampler_init_grammar!(vocab, grammar, "root") {
            L.llama_sampler_chain_add!(chain, g)
        }
        // Hints should be repeatable: greedy decoding.
        L.llama_sampler_chain_add!(chain, L.llama_sampler_init_greedy!())
        return chain
    }

    private func tokenize(_ text: String) -> [llama_token] {
        let len = Int32(text.utf8.count)
        var out = [llama_token](repeating: 0, count: Int(len) + 8)
        var n = L.llama_tokenize!(vocab, text, len, &out, Int32(out.count), true, true)
        if n < 0 {
            out = [llama_token](repeating: 0, count: Int(-n))
            n = L.llama_tokenize!(vocab, text, len, &out, Int32(out.count), true, true)
        }
        return Array(out.prefix(Int(max(0, n))))
    }

    /// The model's own chat template (llama.cpp knows ChatML, which every
    /// catalog model uses); plain ChatML if it can't be applied.
    private func formatChat(_ messages: [ChatMessage]) -> String {
        let chatML = messages.map { "<|im_start|>\($0.role)\n\($0.content)<|im_end|>\n" }.joined() + "<|im_start|>assistant\n"
        // C strings that live for the whole call.
        let roles = messages.map { strdup($0.role) }
        let contents = messages.map { strdup($0.content) }
        defer { roles.forEach { free($0) }; contents.forEach { free($0) } }
        var msgs = zip(roles, contents).map { llama_chat_message(role: $0, content: $1) }
        let total = messages.reduce(0) { $0 + $1.content.utf8.count }
        var buf = [CChar](repeating: 0, count: total * 2 + 512)
        var n = L.llama_chat_apply_template!(template, &msgs, msgs.count, true, &buf, Int32(buf.count))
        if n > Int32(buf.count) {
            buf = [CChar](repeating: 0, count: Int(n) + 1)
            n = L.llama_chat_apply_template!(template, &msgs, msgs.count, true, &buf, Int32(buf.count))
        }
        guard n > 0 else { return chatML }
        return String(decoding: buf[0..<Int(n)].map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private static func physicalCores() -> Int {
        var cores: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.physicalcpu", &cores, &size, nil, 0) == 0, cores > 0 { return Int(cores) }
        return ProcessInfo.processInfo.activeProcessorCount
    }
}
