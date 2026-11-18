import Foundation

/// UserDefaults suites for tests that never touch ~/Library/Preferences:
/// each suite is named by an absolute path (CFPreferences then keeps it in
/// that file), in `TMPDIR/cedric-test-prefs`, and removed afterwards. The
/// old way (a plain suite name) left a plist per suite behind, even after
/// removePersistentDomain: build 7's pass found 806 of them. Scripts/test.sh
/// sweeps stale ones from both places.
enum TestDefaults {
    /// Every prefix a Cedric test suite name starts with (test.sh matches these).
    static let prefixes = ["cedric-owl-test-", "cedric-ai-test-", "cedric-tests-", "cedric-default-", "cedric-bridge-", "cedric-accept-"]

    static let directory: String = {
        let d = (NSTemporaryDirectory() as NSString).appendingPathComponent("cedric-test-prefs")
        try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
        return d
    }()

    /// The suite name (a path) for `prefix` + a UUID.
    static func name(_ prefix: String) -> String {
        precondition(prefixes.contains(prefix), "add \(prefix) to TestDefaults.prefixes and test.sh")
        return (directory as NSString).appendingPathComponent(prefix + UUID().uuidString)
    }

    /// A fresh suite and its name.
    static func make(_ prefix: String) -> (defaults: UserDefaults, name: String) {
        let n = name(prefix)
        return (UserDefaults(suiteName: n)!, n)
    }

    static func remove(_ name: String) {
        try? FileManager.default.removeItem(atPath: name + ".plist")
    }
}
