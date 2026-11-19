import AppKit
import CedricCore

/// CEDRIC_CHECK=tabbar (Scripts/tools-check.sh, 0.2.1): in every theme the
/// app's appearance is the theme's and no window keeps one of its own, so
/// the native window tab bar (drawn from the app's appearance on macOS 26)
/// agrees with the windows it sits in. Writes a snapshot per theme.
@MainActor
extension DevChecks {
    static func tabBarCheck(_ app: AppDelegate) {
        guard let a = app.open(write("app.js", "console.log(1)\n")), let b = app.open(write("notes.txt", "notes\n")) else {
            expect(false, "two tabs open"); finish(); return
        }
        sized(a); sized(b)
        func views(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(views) }
        func tabBar(_ w: NSWindow?) -> NSView? {
            guard let frame = w?.contentView?.superview else { return nil }
            return views(frame).first { String(describing: Swift.type(of: $0)).contains("TabBar") }
        }
        let before = Settings.shared.themeOverride
        var steps: [(@escaping () -> Void) -> Void] = [sync {
            expect(a.window?.tabGroup === b.window?.tabGroup && (a.window?.tabGroup?.windows.count ?? 0) >= 2, "the two files are tabs of one window")
        }]
        for theme in EditorTheme.allCases where theme != .system {
            steps.append(sync {
                Settings.shared.themeOverride = theme
                NotificationCenter.default.post(name: .cedricAppearanceChanged, object: nil)
                let dark = Settings.shared.palette(for: nil).isDark
                let want: NSAppearance.Name = dark ? .darkAqua : .aqua
                let appName = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
                expect(appName == want, "\(theme.rawValue): the app's appearance is the theme's", "\(appName?.rawValue ?? "-")")
                let own = app.tabs.compactMap { $0.window?.appearance?.name.rawValue }
                expect(own.isEmpty, "\(theme.rawValue): no window has an appearance of its own", "\(own)")
                let w = b.window?.tabGroup?.selectedWindow ?? b.window
                let bar = tabBar(w)
                if let bar {
                    expect(bar.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == want, "\(theme.rawValue): the tab bar draws in the same appearance",
                           bar.effectiveAppearance.name.rawValue)
                } else {
                    print("check: note: no tab bar view found in the frame view (screen locked?)")
                }
            })
            steps.append(snapshot("tabbar-\(theme.rawValue).png"))
        }
        steps.append(sync {
            Settings.shared.themeOverride = before
            NotificationCenter.default.post(name: .cedricAppearanceChanged, object: nil)
        })
        run(steps)
    }
}
