import Foundation
import MonitorPresentation
import OpenCineMedia
import Testing

struct MonitorPlaybackInteractionTests {
    @Test func offCenterPinchKeepsSourceUnderFingerThenBoundsPanAndResets() {
        var zoom = MonitorPlaybackZoom()
        let size = CGSize(width: 200, height: 100)
        zoom.pinchChanged(magnification: 2, startAnchorX: 0.75, startAnchorY: 0.5, size: size)
        #expect(zoom.scale == 2)
        #expect(50 * zoom.scale + zoom.offset.width == 50)
        zoom.endGesture(size: size)
        zoom.panChanged(translation: CGSize(width: 1000, height: -1000))
        zoom.endGesture(size: size)
        #expect(zoom.offset == CGSize(width: 100, height: -50))
        zoom.pinchChanged(magnification: 0.52, startAnchorX: 0.5, startAnchorY: 0.5, size: size)
        zoom.endGesture(size: size)
        #expect(zoom.scale == 1 && zoom.offset == .zero)
    }
    @Test func verticalChromeSwipeKeepsDeadZoneAndRejectsDiagonalTravel() {
        #expect(MonitorPlaybackChromeSwipe.classify(dx: 0, dy: 44) == .none)
        #expect(MonitorPlaybackChromeSwipe.classify(dx: 0, dy: 45) == .hide)
        #expect(MonitorPlaybackChromeSwipe.classify(dx: 0, dy: -45) == .show)
        #expect(MonitorPlaybackChromeSwipe.classify(dx: 40, dy: 48) == .none)
        #expect(MonitorPlaybackChromeSwipe.classify(dx: 40, dy: 49) == .hide)
    }
    @Test func canceledSameItemEditCannotTakeItsSuccessorOrAdmitAnotherItem() {
        let item = MonitorPlaybackItemToken(owner: UUID(), revision: 1)
        let other = MonitorPlaybackItemToken(owner: item.owner, revision: 2)
        let a = MonitorPlaybackScrubToken(item: item)
        let b = MonitorPlaybackScrubToken(item: item)
        var editing = MonitorPlaybackEditing()
        let admittedA = editing.admit(a, item: item)
        #expect(admittedA)
        let canceledA = editing.take(a)
        #expect(canceledA == a)
        let admittedB = editing.admit(b, item: item)
        #expect(admittedB)
        let lateA = editing.take(a)
        #expect(lateA == nil, "Retired cancel A cannot cancel newly admitted B on the same item")
        #expect(editing.token == b)
        let canceledB = editing.take(b)
        #expect(canceledB == b)
        let wrongItem = editing.admit(a, item: other)
        #expect(!wrongItem, "A delayed begin cannot bind to a replaced native item")
    }
}
