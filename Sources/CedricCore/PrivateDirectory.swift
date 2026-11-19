import Foundation

/// Cedric's folder in Application Support (~/Library/Application
/// Support/Cedric) holds the CLI token and the session's unsaved buffers,
/// so it and the folders Cedric makes in it are owner-only (0700). The
/// `cedric` script makes it the same way (mkdir -p -m 700).
public enum PrivateDirectory {
    /// ~/Library/Application Support/Cedric
    public static var supportRoot: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        return base.appendingPathComponent("Cedric", isDirectory: true)
    }

    /// Makes `dir` and any missing parents 0700. `dir`, and `root` when
    /// `dir` is inside it, are tightened to 0700 if they already exist
    /// wider (made by an older version); only this user's own real folders,
    /// never through a symbolic link.
    public static func make(_ dir: URL, root: URL = supportRoot) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        tighten(dir.path)
        let r = root.standardizedFileURL.path, d = dir.standardizedFileURL.path
        if d != r, d.hasPrefix(r.hasSuffix("/") ? r : r + "/") { tighten(r) }
    }

    /// chmod 0700 if `path` is this user's own folder (not a link) that
    /// others can reach. True if it is (now) owner-only.
    @discardableResult
    static func tighten(_ path: String) -> Bool {
        var st = stat()
        guard lstat(path, &st) == 0, st.st_mode & S_IFMT == S_IFDIR, st.st_uid == getuid() else { return false }
        if st.st_mode & 0o077 == 0 { return true }
        return chmod(path, 0o700) == 0
    }
}
