import UIKit
import CedricCore

/// How the navigation bar draws a theme.
///
/// The editor uses `navigationItem.style = .editor` with `documentProperties`,
/// so the file name is the document title (a menu), not the bar's plain
/// title label. On iOS 26/27 that title is drawn from the window scene: its
/// foreground comes from the scene's interface style and from the window
/// and navigation-bar tint, including `UINavigationBar.appearance()`, and
/// it ignores `titleTextAttributes` on the bar instance. Setting only those
/// attributes, or only the navigation controller's interface style, leaves
/// the name on the phone's label colour — near-black on a dark theme while
/// the phone is in light mode.
enum EditorBarStyle {
    /// System follows the phone. A fixed theme forces its own light or dark.
    static func interfaceStyle(theme: EditorTheme, isDark: Bool) -> UIUserInterfaceStyle {
        theme == .system ? .unspecified : (isDark ? .dark : .light)
    }

    /// One appearance, shared by the bar, the item and the appearance proxy.
    static func appearance(foreground: UIColor) -> UINavigationBarAppearance {
        let appearance = UINavigationBarAppearance()
        appearance.configureWithDefaultBackground()
        let title: [NSAttributedString.Key: Any] = [.foregroundColor: foreground]
        appearance.titleTextAttributes = title
        appearance.largeTitleTextAttributes = title
        if #available(iOS 26.0, *) {
            appearance.subtitleTextAttributes = title
            appearance.largeSubtitleTextAttributes = title
        }
        return appearance
    }

    static func apply(navigationController: UINavigationController?,
                      item: UINavigationItem,
                      window: UIWindow?,
                      foreground: UIColor,
                      interfaceStyle: UIUserInterfaceStyle) {
        let appearance = appearance(foreground: foreground)
        let titleAttributes: [NSAttributedString.Key: Any] = [.foregroundColor: foreground]
        // The document title is built from the process-wide proxy, not only
        // the bar it is shown in. Restored when the editor goes away.
        let proxy = UINavigationBar.appearance()
        proxy.tintColor = foreground
        proxy.titleTextAttributes = titleAttributes
        proxy.standardAppearance = appearance
        proxy.compactAppearance = appearance
        proxy.scrollEdgeAppearance = appearance
        proxy.compactScrollEdgeAppearance = appearance
        proxy.overrideUserInterfaceStyle = interfaceStyle
        if let bar = navigationController?.navigationBar {
            bar.standardAppearance = appearance
            bar.compactAppearance = appearance
            bar.scrollEdgeAppearance = appearance
            bar.compactScrollEdgeAppearance = appearance
            bar.tintColor = foreground
            bar.titleTextAttributes = titleAttributes
            bar.overrideUserInterfaceStyle = interfaceStyle
        }
        item.standardAppearance = appearance
        item.compactAppearance = appearance
        item.scrollEdgeAppearance = appearance
        item.compactScrollEdgeAppearance = appearance
        // iOS 26 draws `attributedTitle` (and ignores it when a title view
        // is set; the editor does not set one). The document title still
        // follows the tint, which is why the tint is set as well.
        if #available(iOS 26.0, *) {
            item.attributedTitle = colored(item.title, foreground)
            item.attributedSubtitle = colored(item.subtitle, foreground)
        }
        if let nav = navigationController {
            nav.view.tintColor = foreground
            if nav.overrideUserInterfaceStyle != interfaceStyle {
                nav.overrideUserInterfaceStyle = interfaceStyle
                nav.setNeedsStatusBarAppearanceUpdate()
            }
        }
        guard let window else { return }
        window.tintColor = foreground
        if window.overrideUserInterfaceStyle != interfaceStyle {
            window.overrideUserInterfaceStyle = interfaceStyle
        }
        window.traitOverrides.userInterfaceStyle = interfaceStyle
        window.windowScene?.traitOverrides.userInterfaceStyle = interfaceStyle
    }

    /// Puts the appearance proxy and the scene back to the phone's style
    /// once the editor (or a detached preview) has gone.
    static func restore(window: UIWindow?) {
        let proxy = UINavigationBar.appearance()
        let blank = UINavigationBarAppearance()
        blank.configureWithDefaultBackground()
        proxy.tintColor = nil
        proxy.titleTextAttributes = nil
        proxy.standardAppearance = blank
        proxy.compactAppearance = blank
        proxy.scrollEdgeAppearance = blank
        proxy.compactScrollEdgeAppearance = blank
        proxy.overrideUserInterfaceStyle = .unspecified
        window?.tintColor = nil
        window?.overrideUserInterfaceStyle = .unspecified
        window?.traitOverrides.userInterfaceStyle = .unspecified
        window?.windowScene?.traitOverrides.userInterfaceStyle = .unspecified
    }

    /// Draws `view` (the editor's navigation bar) to a PNG. `-OwlinkNavBarPNG
    /// <path>` on a debug launch asks for this; the self-check writes one
    /// beside each window shot.
    static func renderNavigationBar(_ view: UIView, to url: URL) {
        view.layoutIfNeeded()
        let bounds = view.bounds
        guard bounds.width > 1, bounds.height > 1 else { return }
        let format = UIGraphicsImageRendererFormat()
        format.scale = view.traitCollection.displayScale > 0 ? view.traitCollection.displayScale : 2
        let image = UIGraphicsImageRenderer(bounds: bounds, format: format).image { _ in
            view.drawHierarchy(in: bounds, afterScreenUpdates: true)
        }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? image.pngData()?.write(to: url)
    }

    static func renderNavigationBarIfRequested(_ view: UIView?) {
        guard let view else { return }
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-OwlinkNavBarPNG"), i + 1 < args.count else { return }
        renderNavigationBar(view, to: URL(fileURLWithPath: args[i + 1]))
    }

    @available(iOS 26.0, *)
    private static func colored(_ text: String?, _ foreground: UIColor) -> AttributedString? {
        guard let text, !text.isEmpty else { return nil }
        var styled = AttributedString(text)
        styled.uiKit.foregroundColor = foreground
        return styled
    }
}
