import Foundation
import llama

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

    private static let backend: Void = {
        llama_log_set({ _, _, _ in }, nil)   // llama.cpp is chatty on stderr; keep it quiet
        llama_backend_init()
    }()

    public func load(modelAt url: URL) async throws -> any LoadedModel {
        guard FileManager.default.fileExists(atPath: url.path) else { throw BuiltInError.notInstalled }
        return try await withCheckedThrowingContinuation { cont in
            LlamaModel.queue.async {
                _ = Self.backend
                do {
                    let model = try LlamaModel(path: url.path)
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

    init(path: String) throws {
        var mp = llama_model_default_params()
        #if arch(x86_64)
        mp.n_gpu_layers = 0
        #else
        mp.n_gpu_layers = 999
        #endif
        guard let m = llama_model_load_from_file(path, mp) else {
            throw BuiltInError.loadFailed("llama.cpp could not read the model file")
        }
        var cp = llama_context_default_params()
        cp.n_ctx = UInt32(LlamaRuntime.contextTokens)
        cp.n_batch = UInt32(LlamaRuntime.batchTokens)
        #if arch(x86_64)
        let threads = Int32(max(1, Self.physicalCores()))
        cp.n_threads = threads
        cp.n_threads_batch = threads
        #endif
        guard let c = llama_init_from_model(m, cp) else {
            llama_model_free(m)
            throw BuiltInError.loadFailed("llama.cpp could not create a context")
        }
        model = m
        context = c
        vocab = llama_model_get_vocab(m)
        template = llama_model_chat_template(m, nil).map { String(cString: $0) }
    }

    func unload() {
        Self.queue.async { [self] in freeOnQueue() }
    }

    private func freeOnQueue() {
        if let context { llama_free(context) }
        if let model { llama_model_free(model) }
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
        cancelLock.withLock { cancelFlag = false }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                Self.queue.async { [self] in
                    do { cont.resume(returning: try run(request)) } catch { cont.resume(throwing: error) }
                }
            }
        } onCancel: {
            cancelLock.withLock { cancelFlag = true }
        }
    }

    private var isCancelled: Bool { cancelLock.withLock { cancelFlag } }

    // MARK: On `queue`

    private func run(_ request: GenerationRequest) throws -> GenerationResult {
        guard let context, let vocab else { throw BuiltInError.notInstalled }
        let prompt = formatChat(system: request.system, user: request.user)
        var tokens = tokenize(prompt)
        let limit = Int(LlamaRuntime.contextTokens) - request.maxTokens
        guard tokens.count <= limit else { throw BuiltInError.promptTooLong(tokens: tokens.count, limit: limit) }

        llama_memory_clear(llama_get_memory(context), true)
        let sampler = makeSampler(grammar: request.grammar)
        defer { llama_sampler_free(sampler) }

        // Prefill in batches.
        let t0 = Date()
        var i = 0
        while i < tokens.count {
            if isCancelled { throw BuiltInError.cancelled }
            let n = min(Int(LlamaRuntime.batchTokens), tokens.count - i)
            let rc = tokens.withUnsafeMutableBufferPointer { buf in
                llama_decode(context, llama_batch_get_one(buf.baseAddress! + i, Int32(n)))
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
        while generated < request.maxTokens {
            if isCancelled { throw BuiltInError.cancelled }
            var token = llama_sampler_sample(sampler, context, -1)
            if llama_vocab_is_eog(vocab, token) { break }
            let n = llama_token_to_piece(vocab, token, &piece, Int32(piece.count), 0, false)
            if n > 0 { bytes.append(contentsOf: piece[0..<Int(n)].map { UInt8(bitPattern: $0) }) }
            generated += 1
            let rc = llama_decode(context, llama_batch_get_one(&token, 1))
            guard rc == 0 else { throw BuiltInError.generationFailed("decode \(rc)") }
        }
        tokens.removeAll()
        return GenerationResult(text: String(decoding: bytes, as: UTF8.self),
                                promptTokens: Int(i), completionTokens: generated,
                                promptSeconds: promptSeconds, generateSeconds: Date().timeIntervalSince(t1))
    }

    private func makeSampler(grammar: String?) -> UnsafeMutablePointer<llama_sampler> {
        let chain = llama_sampler_chain_init(llama_sampler_chain_default_params())!
        if let grammar, let g = llama_sampler_init_grammar(vocab, grammar, "root") {
            llama_sampler_chain_add(chain, g)
        }
        // Hints should be repeatable: greedy decoding.
        llama_sampler_chain_add(chain, llama_sampler_init_greedy())
        return chain
    }

    private func tokenize(_ text: String) -> [llama_token] {
        let len = Int32(text.utf8.count)
        var out = [llama_token](repeating: 0, count: Int(len) + 8)
        var n = llama_tokenize(vocab, text, len, &out, Int32(out.count), true, true)
        if n < 0 {
            out = [llama_token](repeating: 0, count: Int(-n))
            n = llama_tokenize(vocab, text, len, &out, Int32(out.count), true, true)
        }
        return Array(out.prefix(Int(max(0, n))))
    }

    /// The model's own chat template (llama.cpp knows ChatML, which every
    /// catalog model uses); plain ChatML if it can't be applied.
    private func formatChat(system: String, user: String) -> String {
        let chatML = "<|im_start|>system\n\(system)<|im_end|>\n<|im_start|>user\n\(user)<|im_end|>\n<|im_start|>assistant\n"
        let applied: String? = system.withCString { s in user.withCString { u in
            "system".withCString { rs in "user".withCString { ru in
                var msgs = [llama_chat_message(role: rs, content: s), llama_chat_message(role: ru, content: u)]
                var buf = [CChar](repeating: 0, count: (system.utf8.count + user.utf8.count) * 2 + 512)
                var n = llama_chat_apply_template(template, &msgs, 2, true, &buf, Int32(buf.count))
                if n > Int32(buf.count) {
                    buf = [CChar](repeating: 0, count: Int(n) + 1)
                    n = llama_chat_apply_template(template, &msgs, 2, true, &buf, Int32(buf.count))
                }
                guard n > 0 else { return nil }
                return String(decoding: buf[0..<Int(n)].map { UInt8(bitPattern: $0) }, as: UTF8.self)
            } }
        } }
        return applied ?? chatML
    }

    private static func physicalCores() -> Int {
        var cores: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.physicalcpu", &cores, &size, nil, 0) == 0, cores > 0 { return Int(cores) }
        return ProcessInfo.processInfo.activeProcessorCount
    }
}
