import Foundation

/// The process environment as the app's code may see it.
///
/// The dev and check switches (`CEDRIC_*`, DevHooks.swift) open files,
/// write snapshots, drive the editor and point the owl at other models.
/// In a shipped build any local program could launch Owlink with them and
/// borrow Owlink's privacy (TCC) grants, so they are compiled in only when
/// `CEDRIC_CHECKS` is defined: debug builds (Package.swift) and the dev
/// `dist` build Scripts/bundle-app.sh makes by default. The release build
/// (`bundle-app.sh --release`, used by Scripts/release.sh) leaves it out
/// and sees only `releaseAllowed`: switches that name no file and only
/// skip or measure, which the release's own launch check uses.
///
/// Every read of a `CEDRIC_*` variable goes through `values`; nothing else
/// in the app reads `ProcessInfo.processInfo.environment` for them.
public enum DevEnvironment {
    #if CEDRIC_CHECKS
    public static let checksEnabled = true
    #else
    public static let checksEnabled = false
    #endif

    /// What a release build honours: no paths, no editing, no settings.
    public static let releaseAllowed: Set<String> = [
        "CEDRIC_LLAMA_CHECK",        // dlopen the bundled llama.framework, print, quit
        "CEDRIC_NO_RESTORE",         // don't restore the session
        "CEDRIC_NO_SESSION_SAVE",    // don't write it
        "CEDRIC_LAUNCH_METRICS",     // print launch time
        "CEDRIC_QUIT_AFTER_LAUNCH",  // and quit
    ]

    /// `env` without the `CEDRIC_*` switches a build without checks must ignore.
    public static func filter(_ env: [String: String], checksEnabled: Bool) -> [String: String] {
        if checksEnabled { return env }
        return env.filter { !$0.key.hasPrefix("CEDRIC_") || releaseAllowed.contains($0.key) }
    }

    /// The environment, filtered for this build.
    public static let values: [String: String] = filter(ProcessInfo.processInfo.environment, checksEnabled: checksEnabled)
}
