import Foundation
import MonitorPresentation
import OpenCineMedia
import Testing

struct MonitorPlaybackInteractionTests {
    @Test func cumulativePreviewDoesNotChangeItsOriginOrApplyPanTwice() {
        let origin = MonitorPlaybackZoom(maximumScale: 8), size = CGSize(width: 400, height: 200)
        let first = origin.preview(magnification: 2, anchor: CGPoint(x: 300, y: 100),
            translation: CGSize(width: 60, height: 0), size: size)
        let repeated = origin.preview(magnification: 2, anchor: CGPoint(x: 300, y: 100),
            translation: CGSize(width: 60, height: 0), size: size)
        #expect(first == repeated && origin.scale == 1 && origin.offset == .zero)
        #expect(first.scale == 2 && first.offset == CGSize(width: -40, height: 0))
    }
    @Test func simultaneousPanIsAddedBeforeTheFinalPictureBounds() {
        let origin = MonitorPlaybackZoom(maximumScale: 8)
        let value = origin.preview(magnification: 2, anchor: CGPoint(x: -200, y: 100),
            translation: CGSize(width: -300, height: 0), size: CGSize(width: 400, height: 200))
        #expect(value.offset.width == 100)
    }
    @Test func inverseFocusUsesTheSamePreRotationPictureTransform() {
        let size = CGSize(width: 400, height: 200)
        let value = MonitorPlaybackZoom(maximumScale: 8).preview(magnification: 2,
            anchor: CGPoint(x: 300, y: 100), translation: CGSize(width: 60, height: -20), size: size)
        let cameraPoint = CGPoint(x: 150, y: 75)
        let rendered = CGPoint(x: size.width / 2 + (cameraPoint.x - size.width / 2) * value.scale + value.offset.width,
            y: size.height / 2 + (cameraPoint.y - size.height / 2) * value.scale + value.offset.height)
        #expect(value.sourcePoint(rendered, size: size) == cameraPoint)
        #expect(MonitorPlaybackZoom().sourcePoint(CGPoint(x: -10, y: 50), size: size) == CGPoint(x: -10, y: 50))
    }
    @Test func incrementalTransformsRespectActualLetterboxedPictureBounds() {
        let value = MonitorPlaybackZoom(maximumScale: 8).transformed(zoomChange: 2,
            centroid: CGPoint(x: 200, y: 200), panChange: CGSize(width: 1000, height: 1000),
            frame: CGSize(width: 400, height: 400), picture: CGSize(width: 400, height: 200))
        #expect(value.scale == 2 && value.offset == CGSize(width: 200, height: 0))
        #expect(value.maximumScale == 8)
    }
    @Test func settlingResetsNearOneButRetainsACommittedPictureOffset() {
        let origin = MonitorPlaybackZoom(maximumScale: 8)
        let near = origin.transformed(zoomChange: 1.04, centroid: CGPoint(x: 200, y: 100),
            panChange: .zero, frame: CGSize(width: 400, height: 200)).settled()
        #expect(near.scale == 1 && near.maximumScale == 8)
        let held = origin.transformed(zoomChange: 1.5, centroid: CGPoint(x: 200, y: 100),
            panChange: CGSize(width: 12, height: 0), frame: CGSize(width: 400, height: 200))
        #expect(held.settled() == held)
    }
    @Test func endingPinchDoesNotReplayAnActivePansCumulativeTranslation() {
        var zoom = MonitorPlaybackZoom()
        let size = CGSize(width: 400, height: 200)
        zoom.pinchChanged(magnification: 2, startAnchorX: 0.5, startAnchorY: 0.5, size: size)
        zoom.panChangedBounded(translation: CGSize(width: 40, height: 0), size: size)
        zoom.endPinch(size: size)
        zoom.panChangedBounded(translation: CGSize(width: 45, height: 0), size: size)
        #expect(zoom.offset.width == 45)
        zoom.endPan(size: size)
        zoom.panChanged(translation: CGSize(width: 5, height: 0))
        #expect(zoom.offset.width == 50)
    }
    @Test func endingPanRetainsTheActivePinchsStartingScale() {
        var zoom = MonitorPlaybackZoom(maximumScale: 8)
        let size = CGSize(width: 400, height: 200)
        zoom.pinchChanged(magnification: 2, startAnchorX: 0.5, startAnchorY: 0.5, size: size)
        zoom.panChanged(translation: CGSize(width: 20, height: 0))
        zoom.endPan(size: size)
        zoom.pinchChanged(magnification: 3, startAnchorX: 0.5, startAnchorY: 0.5, size: size)
        #expect(zoom.scale == 3)
        #expect(zoom.offset.width == 30)
        zoom.endPinch(size: size)
        zoom.pinchChanged(magnification: 4, startAnchorX: 0.5, startAnchorY: 0.5, size: size)
        #expect(zoom.scale == 8)
        zoom.reset()
        #expect(zoom.maximumScale == 8)
    }
    @Test func contextChangeRetiresBothOriginsWithoutChangingTheScaleLimit() {
        var zoom = MonitorPlaybackZoom(maximumScale: 8)
        let size = CGSize(width: 400, height: 200)
        zoom.pinchChanged(magnification: 2, startAnchorX: 0.5, startAnchorY: 0.5, size: size)
        zoom.panChanged(translation: CGSize(width: 30, height: 0))
        zoom.endGesture(size: size)
        zoom.pinchChanged(magnification: 2, startAnchorX: 0.5, startAnchorY: 0.5, size: size)
        zoom.panChanged(translation: CGSize(width: 5, height: 0))
        #expect(zoom.scale == 4)
        #expect(zoom.offset.width == 65)
    }
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
