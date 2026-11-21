import MonitorPresentation
import Testing

struct LiveStreamOverlayPlacementTests {
    @Test func anchorsUnderStatusTrailing() {
        let point = LiveStreamOverlayPlacement.anchor(
            status: MonitorRect(x: 0, y: 47, width: 393, height: 44),
            viewportWidth: 393, safeTop: 47, safeTrailing: 0)
        #expect(point == LiveStreamOverlayPlacement.Point(x: 385, y: 97))
    }

    @Test func staysInsideTheTrailingSafeArea() {
        let point = LiveStreamOverlayPlacement.anchor(
            status: MonitorRect(x: 59, y: 0, width: 793, height: 44),
            viewportWidth: 852, safeTop: 0, safeTrailing: 59)
        #expect(point == LiveStreamOverlayPlacement.Point(x: 785, y: 50))
    }

    @Test func statusOffStillTopTrailing() {
        let point = LiveStreamOverlayPlacement.anchor(
            status: MonitorRect(), viewportWidth: 852, safeTop: 0, safeTrailing: 59)
        #expect(point == LiveStreamOverlayPlacement.Point(x: 785, y: 16))
    }
}
