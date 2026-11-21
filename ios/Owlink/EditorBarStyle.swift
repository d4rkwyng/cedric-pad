import UIKit
import CedricCore

/// How the navigation bar draws a theme.
///
/// On iOS 26/27 the editor-style document title (`navigationItem.style =
/// .editor` plus `documentProperties`) is drawn from the window scene, not
/// from the navigation controller. `overrideUserInterfaceStyle` on the
/// navigation controller alone leaves that title on the phone's label
/// colour: near-black on a dark theme when the phone is in light mode.
/// The title colour is therefore set explicitly on every bar appearance,
/// and a fixed theme also overrides the window so the scene chrome matches.
enum EditorBarStyle {
    /// System follows the phone. A fixed theme forces its own light or dark.
    static func interfaceStyle(theme: EditorTheme, isDark: Bool) -> UIUserInterfaceStyle {
        theme == .system ? .unspecified : (isDark ? .dark : .light)
    }

    /// One appearance, shared by the bar and the navigation item, so the
    /// document title uses the theme's foreground wherever UIKit reads it.
    static func appearance(foreground: UIColor) -> UINavigationBarAppearance {
        let appearance = UINavigationBarAppearance()
        appearance.configureWithDefaultBackground()
        let title: [NSAttributedString.Key: Any] = [.foregroundColor: foreground]
        appearance.titleTextAttributes = title
        appearance.largeTitleTextAttributes = title
        return appearance
    }

    static func apply(navigationController: UINavigationController?,
                      item: UINavigationItem,
                      window: UIWindow?,
                      foreground: UIColor,
                      interfaceStyle: UIUserInterfaceStyle) {
        let appearance = appearance(foreground: foreground)
        if let bar = navigationController?.navigationBar {
            bar.standardAppearance = appearance
            bar.compactAppearance = appearance
            bar.scrollEdgeAppearance = appearance
            bar.compactScrollEdgeAppearance = appearance
            bar.tintColor = foreground
            bar.titleTextAttributes = [.foregroundColor: foreground]
            bar.overrideUserInterfaceStyle = interfaceStyle
        }
        item.standardAppearance = appearance
        item.compactAppearance = appearance
        item.scrollEdgeAppearance = appearance
        item.compactScrollEdgeAppearance = appearance
        if let nav = navigationController, nav.overrideUserInterfaceStyle != interfaceStyle {
            nav.overrideUserInterfaceStyle = interfaceStyle
            nav.setNeedsStatusBarAppearanceUpdate()
        }
        guard let window else { return }
        if window.overrideUserInterfaceStyle != interfaceStyle {
            window.overrideUserInterfaceStyle = interfaceStyle
        }
        window.traitOverrides.userInterfaceStyle = interfaceStyle
    }
}
