import Foundation
import CedricCore

/// The owl's facts that need the disk, read lazily and off the main thread.
///
/// `FileProbe` answers Markdown's "does this relative link's file exist?":
/// the first time a path is asked it isn’t known (nil, the rule skips it)
/// and a stat runs on a background queue; the next query (at most one per
/// 30 s) has the answer. Answers are kept for 2 min, so a file made or
/// renamed since is seen again soon. Nothing here runs before the first
/// frame: the owl only asks after it.
final class FileProbe: @unchecked Sendable {
    let folder: URL
    private let lock = NSLock()
    private var known: [String: (exists: Bool, at: Date)] = [:]
    private var pending: Set<String> = []
    private static let queue = DispatchQueue(label: "owlink.owl.file-probe", qos: .utility)
    static let lifetime: TimeInterval = 120

    init(folder: URL) { self.folder = folder }

    /// The probe the rules call: relative path → exists, or nil (checking).
    /// Made on the main thread (`owlFacts`), called from the rules.
    lazy var rulesProbe: OwlFileProbe = OwlFileProbe { [weak self] rel in self?.exists(rel) ?? nil }

    func exists(_ rel: String) -> Bool? {
        let path = folder.appendingPathComponent(rel).standardizedFileURL.path
        lock.lock()
        defer { lock.unlock() }
        if let k = known[path], Date().timeIntervalSince(k.at) < Self.lifetime { return k.exists }
        if known.count > 2000 { known.removeAll() }
        guard pending.insert(path).inserted else { return nil }
        Self.queue.async { [weak self] in
            let e = FileManager.default.fileExists(atPath: path)
            guard let self else { return }
            self.lock.lock()
            self.known[path] = (e, Date())
            self.pending.remove(path)
            self.lock.unlock()
        }
        return nil
    }
}

extension EditorWindowController {
    /// Markdown files with a folder get the file probe (made on first use,
    /// replaced when the file moves).
    func owlFileProbe() -> OwlFileProbe? {
        guard doc.language == .markdown, let folder = doc.fileURL?.deletingLastPathComponent(), OwlFileProbe.probes(folder: folder) else { return nil }
        if let p = fileProbe, p.folder == folder { return p.rulesProbe }
        let p = FileProbe(folder: folder)
        fileProbe = p
        return p.rulesProbe
    }
}
