import AppKit
import CedricCore

// Git, lightweight (Git.swift in CedricCore has the logic): the branch in
// the status bar, change bars in the gutter against HEAD, GitHub links and
// Compare with Last Commit. Nothing runs at launch: a tab looks for its
// repository only after the first frame, once it is shown and typing has
// paused, and git runs on one background queue. Never in large mode, never
// for untitled tabs, no network.

extension Notification.Name {
    /// A repository's HEAD or index changed (GitRepo's watcher).
    static let cedricGitRepoChanged = Notification.Name("CedricGitRepoChanged")
}

/// One background queue for every git process and diff.
let gitQueue = DispatchQueue(label: "cedric.git", qos: .utility)

/// A repository shared by the tabs open in it: watches its git directory
/// (HEAD and index are replaced by rename, so the folder's own write event
/// sees them) and tells the tabs, debounced.
@MainActor
final class GitRepo {
    let location: GitLocation
    var remote: GitHubRemote?
    fileprivate var users = 0
    private var source: DispatchSourceFileSystemObject?
    private var debounce: DispatchWorkItem?

    init(location: GitLocation) {
        self.location = location
        let fd = open(location.gitDir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete, .attrib], queue: .main)
        s.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.changed() } }
        s.setCancelHandler { close(fd) }
        s.resume()
        source = s
    }

    private func changed() {
        debounce?.cancel()
        let w = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                NotificationCenter.default.post(name: .cedricGitRepoChanged, object: self)
            }
        }
        debounce = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: w)
    }

    func stop() {
        debounce?.cancel()
        source?.cancel()
        source = nil
    }
}

@MainActor
enum GitRepos {
    private static var repos: [String: GitRepo] = [:]

    static func retain(_ loc: GitLocation) -> GitRepo {
        let key = loc.gitDir.path
        let r = repos[key] ?? GitRepo(location: loc)
        repos[key] = r
        r.users += 1
        return r
    }

    static func release(_ r: GitRepo) {
        r.users -= 1
        if r.users <= 0 {
            r.stop()
            repos.removeValue(forKey: r.location.gitDir.path)
        }
    }
}

/// What the background refresh found for a file.
struct GitRefreshResult: Sendable {
    var location: GitLocation
    var status: GitFileStatus
    var relativePath: String?
    var remote: GitHubRemote?
    /// HEAD's text for the file (nil: not in HEAD, or unchanged since `baseSHA`).
    var base: String?
    var baseFetched: Bool
}

/// One tab's git state.
@MainActor
final class GitTabState {
    private weak var tab: EditorWindowController?
    private(set) var repo: GitRepo?
    private(set) var status: GitFileStatus?
    /// The file's path from the work tree's root, as GitHub names it.
    private(set) var relativePath: String?
    /// HEAD's text for the file; nil when it isn't in HEAD.
    private(set) var baseText: String?
    private var baseSHA: String?
    private(set) var changes = GitLineChanges()
    private var fileURL: URL?
    private var started = false
    private var refreshing = false
    private var refreshAgain = false
    private var refreshTimer: Timer?
    private var diffTimer: Timer?
    private var lastEdit = Date.distantPast
    /// Edits since the last diff snapshot (a stale result is dropped).
    private var edits = 0
    private var observer: NSObjectProtocol?
    /// Every refresh that finished (checks wait on it).
    private(set) var refreshCount = 0
    private(set) var diffCount = 0
    /// The last refresh found no repository (or no usable git).
    private(set) var notInGit = false

    init(tab: EditorWindowController) { self.tab = tab }

    var showsGutter: Bool { Settings.shared.showGitChanges }

    /// After the first frame, once the tab is on screen and idle.
    func tabShown() {
        guard !started else { return }
        AfterFirstFrame.run { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.startIfIdle() }
        }
    }

    private func startIfIdle() {
        guard !started, let tab, tab.window?.isVisible == true || ProcessInfo.processInfo.environment["CEDRIC_CHECK"] != nil else { return }
        if Date().timeIntervalSince(lastEdit) < 0.5 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.startIfIdle() }
            return
        }
        started = true
        refresh()
    }

    /// Saved, focused, reloaded, or HEAD/index changed: look again (debounced).
    func scheduleRefresh(after delay: TimeInterval = 0.15) {
        guard started else { return }
        refreshTimer?.invalidate()
        let t = Timer(timeInterval: delay, repeats: false) { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }
        RunLoop.main.add(t, forMode: .common)
        refreshTimer = t
    }

    private func clear() {
        status = nil
        baseText = nil
        baseSHA = nil
        relativePath = nil
        changes = GitLineChanges()
        if let repo { GitRepos.release(repo) }
        repo = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        tab?.gitStateChanged()
    }

    func refresh() {
        guard started, let tab else { return }
        guard let url = tab.doc.fileURL, !tab.isLargeDocument else { clear(); return }
        if refreshing { refreshAgain = true; return }
        if url != fileURL {
            if fileURL != nil { clear() }
            fileURL = url
        }
        refreshing = true
        let knownLoc = repo?.location
        let needPath = relativePath == nil
        let haveSHA = baseText != nil ? baseSHA : nil
        let encoding = tab.doc.encoding
        gitQueue.async { [weak self] in
            let result = Self.work(url: url, knownLocation: knownLoc, needPath: needPath, baseSHA: haveSHA, encoding: encoding)
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.apply(result, url: url) }
            }
        }
    }

    nonisolated private static func work(url: URL, knownLocation: GitLocation?, needPath: Bool, baseSHA: String?,
                                         encoding: TextEncoding) -> GitRefreshResult? {
        guard let loc = knownLocation ?? GitLocation.find(for: url) else { return nil }
        let dir = url.deletingLastPathComponent(), name = url.lastPathComponent
        guard let st = GitRunner.run(["status", "--porcelain=v2", "--branch", "-z", "--untracked-files=all", "--", name], cwd: dir),
              st.status == 0 else { return nil }
        let status = GitFileStatus.parse(porcelainV2: st.text)
        var result = GitRefreshResult(location: loc, status: status, baseFetched: false)
        if needPath, let p = GitRunner.run(["rev-parse", "--show-prefix"], cwd: dir), p.status == 0 {
            result.relativePath = p.text.trimmingCharacters(in: .newlines) + name
        }
        if let r = GitRunner.run(["config", "--get", "remote.origin.url"], cwd: dir), r.status == 0 {
            result.remote = GitHubRemote.parse(r.text)
        }
        if let sha = status.headSHA, sha != baseSHA {
            result.baseFetched = true
            if !status.untracked, let show = GitRunner.run(["show", "\(sha):./\(name)"], cwd: dir) {
                if show.status == 0 {
                    result.base = (TextCodec.decode(show.output, as: encoding) ?? TextCodec.decode(show.output))?.text
                } else {
                    // In the index but not in HEAD: every line is new.
                    result.base = ""
                }
            }
        } else if status.headSHA == nil {
            result.baseFetched = true
            result.base = status.untracked ? nil : ""
        }
        if status.untracked { result.base = nil; result.baseFetched = true }
        return result
    }

    private func apply(_ result: GitRefreshResult?, url: URL) {
        refreshing = false
        refreshCount += 1
        defer {
            if refreshAgain { refreshAgain = false; refresh() }
        }
        guard let tab, url == tab.doc.fileURL else { return }
        notInGit = result == nil
        guard let result else { clear(); return }
        if repo?.location != result.location {
            if let repo { GitRepos.release(repo) }
            let r = GitRepos.retain(result.location)
            repo = r
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = NotificationCenter.default.addObserver(forName: .cedricGitRepoChanged, object: r, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleRefresh() }
            }
        }
        repo?.remote = result.remote
        status = result.status
        if let p = result.relativePath { relativePath = p }
        if result.baseFetched {
            baseText = result.base
            baseSHA = result.status.headSHA
        }
        tab.gitStateChanged()
        diffNow()
    }

    // MARK: Gutter

    /// An edit in the buffer: move the marks below it now, diff when typing pauses.
    func edited(firstLine: Int, lineDelta: Int) {
        lastEdit = Date()
        edits += 1
        guard started else { return }
        if tab?.isLargeDocument == true { clear(); return }
        guard baseText != nil else { return }
        if lineDelta != 0 {
            changes.shift(fromLine: firstLine, by: lineDelta)
        }
        diffTimer?.invalidate()
        let t = Timer(timeInterval: 0.4, repeats: false) { [weak self] _ in MainActor.assumeIsolated { self?.diffNow() } }
        RunLoop.main.add(t, forMode: .common)
        diffTimer = t
    }

    /// Diffs the buffer against HEAD's text off the main thread.
    func diffNow() {
        diffTimer?.invalidate()
        guard let tab, let base = baseText, showsGutter, !tab.isLargeDocument, let storage = tab.textView.textStorage else {
            if !changes.isEmpty { changes = GitLineChanges(); tab?.gitStateChanged() }
            return
        }
        // An immutable copy: the storage keeps changing on the main thread.
        let current = String((storage.string as NSString).copy() as! NSString)
        let seen = edits
        gitQueue.async { [weak self] in
            let c = GitLineChanges.compute(base: base, current: current)
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.edits == seen else { return }
                    self.diffCount += 1
                    if c != self.changes {
                        self.changes = c
                        self.tab?.gitStateChanged()
                    } else {
                        self.tab?.updateGitLabel()
                    }
                }
            }
        }
    }

    func settingChanged() {
        if showsGutter { diffNow() } else if !changes.isEmpty { changes = GitLineChanges(); tab?.gitStateChanged() }
    }

    func stop() {
        refreshTimer?.invalidate()
        diffTimer?.invalidate()
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        if let repo { GitRepos.release(repo) }
        repo = nil
        started = false
    }

    // MARK: Links

    /// The file has uncommitted changes (on disk or in the buffer).
    var isDirty: Bool { (status?.changed ?? false) || !changes.isEmpty }

    var remote: GitHubRemote? { repo?.remote }

    /// The ref a GitHub link uses: the branch when it has an upstream (so
    /// it is likely pushed), else HEAD's commit.
    var linkRef: String? {
        guard let status, let sha = status.headSHA else { return nil }
        if let b = status.branch, status.upstream != nil { return b }
        return sha
    }

    func gitHubLink(lines: ClosedRange<Int>?) -> String? {
        guard let remote, let ref = linkRef, let path = relativePath, baseText != nil else { return nil }
        return remote.blobURL(ref: ref, path: path, lines: lines)
    }

    /// HEAD's text now, fetching it if the tab hasn't yet.
    func withBase(_ done: @escaping @MainActor (String?) -> Void) {
        if started, let baseText { done(baseText); return }
        guard let url = tab?.doc.fileURL, let enc = tab?.doc.encoding else { done(nil); return }
        gitQueue.async {
            let r = Self.work(url: url, knownLocation: nil, needPath: false, baseSHA: nil, encoding: enc)
            let base = r?.base
            DispatchQueue.main.async { MainActor.assumeIsolated { done(base) } }
        }
    }
}

// MARK: - Tab

extension EditorWindowController {
    /// The branch label, dirty dot and gutter after a git refresh or diff.
    func gitStateChanged() {
        gutter.needsDisplay = true
        updateGitLabel()
    }

    func updateGitLabel() {
        let b = statusBar.gitButton
        guard let git = gitState, let label = git.status?.label else {
            if !b.isHidden { b.isHidden = true }
            return
        }
        let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let s = NSMutableAttributedString(string: label, attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor])
        if git.isDirty {
            s.append(NSAttributedString(string: " ●", attributes: [.font: NSFont.systemFont(ofSize: 8),
                                                                   .foregroundColor: NSColor.controlAccentColor,
                                                                   .baselineOffset: 1]))
        }
        b.attributedTitle = s
        b.toolTip = git.status?.branch == nil ? String(localized: "Detached HEAD") : String(localized: "Git branch")
        b.setAccessibilityLabel(label + (git.isDirty ? String(localized: ", uncommitted changes") : ""))
        b.isHidden = false
    }

    /// The selected lines (1-based) for a GitHub link: the caret's line
    /// with no selection; a selection ending at a line start leaves that
    /// line out.
    var gitLinkLines: ClosedRange<Int> {
        let sel = textView.selectedRange()
        let first = lineIndex.line(containing: sel.location)
        var last = lineIndex.line(containing: NSMaxRange(sel))
        if sel.length > 0, last > first, lineIndex.starts[last] == NSMaxRange(sel) { last -= 1 }
        return (first + 1)...(last + 1)
    }

    @objc func showGitMenu(_ sender: NSButton) {
        let menu = NSMenu()
        func add(_ title: String, _ action: Selector, enabled: Bool = true) {
            let i = NSMenuItem(title: title, action: enabled ? action : nil, keyEquivalent: "")
            i.target = self
            menu.addItem(i)
        }
        add(String(localized: "Copy Branch Name"), #selector(copyBranchName(_:)))
        add(String(localized: "Open Repository in Finder"), #selector(openRepositoryInFinder(_:)))
        if gitState?.remote != nil {
            add(String(localized: "Open on GitHub"), #selector(openOnGitHub(_:)), enabled: gitState?.gitHubLink(lines: nil) != nil)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 2), in: sender)
    }

    @objc func copyBranchName(_ sender: Any?) {
        guard let label = gitState?.status?.label else { NSSound.beep(); return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(label, forType: .string)
    }

    @objc func openRepositoryInFinder(_ sender: Any?) {
        guard let root = gitState?.repo?.location.workTree else { NSSound.beep(); return }
        NSWorkspace.shared.open(root)
    }

    @objc func openOnGitHub(_ sender: Any?) {
        guard let s = gitState?.gitHubLink(lines: gitLinkLines), let u = URL(string: s) else { NSSound.beep(); return }
        NSWorkspace.shared.open(u)
    }

    @objc func copyGitHubLink(_ sender: Any?) {
        guard let s = gitState?.gitHubLink(lines: gitLinkLines) else { NSSound.beep(); return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    @objc func compareWithLastCommit(_ sender: Any?) {
        guard let git = gitState, doc.fileURL != nil else { NSSound.beep(); return }
        git.withBase { [weak self] base in
            guard let self, let base else { NSSound.beep(); return }
            (NSApp.delegate as? AppDelegate)?.showCompare(leftName: "\(self.doc.displayName) (HEAD)", leftText: base,
                                                          rightName: self.doc.displayName, rightText: self.text, host: self)
        }
    }
}

// MARK: - App menus

extension AppDelegate {
    @objc func openOnGitHubMenu(_ sender: Any?) { currentTab?.openOnGitHub(sender) }
    @objc func copyGitHubLinkMenu(_ sender: Any?) { currentTab?.copyGitHubLink(sender) }
    @objc func compareWithLastCommitMenu(_ sender: Any?) { currentTab?.compareWithLastCommit(sender) }

    func showCompare(leftName: String, leftText: String, rightName: String, rightText: String, host tab: EditorWindowController) {
        let c = CompareWindowController(leftName: leftName, leftText: leftText, rightName: rightName, rightText: rightText, palette: tab.palette)
        compareWindows.append(c)
        c.onClose = { [weak self] c in self?.compareWindows.removeAll { $0 === c } }
        if let w = c.window {
            if let host = tab.window, host.isVisible { host.addTabbedWindow(w, ordered: .above) } else { w.center() }
            w.makeKeyAndOrderFront(nil)
        }
    }

    func validateGitItem(_ item: NSMenuItem) -> Bool? {
        let git = currentTab?.gitState
        switch item.action {
        case #selector(openOnGitHubMenu(_:)), #selector(copyGitHubLinkMenu(_:)):
            return git?.gitHubLink(lines: nil) != nil
        case #selector(compareWithLastCommitMenu(_:)):
            // Before the tab's first look, git may still find it: let it try.
            guard let tab = currentTab, tab.doc.fileURL != nil, !tab.isLargeDocument else { return false }
            guard let git else { return true }
            return !git.notInGit && (git.status == nil || git.baseText != nil)
        default: return nil
        }
    }
}

extension EditorWindowController {
    /// The tab is (or will soon be) on screen: look for its repository
    /// once it is idle. Untitled tabs have none.
    func gitTabShown() {
        guard doc.fileURL != nil else { return }
        if gitState == nil { gitState = GitTabState(tab: self) }
        gitState?.tabShown()
    }

    /// Saved (perhaps to a new place, perhaps for the first time).
    func gitSaved() {
        if gitState == nil { gitTabShown() } else { gitState?.scheduleRefresh() }
    }
}
