import UIKit
import UniformTypeIdentifiers
import CedricCore

/// One window: the Files-style document browser, which presents an editor
/// for the document picked. Every window (iPad scenes, Stage Manager) has
/// its own browser and editor.
final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let ws = scene as? UIWindowScene else { return }
        let browser = DocumentBrowserViewController()
        let w = UIWindow(windowScene: ws)
        w.rootViewController = browser
        w.makeKeyAndVisible()
        window = w
        ws.sizeRestrictions?.minimumSize = CGSize(width: 320, height: 400)
        #if DEBUG
        if let out = SelfCheck.outDir {
            SelfCheck.run(in: w, browser: browser, out: out)
            return
        }
        #endif
        if let ctx = options.urlContexts.first {
            browser.open(ctx.url, importIfNeeded: !ctx.options.openInPlace)
        } else if let url = TestLaunch.documentToOpen() {
            browser.presentDocument(at: url)
        }
    }

    func scene(_ scene: UIScene, openURLContexts contexts: Set<UIOpenURLContext>) {
        guard let ctx = contexts.first, let browser = window?.rootViewController as? DocumentBrowserViewController else { return }
        browser.open(ctx.url, importIfNeeded: !ctx.options.openInPlace)
    }
}

/// Launch arguments for the UI tests and screenshots:
/// `-OwlinkOpen <name>` opens Documents/<name>, copying the bundled sample
/// of that name there first if it isn't there yet (`-OwlinkFreshSample`
/// copies it again).
enum TestLaunch {
    static func documentToOpen() -> URL? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-OwlinkOpen"), i + 1 < args.count else { return nil }
        let name = args[i + 1]
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = docs.appendingPathComponent(name)
        let fresh = args.contains("-OwlinkFreshSample")
        if fresh || !FileManager.default.fileExists(atPath: url.path),
           let sample = Bundle.main.url(forResource: (name as NSString).deletingPathExtension,
                                        withExtension: (name as NSString).pathExtension, subdirectory: "Samples") {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.copyItem(at: sample, to: url)
        }
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}

final class DocumentBrowserViewController: UIDocumentBrowserViewController, UIDocumentBrowserViewControllerDelegate {
    init() {
        super.init(forOpening: TextDocument.browsableTypes)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        delegate = self
        allowsDocumentCreation = true
        allowsPickingMultipleItems = false
        shouldShowFileExtensions = true
        let settings = UIBarButtonItem(image: UIImage(systemName: "gear"), primaryAction: UIAction { [weak self] _ in
            let host = UIHostingSettings.make()
            self?.present(host, animated: true)
        })
        settings.accessibilityIdentifier = "browser.settings"
        additionalTrailingNavigationBarButtonItems = [settings]
    }

    // MARK: Delegate

    func documentBrowser(_ controller: UIDocumentBrowserViewController,
                         didRequestDocumentCreationWithHandler importHandler: @escaping (URL?, ImportMode) -> Void) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(String(localized: "Untitled") + ".txt")
        do {
            try Data().write(to: url)
            importHandler(url, .move)
        } catch {
            importHandler(nil, .none)
        }
    }

    func documentBrowser(_ controller: UIDocumentBrowserViewController, didPickDocumentsAt urls: [URL]) {
        if let url = urls.first { presentDocument(at: url) }
    }

    func documentBrowser(_ controller: UIDocumentBrowserViewController, didImportDocumentAt source: URL, toDestinationURL dest: URL) {
        presentDocument(at: dest)
    }

    func documentBrowser(_ controller: UIDocumentBrowserViewController, failedToImportDocumentAt url: URL, error: Error?) {
        alert(String(localized: "Couldn’t create the document"), error?.localizedDescription)
    }

    // MARK: Opening

    func open(_ url: URL, importIfNeeded: Bool) {
        if importIfNeeded {
            revealDocument(at: url, importIfNeeded: true) { [weak self] revealed, error in
                if let revealed { self?.presentDocument(at: revealed) } else { self?.alert(String(localized: "Couldn’t open the file"), error?.localizedDescription) }
            }
        } else {
            presentDocument(at: url)
        }
    }

    func presentDocument(at url: URL, binaryOK: Bool = false) {
        let doc = TextDocument(fileURL: url)
        doc.openBinaryAnyway = binaryOK
        doc.open { [weak self] ok in
            guard let self else { return }
            guard ok else {
                if !binaryOK, (try? Data(contentsOf: url, options: .mappedIfSafe)).map(TextCodec.looksBinary) == true {
                    let a = UIAlertController(title: String(localized: "This looks like a binary file"),
                                              message: String(localized: "Open it as text anyway? Saving it may damage it."), preferredStyle: .alert)
                    a.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
                    a.addAction(UIAlertAction(title: String(localized: "Open as Text"), style: .destructive) { _ in
                        self.presentDocument(at: url, binaryOK: true)
                    })
                    self.present(a, animated: true)
                } else {
                    self.alert(String(localized: "Couldn’t open \(url.lastPathComponent)"), nil)
                }
                return
            }
            let editor = EditorViewController(document: doc)
            let nav = UINavigationController(rootViewController: editor)
            nav.modalPresentationStyle = .fullScreen
            nav.navigationBar.prefersLargeTitles = false
            self.present(nav, animated: true)
        }
    }

    private func alert(_ title: String, _ message: String?) {
        let a = UIAlertController(title: title, message: message, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: String(localized: "OK"), style: .default))
        present(a, animated: true)
    }
}

import SwiftUI

enum UIHostingSettings {
    static func make() -> UIViewController {
        let host = UIHostingController(rootView: SettingsView())
        host.modalPresentationStyle = .formSheet
        return host
    }
}
