import Foundation

/// View › Follow File: watches a file with a DispatchSource and reports
/// what was appended, or the whole new content after it was truncated,
/// replaced or rotated (deleted or renamed, then recreated).
public final class FileTail: @unchecked Sendable {
    public enum Event: Sendable, Equatable {
        /// New text at the end (line endings normalised to LF).
        case appended(String)
        /// The file was truncated or replaced: this is all of it now.
        case reset(String)
    }

    public let url: URL
    public let encoding: TextEncoding
    private let queue = DispatchQueue(label: "cedric.filetail")
    private let callbackQueue: DispatchQueue
    private let handler: @Sendable (Event) -> Void
    // Touched only on `queue`.
    private var source: DispatchSourceFileSystemObject?
    private var retry: DispatchSourceTimer?
    private var offset: UInt64
    private var inode: UInt64 = 0
    private var pending = Data()
    private var stopped = false

    /// `offset`: how many bytes of the file the caller already shows.
    public init(url: URL, encoding: TextEncoding = .utf8, offset: UInt64, callbackQueue: DispatchQueue = .main,
                handler: @escaping @Sendable (Event) -> Void) {
        self.url = url
        self.encoding = encoding
        self.offset = offset
        self.callbackQueue = callbackQueue
        self.handler = handler
    }

    deinit { source?.cancel(); retry?.cancel() }

    public func start() {
        queue.async { [self] in
            inode = Self.fileInfo(url)?.inode ?? 0
            watch()
            check()
        }
    }

    public func stop() {
        queue.sync {
            stopped = true
            source?.cancel(); source = nil
            retry?.cancel(); retry = nil
        }
    }

    /// Checks the file now (the watcher calls this; tests may too).
    public func poll() { queue.async { [self] in check() } }

    static func fileInfo(_ url: URL) -> (size: UInt64, inode: UInt64)? {
        var st = Darwin.stat()
        guard stat(url.path, &st) == 0 else { return nil }
        return (UInt64(st.st_size), UInt64(st.st_ino))
    }

    private func watch() {
        source?.cancel(); source = nil
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { waitForFile(); return }
        let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename, .revoke, .attrib],
                                                          queue: queue)
        s.setEventHandler { [weak self, weak s] in
            guard let self, let s else { return }
            let ev = s.data
            if ev.contains(.delete) || ev.contains(.rename) || ev.contains(.revoke) {
                // Rotated: the old file is gone; follow the path.
                s.cancel()
                self.source = nil
                self.waitForFile()
            } else {
                self.check()
            }
        }
        s.setCancelHandler { close(fd) }
        source = s
        s.resume()
    }

    /// The path has no file (mid-rotation): look again every 250 ms.
    private func waitForFile() {
        guard !stopped, retry == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.25, repeating: 0.25)
        t.setEventHandler { [weak self] in
            guard let self, Self.fileInfo(self.url) != nil else { return }
            self.retry?.cancel(); self.retry = nil
            self.watch()
            self.check()
        }
        retry = t
        t.resume()
    }

    private func check() {
        guard !stopped, let st = Self.fileInfo(url) else { return }
        if st.inode != inode || st.size < offset {
            // Replaced or truncated: start over.
            let replaced = st.inode != inode
            inode = st.inode
            if replaced || source == nil { watch() }
            guard let data = try? Data(contentsOf: url) else { return }
            offset = UInt64(data.count)
            pending = Data()
            let text = TextCodec.decode(data, as: encoding)?.text ?? String(decoding: data, as: UTF8.self)
            emit(.reset(text))
            return
        }
        guard st.size > offset, let fh = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? fh.close() }
        do {
            try fh.seek(toOffset: offset)
            guard let chunk = try fh.read(upToCount: Int(st.size - offset)), !chunk.isEmpty else { return }
            offset += UInt64(chunk.count)
            var bytes = pending + chunk
            pending = Data()
            // Hold back a character cut in half at the end.
            var text: String?
            for cut in 0...min(3, bytes.count) {
                if let s = String(data: bytes.prefix(bytes.count - cut), encoding: encoding.foundation) {
                    text = s
                    pending = bytes.suffix(cut)
                    bytes = bytes.prefix(bytes.count - cut)
                    break
                }
            }
            guard var s = text, !s.isEmpty else { return }
            // A CR at the very end may be the first half of a CRLF.
            if s.hasSuffix("\r"), let cr = "\r".data(using: encoding.foundation) {
                s.removeLast()
                pending = cr + pending
            }
            guard !s.isEmpty else { return }
            emit(.appended(TextCodec.normalizeLineEndings(s)))
        } catch {
            return
        }
    }

    private func emit(_ e: Event) {
        let h = handler
        callbackQueue.async { h(e) }
    }
}
