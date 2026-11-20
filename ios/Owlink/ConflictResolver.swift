import UIKit
import CedricCore

/// An iCloud conflict on an open document (its state has `.inConflict`).
///
/// Nothing is resolved until every version's bytes, and any unsaved text,
/// are copied to the app's private store (`SaveSafetyStores.copies`).
/// Then the person chooses Keep This / Keep Other / Keep Both, and the
/// choice runs in Apple's documented order: replace the file with the
/// chosen version, remove the other versions, mark the conflict versions
/// resolved (Document-Based App Programming Guide for iOS, "Resolving
/// Document Version Conflicts"). Reads and writes are coordinated, with
/// the document as the presenter so it isn't asked to step aside for
/// itself, off the main thread.
@MainActor final class ConflictResolver {
    enum Failure: LocalizedError {
        case noCopy(String)
        case copyBeside(String)
        case resolve(String)
        var errorDescription: String? {
            switch self {
            case .noCopy(let why):
                return String(localized: "Owlink couldn’t make a safety copy of every version (\(why)), so it left the conflict as it is. Nothing was removed.")
            case .copyBeside(let why):
                return String(localized: "Owlink couldn’t save the other version beside the file (\(why)). Nothing was removed.")
            case .resolve(let why):
                return String(localized: "Owlink couldn’t finish resolving the conflict (\(why)). Copies of every version are kept.")
            }
        }
    }

    struct Versions {
        var current: NSFileVersion?
        /// Unresolved conflict versions, newest first.
        var others: [NSFileVersion]
    }

    private let document: TextDocument
    private let queue = DispatchQueue(label: "app.owlink.conflict", qos: .userInitiated)

    init(document: TextDocument) { self.document = document }

    func versions() -> Versions {
        let url = document.fileURL
        let others = (NSFileVersion.unresolvedConflictVersionsOfItem(at: url) ?? [])
            .sorted { ($0.modificationDate ?? .distantPast) > ($1.modificationDate ?? .distantPast) }
        return Versions(current: NSFileVersion.currentVersionOfItem(at: url), others: others)
    }

    /// Copies every version's bytes, and the unsaved text if any, then
    /// calls back on the main queue (nil: all copied).
    func backUp(_ v: Versions, unsavedText: String?, done: @escaping (Failure?) -> Void) {
        let doc = document
        let path = doc.recoveryPath, name = doc.displayName, url = doc.fileURL
        let encoding = doc.encoding, lineEnding = doc.lineEnding
        let others = v.others.map { ($0.url, $0.modificationDate, $0.localizedNameOfSavingComputer) }
        let currentDate = v.current?.modificationDate, currentDevice = v.current?.localizedNameOfSavingComputer
        let store = SaveSafetyStores.copies
        queue.async {
            var failure: Failure?
            do {
                // This device's version: the file itself, read coordinated.
                var readError: NSError?
                var current: Data?
                var inner: Error?
                NSFileCoordinator(filePresenter: doc).coordinate(readingItemAt: url, options: [], error: &readError) { u in
                    do { current = try Data(contentsOf: u) } catch { inner = error }
                }
                if let e = readError ?? inner { throw e }
                try store.keep(current ?? Data(), as: SafetyCopy(documentPath: path, displayName: name, kind: .conflictVersion,
                                                                 sourceDate: currentDate, device: currentDevice))
                for (u, date, device) in others {
                    let data = try Data(contentsOf: u)
                    try store.keep(data, as: SafetyCopy(documentPath: path, displayName: name, kind: .conflictVersion,
                                                        sourceDate: date, device: device))
                }
                if let unsavedText {
                    let enc = TextCodec.encode(unsavedText, encoding: encoding, lineEnding: lineEnding)
                    try store.keep(enc ?? Data(unsavedText.utf8),
                                   as: SafetyCopy(documentPath: path, displayName: name, kind: .unsavedText,
                                                  encoding: enc == nil ? .utf8 : encoding))
                }
            } catch {
                failure = .noCopy(error.localizedDescription)
            }
            DispatchQueue.main.async { done(failure) }
        }
    }

    /// Runs the choice's steps; calls back on the main queue with the name
    /// of the copy saved beside the file (Keep Both) or the failure.
    func resolve(_ choice: ConflictResolution.Choice, _ v: Versions, done: @escaping (Result<String?, Failure>) -> Void) {
        let doc = document
        let url = doc.fileURL
        queue.async {
            var savedName: String?
            do {
                for step in ConflictResolution.steps(for: choice) {
                    switch step {
                    case .copyAllVersions, .reload:
                        break // done before (backUp) and after (by the editor)
                    case .saveOthersAsCopies:
                        do {
                            for other in v.others {
                                savedName = try Self.saveBeside(url, data: try Data(contentsOf: other.url),
                                                                date: other.modificationDate ?? Date(), presenter: doc)
                            }
                        } catch {
                            throw Failure.copyBeside(error.localizedDescription)
                        }
                    case .replaceWithOther:
                        guard let other = v.others.first else { break }
                        var coordError: NSError?
                        var inner: Error?
                        NSFileCoordinator(filePresenter: doc).coordinate(writingItemAt: url, options: .forReplacing, error: &coordError) { u in
                            do { _ = try other.replaceItem(at: u, options: []) } catch { inner = error }
                        }
                        if let e = coordError ?? inner { throw Failure.resolve(e.localizedDescription) }
                    case .removeOtherVersions:
                        do { try NSFileVersion.removeOtherVersionsOfItem(at: url) } catch { throw Failure.resolve(error.localizedDescription) }
                    case .markResolved:
                        // The versions fetched before removing: those are the conflict ones.
                        for o in v.others { o.isResolved = true }
                        for o in NSFileVersion.unresolvedConflictVersionsOfItem(at: url) ?? [] { o.isResolved = true }
                    }
                }
                DispatchQueue.main.async { done(.success(savedName)) }
            } catch let f as Failure {
                DispatchQueue.main.async { done(.failure(f)) }
            } catch {
                DispatchQueue.main.async { done(.failure(.resolve(error.localizedDescription))) }
            }
        }
    }

    /// Writes `data` as "<name> (conflict <date>).<ext>" in the file's folder.
    nonisolated private static func saveBeside(_ url: URL, data: Data, date: Date, presenter: NSFilePresenter) throws -> String {
        let dir = url.deletingLastPathComponent()
        let name = ConflictResolution.copyName(for: url.lastPathComponent, date: date) {
            FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path)
        }
        let dest = dir.appendingPathComponent(name)
        var coordError: NSError?
        var inner: Error?
        NSFileCoordinator(filePresenter: presenter).coordinate(writingItemAt: dest, options: .forReplacing, error: &coordError) { u in
            do { try data.write(to: u, options: .withoutOverwriting) } catch { inner = error }
        }
        if let e = coordError ?? inner { throw e }
        return name
    }

    /// Keep This / Keep Other / Keep Both, with when and where each was saved.
    static func chooser(name: String, _ v: Versions, note: String? = nil,
                        choose: @escaping (ConflictResolution.Choice) -> Void) -> UIAlertController {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        f.doesRelativeDateFormatting = true
        func line(_ label: String, _ ver: NSFileVersion?) -> String {
            var s = label
            if let d = ver?.modificationDate { s += ": " + String(localized: "saved \(f.string(from: d))") }
            if let dev = ver?.localizedNameOfSavingComputer { s += " " + String(localized: "on \(dev)") }
            return s
        }
        var lines = [line(String(localized: "This version"), v.current), line(String(localized: "Other version"), v.others.first)]
        if v.others.count > 1 { lines.append(String(localized: "\(v.others.count - 1) more other versions are kept as copies too.")) }
        lines.append(String(localized: "A safety copy of every version is already kept in Owlink."))
        if let note { lines.insert(note, at: 0) }
        let a = UIAlertController(title: String(localized: "\(name) was changed on another device too"),
                                  message: lines.joined(separator: "\n"), preferredStyle: .alert)
        a.addAction(UIAlertAction(title: String(localized: "Keep This Version"), style: .default) { _ in choose(.keepThis) })
        a.addAction(UIAlertAction(title: String(localized: "Keep Other Version"), style: .default) { _ in choose(.keepOther) })
        a.addAction(UIAlertAction(title: String(localized: "Keep Both"), style: .default) { _ in choose(.keepBoth) })
        a.preferredAction = a.actions.last
        return a
    }
}
