import CoreGraphics
import Testing
@testable import CedricCore

@Suite struct OwlChatPlacementTests {
    typealias P = OwlChatPlacement
    /// A 1440×900 screen's visible frame (menu bar and Dock taken off).
    let screen = CGRect(x: 0, y: 70, width: 1440, height: 805)
    let panel = CGSize(width: 400, height: 460)

    func frame(_ o: CGPoint) -> CGRect { CGRect(origin: o, size: panel) }

    @Test func besideHimOnTheSideWithMoreRoom() {
        // Bottom right of a centred window: more room to his left.
        let owl = CGRect(x: 1000, y: 200, width: 72, height: 72)
        let o = P.panelOrigin(owl: owl, panel: panel, screen: screen)
        #expect(o == CGPoint(x: owl.minX - P.gap - panel.width, y: owl.minY), "left of him, bottom level with his feet")
        #expect(!frame(o).intersects(owl))
        // Snapped to the left edge of a window on the left: to his right.
        let left = CGRect(x: 120, y: 200, width: 72, height: 72)
        #expect(P.panelOrigin(owl: left, panel: panel, screen: screen) == CGPoint(x: left.maxX + P.gap, y: left.minY))
    }

    @Test func highUpHisHeadIsLevelWithTheTop() {
        let owl = CGRect(x: 300, y: 760, width: 72, height: 72)
        let o = P.panelOrigin(owl: owl, panel: panel, screen: screen)
        #expect(o.x == owl.maxX + P.gap)
        #expect(o.y == owl.maxY - panel.height, "it hangs down from his head")
    }

    @Test func keptInsideTheVisibleFrame() {
        // Low on the screen: pushed up above the Dock, never under it.
        let owl = CGRect(x: 1000, y: 72, width: 72, height: 72)
        let o = P.panelOrigin(owl: owl, panel: panel, screen: screen)
        #expect(screen.insetBy(dx: P.margin, dy: P.margin).contains(frame(o)))
        #expect(o.y == screen.minY + P.margin)
        // Near the top-right corner.
        let top = CGRect(x: 1360, y: 800, width: 72, height: 72)
        let t = P.panelOrigin(owl: top, panel: panel, screen: screen)
        #expect(screen.insetBy(dx: P.margin, dy: P.margin).contains(frame(t)))
        #expect(t.x == top.minX - P.gap - panel.width, "the side with room")
    }

    @Test func aNarrowScreenGoesAboveOrBelow() {
        let narrow = CGRect(x: 0, y: 0, width: 600, height: 1000)
        let owl = CGRect(x: 264, y: 100, width: 72, height: 72)
        let o = P.panelOrigin(owl: owl, panel: panel, screen: narrow)
        #expect(o.y == owl.maxY + P.gap, "above him: more room there")
        #expect(o.x == owl.midX - panel.width / 2)
        let high = CGRect(x: 264, y: 880, width: 72, height: 72)
        #expect(P.panelOrigin(owl: high, panel: panel, screen: narrow).y == high.minY - P.gap - panel.height)
    }

    @Test func aPanelTallerThanTheScreenKeepsItsTitleBarOnScreen() {
        let small = CGRect(x: 0, y: 0, width: 1200, height: 300)
        let owl = CGRect(x: 600, y: 100, width: 72, height: 72)
        let o = P.panelOrigin(owl: owl, panel: panel, screen: small)
        #expect(o.y + panel.height == small.maxY - P.margin)
    }

    @Test func onASecondScreen() {
        // A screen to the left of the main one (negative x).
        let second = CGRect(x: -1920, y: 0, width: 1920, height: 1055)
        let owl = CGRect(x: -400, y: 300, width: 72, height: 72)
        let o = P.panelOrigin(owl: owl, panel: panel, screen: second)
        #expect(second.contains(frame(o)))
        #expect(o.x == owl.minX - P.gap - panel.width)
    }
}
