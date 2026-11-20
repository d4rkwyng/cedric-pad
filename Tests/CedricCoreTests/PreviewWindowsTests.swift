import Foundation
import Testing
@testable import CedricCore

/// The iPad's detached preview window (PreviewWindows): the activity and
/// session user info, which scene becomes what, which previews follow
/// which document, and what happens to them when the editor goes.
@Suite struct PreviewWindowsTests {
    let target = PreviewWindows.Target(documentPath: "/var/mobile/Docs/Notes.md", editorWindow: "editor-1", title: "Notes.md")

    @Test func userInfoRoundTrips() {
        let info = PreviewWindows.userInfo(for: target)
        #expect(PreviewWindows.target(activityType: PreviewWindows.activityType, userInfo: info) == target)
        #expect(PreviewWindows.target(userInfo: info) == target)
        // Plist types only, so a restored session keeps it.
        #expect(PropertyListSerialization.propertyList(info, isValidFor: .binary))
    }

    @Test func otherActivitiesAreNotPreviews() {
        let info = PreviewWindows.userInfo(for: target)
        #expect(PreviewWindows.target(activityType: PreviewWindows.newWindowActivityType, userInfo: info) == nil)
        #expect(PreviewWindows.target(activityType: nil, userInfo: info) == nil)
    }

    @Test func damagedUserInfoIsNotAPreview() {
        var info: [AnyHashable: Any] = PreviewWindows.userInfo(for: target)
        info["owlink.documentPath"] = ""
        #expect(PreviewWindows.target(userInfo: info) == nil)
        info["owlink.documentPath"] = 42
        #expect(PreviewWindows.target(userInfo: info) == nil)
        #expect(PreviewWindows.target(userInfo: ["owlink.role": "editor", "owlink.documentPath": "/a.md", "owlink.editorWindow": "w"]) == nil)
        #expect(PreviewWindows.target(userInfo: nil) == nil)
        #expect(PreviewWindows.target(userInfo: [:]) == nil)
    }

    @Test func missingTitleFallsBackToTheFileName() {
        var info = PreviewWindows.userInfo(for: target)
        info["owlink.title"] = nil
        #expect(PreviewWindows.target(userInfo: info)?.title == "Notes.md")
    }

    @Test func routeFromActivityOrRestoredSession() {
        let info = PreviewWindows.userInfo(for: target)
        // A new preview window: its activity.
        #expect(PreviewWindows.route(activities: [(PreviewWindows.activityType, info)], sessionUserInfo: nil) == .preview(target))
        // Restored after a relaunch: no activity, the session's user info.
        #expect(PreviewWindows.route(activities: [], sessionUserInfo: info) == .preview(target))
        // New Window, a file opened from Files, a plain launch: an editor window.
        #expect(PreviewWindows.route(activities: [(PreviewWindows.newWindowActivityType, nil)], sessionUserInfo: nil) == .editor)
        #expect(PreviewWindows.route(activities: [], sessionUserInfo: nil) == .editor)
        #expect(PreviewWindows.route(activities: [], sessionUserInfo: ["something": "else"]) == .editor)
    }

    @Test func detachOnlyWhereThereAreWindows() {
        #expect(PreviewWindows.detachAvailable(supportsMultipleScenes: true, isPhone: false))
        #expect(!PreviewWindows.detachAvailable(supportsMultipleScenes: true, isPhone: true))
        #expect(!PreviewWindows.detachAvailable(supportsMultipleScenes: false, isPhone: false))
        #expect(!PreviewWindows.detachAvailable(supportsMultipleScenes: false, isPhone: true))
    }

    @Test func liveWhileAnEditorHasItOpen() {
        var docs = OpenDocumentRegistry()
        #expect(PreviewWindows.state(for: target, documents: docs) == .blank)
        _ = docs.register(path: target.documentPath, window: "editor-1")
        #expect(PreviewWindows.state(for: target, documents: docs) == .live)
        // Reopened in another editor window: still followed.
        docs.removeAll(window: "editor-1")
        _ = docs.register(path: "/var/mobile/Docs/./Notes.md", window: "editor-2")
        #expect(PreviewWindows.state(for: target, documents: docs) == .live)
    }

    @Test func previewWindowsAreExemptFromOneWindowPerDocument() {
        var docs = OpenDocumentRegistry()
        var previews = PreviewWindowRegistry()
        #expect(docs.register(path: target.documentPath, window: "editor-1") == .registered)
        previews.register(previewWindow: "preview-1", target: target)
        // The preview never claims the document: the editor still owns it,
        // and opening it again elsewhere still finds the editor.
        #expect(docs.owner(ofPath: target.documentPath) == "editor-1")
        #expect(docs.register(path: target.documentPath, window: "editor-2") == .openElsewhere(window: "editor-1"))
        #expect(previews.hasPreviews(forPath: target.documentPath))
    }

    @Test func secondPreviewOfADocumentBringsTheFirstForward() {
        var previews = PreviewWindowRegistry()
        #expect(previews.existing(forPath: target.documentPath) == nil)
        previews.register(previewWindow: "p-b", target: target)
        previews.register(previewWindow: "p-a", target: target)
        // However the path is spelled.
        #expect(previews.existing(forPath: "/var/mobile/Docs/../Docs/Notes.md") == "p-a")
        #expect(previews.previewWindows(forPath: target.documentPath) == ["p-a", "p-b"])
        previews.unregister(previewWindow: "p-a")
        #expect(previews.existing(forPath: target.documentPath) == "p-b")
        #expect(previews.count == 1)
    }

    @Test func closingTheDocumentClosesItsPreviewsOnly() {
        var docs = OpenDocumentRegistry()
        var previews = PreviewWindowRegistry()
        let other = PreviewWindows.Target(documentPath: "/var/mobile/Docs/Other.md", editorWindow: "editor-1", title: "Other.md")
        previews.register(previewWindow: "p1", target: target)
        previews.register(previewWindow: "p2", target: other)
        _ = docs.register(path: other.documentPath, window: "editor-2")
        #expect(previews.actions(for: .documentClosed(path: target.documentPath), documents: docs) == ["p1": .close])
        // Still open in an editor (reopened meanwhile): its preview stays.
        #expect(previews.actions(for: .documentClosed(path: other.documentPath), documents: docs) == [:])
    }

    @Test func editorWindowGoneBlanksItsPreviews() {
        var docs = OpenDocumentRegistry()
        var previews = PreviewWindowRegistry()
        let other = PreviewWindows.Target(documentPath: "/var/mobile/Docs/Other.md", editorWindow: "editor-2", title: "Other.md")
        previews.register(previewWindow: "p1", target: target)
        previews.register(previewWindow: "p2", target: other)
        _ = docs.register(path: other.documentPath, window: "editor-2")
        #expect(previews.actions(for: .editorWindowGone(window: "editor-1"), documents: docs) == ["p1": .blank])
        #expect(previews.actions(for: .editorWindowGone(window: "editor-3"), documents: docs) == [:])
    }

    @Test func scrollFollowSkipsTinyMoves() {
        var f = PreviewScrollFollow(threshold: 0.01)
        #expect(f.next(0.5) == 0.5)
        #expect(f.next(0.505) == nil)
        #expect(f.next(0.52) == 0.52)
        // Clamped, and the ends always land.
        #expect(f.next(1.4) == 1)
        #expect(f.next(1) == nil)
        #expect(f.next(0.995) == nil)
        #expect(f.next(-3) == 0)
        #expect(f.next(.nan) == nil)
    }
}
