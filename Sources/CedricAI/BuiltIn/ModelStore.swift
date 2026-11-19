import Foundation
import CedricCore

/// Where downloaded models live: `~/Library/Application Support/Cedric/Models/`.
///
/// - `<fileName>`: a finished, verified model;
/// - `<fileName>.verified`: the SHA-256 it was verified against (a model is
///   "installed" only when the file has the catalog's size and this marker
///   matches the catalog's hash, so a catalog update re-downloads);
/// - `.partial/<fileName>.part`: an unfinished download, resumable.
public struct ModelStore: Sendable {
    public let directory: URL

    public init(directory: URL = ModelStore.defaultDirectory) {
        self.directory = directory
    }

    /// CEDRIC_MODELS_DIR=/dir overrides it (the app checks use a temp dir).
    public static var defaultDirectory: URL {
        if let dir = ProcessInfo.processInfo.environment["CEDRIC_MODELS_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: dir, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Cedric/Models", isDirectory: true)
    }

    var partialDirectory: URL { directory.appendingPathComponent(".partial", isDirectory: true) }

    public func fileURL(for model: BuiltInModel) -> URL { directory.appendingPathComponent(model.fileName) }
    func markerURL(for model: BuiltInModel) -> URL { directory.appendingPathComponent(model.fileName + ".verified") }
    public func partialURL(for model: BuiltInModel) -> URL { partialDirectory.appendingPathComponent(model.fileName + ".part") }

    public func isInstalled(_ model: BuiltInModel) -> Bool {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: fileURL(for: model).path),
              (attrs[.size] as? NSNumber)?.int64Value == model.sizeBytes,
              let mark = try? String(contentsOf: markerURL(for: model), encoding: .utf8) else { return false }
        return mark.trimmingCharacters(in: .whitespacesAndNewlines) == model.sha256
    }

    /// Bytes already downloaded for an unfinished download (0 if none).
    public func partialBytes(_ model: BuiltInModel) -> Int64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: partialURL(for: model).path)
        return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
    }

    public func installed(in catalog: ModelCatalog) -> [BuiltInModel] { catalog.models.filter(isInstalled) }

    /// Removes the model, its marker and any partial download.
    public func delete(_ model: BuiltInModel) throws {
        let fm = FileManager.default
        for url in [fileURL(for: model), markerURL(for: model), partialURL(for: model)]
        where fm.fileExists(atPath: url.path) {
            try fm.removeItem(at: url)
        }
    }

    func prepare() throws {
        try PrivateDirectory.make(partialDirectory)
    }

    /// Moves a verified partial into place and writes its marker.
    func install(_ model: BuiltInModel, from partial: URL) throws {
        let fm = FileManager.default
        let dest = fileURL(for: model)
        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        try fm.moveItem(at: partial, to: dest)
        try model.sha256.write(to: markerURL(for: model), atomically: true, encoding: .utf8)
        // Models are re-downloadable; keep them out of Time Machine.
        var url = dest
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    /// Free space for new files on the volume holding `url` (walks up to an
    /// existing ancestor), as the system counts it for important downloads.
    public static func freeSpace(at url: URL) -> Int64? {
        var probe = url
        while !FileManager.default.fileExists(atPath: probe.path), probe.pathComponents.count > 1 {
            probe = probe.deletingLastPathComponent()
        }
        let values = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey,
                                                         .volumeAvailableCapacityKey])
        if let important = values?.volumeAvailableCapacityForImportantUsage, important > 0 { return important }
        return values?.volumeAvailableCapacity.map(Int64.init)
    }
}
