import Foundation
import CryptoKit

public enum ModelDownloadError: Error, Equatable, Sendable {
    case notEnoughSpace(needed: Int64, available: Int64)
    case disallowedHost
    case http(Int)
    case transport(String)
    case sizeMismatch(expected: Int64, got: Int64)
    case checksumMismatch
    case io(String)

    public var message: String {
        switch self {
        case .notEnoughSpace(let needed, let available):
            let f = ByteCountFormatter()
            return "Not enough disk space: needs \(f.string(fromByteCount: needed)), \(f.string(fromByteCount: available)) free."
        case .disallowedHost: return "Models are only downloaded from huggingface.co."
        case .http(let code): return "The download server answered HTTP \(code)."
        case .transport(let s): return "Download interrupted: \(s)"
        case .sizeMismatch(let e, let g): return "The download has the wrong size (\(g) bytes, expected \(e)). It was deleted."
        case .checksumMismatch: return "The download didn't match its checksum and was deleted."
        case .io(let s): return "Couldn't save the model: \(s)"
        }
    }
}

public enum ModelDownloadState: Sendable, Equatable {
    case notDownloaded
    case downloading(received: Int64, total: Int64)
    case paused(received: Int64, total: Int64)
    case verifying
    case installed
    case failed(ModelDownloadError)

    public var fraction: Double? {
        switch self {
        case .downloading(let r, let t), .paused(let r, let t): return t > 0 ? Double(r) / Double(t) : nil
        case .installed: return 1
        default: return nil
        }
    }

    public var isActive: Bool {
        if case .downloading = self { return true }
        return self == .verifying
    }
}

/// Downloads catalog models into a `ModelStore`, one HTTPS GET per model,
/// with HTTP `Range` resume from `.partial/<file>.part` (so pause, quit and
/// relaunch, or a dropped connection all continue where they stopped).
/// The SHA-256 is computed while bytes arrive (re-hashing the partial file
/// first on resume) and checked before the file is moved into place; a
/// mismatch deletes the file. Only `https://huggingface.co/...` URLs are
/// fetched; redirects to its CDN are followed. No telemetry: the request
/// carries no cookies, no identifiers, nothing but the URL.
public actor ModelDownloader {
    public typealias Observer = @Sendable (String, ModelDownloadState) -> Void

    /// Extra free space required beyond the bytes still to download.
    public static let headroom: Int64 = 256 * 1_048_576

    public nonisolated let store: ModelStore
    let configuration: URLSessionConfiguration
    let freeSpace: @Sendable (URL) -> Int64?
    var observer: Observer?

    private var states: [String: ModelDownloadState] = [:]
    private var transfers: [String: Transfer] = [:]
    private var waiters: [String: [CheckedContinuation<ModelDownloadState, Never>]] = [:]

    public init(store: ModelStore = ModelStore(),
                configuration: URLSessionConfiguration? = nil,
                freeSpace: @escaping @Sendable (URL) -> Int64? = { ModelStore.freeSpace(at: $0) },
                observer: Observer? = nil) {
        self.store = store
        let config = configuration ?? .ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 60
        config.waitsForConnectivity = false
        self.configuration = config
        self.freeSpace = freeSpace
        self.observer = observer
    }

    public func setObserver(_ observer: Observer?) { self.observer = observer }

    /// The current state, reading the disk when nothing is running.
    public func state(of model: BuiltInModel) -> ModelDownloadState {
        if let s = states[model.id], s != .notDownloaded {
            if case .failed = s { return s }
            if s.isActive || transfers[model.id] != nil { return s }
        }
        if store.isInstalled(model) { return .installed }
        let part = store.partialBytes(model)
        if part > 0 { return .paused(received: part, total: model.sizeBytes) }
        return states[model.id] ?? .notDownloaded
    }

    /// Starts (or resumes) a download. Throws before any network request
    /// for a non-Hugging Face URL or when the disk is too full.
    public func start(_ model: BuiltInModel) throws {
        guard transfers[model.id] == nil else { return }
        if store.isInstalled(model) { set(model.id, .installed); return }
        guard model.url.scheme == "https", model.url.host == ModelCatalog.allowedHost else {
            throw ModelDownloadError.disallowedHost
        }
        do { try store.prepare() } catch { throw ModelDownloadError.io(error.localizedDescription) }
        let have = min(store.partialBytes(model), model.sizeBytes)
        let needed = model.sizeBytes - have + Self.headroom
        if let available = freeSpace(store.directory), available < needed {
            let err = ModelDownloadError.notEnoughSpace(needed: needed, available: available)
            set(model.id, .failed(err))
            throw err
        }
        // One ordered stream per transfer, so "verifying" can never land
        // after "finished".
        let (events, sink) = AsyncStream<Transfer.Event>.makeStream()
        let transfer = Transfer(model: model, partial: store.partialURL(for: model),
                                configuration: configuration) { event in
            sink.yield(event)
            if case .finished = event { sink.finish() }
        }
        Task { [weak self] in
            for await event in events { await self?.handle(model, event) }
        }
        transfers[model.id] = transfer
        set(model.id, .downloading(received: have, total: model.sizeBytes))
        transfer.begin()
    }

    /// Stops the transfer and keeps the partial file for `start` to resume.
    public func pause(_ model: BuiltInModel) {
        transfers[model.id]?.stop(.pause)
    }

    /// Stops the transfer and deletes the partial file.
    public func cancel(_ model: BuiltInModel) {
        if let t = transfers[model.id] {
            t.stop(.cancel)
        } else {
            try? FileManager.default.removeItem(at: store.partialURL(for: model))
            set(model.id, .notDownloaded)
        }
    }

    /// Deletes an installed model (and any partial).
    public func delete(_ model: BuiltInModel) throws {
        transfers[model.id]?.stop(.cancel)
        try store.delete(model)
        set(model.id, .notDownloaded)
    }

    /// Waits until the model's download stops: installed, paused, failed or
    /// cancelled (`.notDownloaded`). Returns at once if nothing is running.
    public func waitUntilSettled(_ model: BuiltInModel) async -> ModelDownloadState {
        guard transfers[model.id] != nil else { return state(of: model) }
        return await withCheckedContinuation { waiters[model.id, default: []].append($0) }
    }

    // MARK: Transfer events

    private func handle(_ model: BuiltInModel, _ event: Transfer.Event) {
        let id = model.id
        switch event {
        case .progress(let received):
            guard transfers[id] != nil else { return }
            set(id, .downloading(received: received, total: model.sizeBytes))
        case .verifying:
            guard transfers[id] != nil else { return }
            set(id, .verifying)
        case .finished(let result):
            transfers[id] = nil
            let final: ModelDownloadState
            switch result {
            case .installed(let digest):
                if digest != model.sha256 {
                    try? FileManager.default.removeItem(at: store.partialURL(for: model))
                    final = .failed(.checksumMismatch)
                } else {
                    do {
                        try store.install(model, from: store.partialURL(for: model))
                        final = .installed
                    } catch {
                        final = .failed(.io(error.localizedDescription))
                    }
                }
            case .paused(let received):
                final = .paused(received: received, total: model.sizeBytes)
            case .cancelled:
                try? FileManager.default.removeItem(at: store.partialURL(for: model))
                final = .notDownloaded
            case .failed(let error, let keepPartial):
                if !keepPartial { try? FileManager.default.removeItem(at: store.partialURL(for: model)) }
                final = .failed(error)
            }
            set(id, final)
            for w in waiters.removeValue(forKey: id) ?? [] { w.resume(returning: final) }
        }
    }

    private func set(_ id: String, _ state: ModelDownloadState) {
        guard states[id] != state else { return }
        states[id] = state
        observer?(id, state)
    }
}

/// One HTTP transfer. All of its mutable state lives on its delegate queue.
final class Transfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    enum Stop { case pause, cancel }
    enum Result {
        case installed(sha256: String)
        case paused(Int64)
        case cancelled
        case failed(ModelDownloadError, keepPartial: Bool)
    }
    enum Event {
        case progress(Int64)
        case verifying
        case finished(Result)
    }

    let model: BuiltInModel
    let partial: URL
    let emit: @Sendable (Event) -> Void
    private let queue: OperationQueue
    private var session: URLSession!

    // Delegate-queue state.
    private var handle: FileHandle?
    private var hasher = SHA256()
    private var received: Int64 = 0
    private var requestedOffset: Int64 = 0
    private var stopReason: Stop?
    private var failure: ModelDownloadError?
    private var lastProgress = Date.distantPast
    private var done = false

    init(model: BuiltInModel, partial: URL, configuration: URLSessionConfiguration,
         emit: @escaping @Sendable (Event) -> Void) {
        self.model = model
        self.partial = partial
        self.emit = emit
        queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.name = "net.mindtricks.cedric.model-download"
        queue.qualityOfService = .utility
        super.init()
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
    }

    func begin() {
        queue.addOperation { [self] in
            do {
                let fm = FileManager.default
                if !fm.fileExists(atPath: partial.path) { fm.createFile(atPath: partial.path, contents: nil) }
                let h = try FileHandle(forUpdating: partial)
                // Re-hash what is already there, so the checksum covers the whole file.
                var offset: Int64 = 0
                while true {
                    let chunk = try h.read(upToCount: 8 << 20) ?? Data()
                    if chunk.isEmpty { break }
                    hasher.update(data: chunk)
                    offset += Int64(chunk.count)
                }
                if offset > model.sizeBytes {
                    try h.truncate(atOffset: 0); hasher = SHA256(); offset = 0
                }
                handle = h
                received = offset
                requestedOffset = offset
            } catch {
                finish(.failed(.io(error.localizedDescription), keepPartial: true))
                return
            }
            if stopReason != nil { finish(stopReason == .pause ? .paused(received) : .cancelled); return }
            if received == model.sizeBytes { verifyAndFinish(); return }
            var request = URLRequest(url: model.url)
            request.setValue("Cedric", forHTTPHeaderField: "User-Agent")
            if received > 0 { request.setValue("bytes=\(received)-", forHTTPHeaderField: "Range") }
            session.dataTask(with: request).resume()
        }
    }

    func stop(_ reason: Stop) {
        queue.addOperation { [self] in
            guard !done else { return }
            stopReason = reason
            session.getAllTasks { tasks in tasks.forEach { $0.cancel() } }
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            failure = .transport("not an HTTP response"); completionHandler(.cancel); return
        }
        switch http.statusCode {
        case 206 where requestedOffset > 0:
            let range = http.value(forHTTPHeaderField: "Content-Range") ?? ""
            if !range.hasPrefix("bytes \(requestedOffset)-") {
                failure = .transport("unexpected range \(range)"); completionHandler(.cancel); return
            }
        case 200:
            if requestedOffset > 0 {
                // The server ignored Range: start over.
                do { try handle?.truncate(atOffset: 0) } catch {
                    failure = .io(error.localizedDescription); completionHandler(.cancel); return
                }
                hasher = SHA256(); received = 0; requestedOffset = 0
            }
        default:
            failure = .http(http.statusCode); completionHandler(.cancel); return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard failure == nil, stopReason == nil, let handle else { return }
        if received + Int64(data.count) > model.sizeBytes {
            failure = .sizeMismatch(expected: model.sizeBytes, got: received + Int64(data.count))
            dataTask.cancel()
            return
        }
        do { try handle.write(contentsOf: data) } catch {
            failure = .io(error.localizedDescription); dataTask.cancel(); return
        }
        hasher.update(data: data)
        received += Int64(data.count)
        let now = Date()
        if now.timeIntervalSince(lastProgress) >= 0.25 {
            lastProgress = now
            emit(.progress(received))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let stopReason {
            finish(stopReason == .pause ? .paused(received) : .cancelled); return
        }
        if let failure {
            // A bad size or an I/O error poisons the partial; an HTTP or
            // network error leaves it for a later resume.
            let keep: Bool
            switch failure {
            case .sizeMismatch: keep = false
            default: keep = true
            }
            finish(.failed(failure, keepPartial: keep)); return
        }
        if let error {
            finish(.failed(.transport(error.localizedDescription), keepPartial: true)); return
        }
        emit(.progress(received))
        guard received == model.sizeBytes else {
            finish(.failed(.sizeMismatch(expected: model.sizeBytes, got: received), keepPartial: false)); return
        }
        verifyAndFinish()
    }

    private func verifyAndFinish() {
        emit(.verifying)
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        finish(.installed(sha256: digest))
    }

    private func finish(_ result: Result) {
        guard !done else { return }
        done = true
        try? handle?.synchronize()
        try? handle?.close()
        handle = nil
        session.finishTasksAndInvalidate()
        emit(.finished(result))
    }
}
