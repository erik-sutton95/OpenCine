import Foundation
import MonitorPresentation
import Testing

struct MonitorPlaybackPageGeometryTests {
    @Test func defaultBoundsKeepOriginalPictureGeometry() {
        var zoom = MonitorPlaybackZoom()
        zoom.pinchChanged(
            magnification: 2, startAnchorX: 0.5, startAnchorY: 0.5,
            size: CGSize(width: 200, height: 100))
        zoom.endGesture(size: CGSize(width: 200, height: 100))
        zoom.panChanged(translation: CGSize(width: 1000, height: -1000))
        zoom.endGesture(size: CGSize(width: 200, height: 100))
        #expect(zoom.offset == CGSize(width: 100, height: -50))
    }
    @Test func capturedCanvasAndPresentationScaleKeepDesqueezeBounds() {
        var zoom = MonitorPlaybackZoom()
        let canvas = CGSize(width: 400, height: 300)
        zoom.pinchChanged(magnification: 2, startAnchorX: 0.5, startAnchorY: 0.5, size: canvas)
        zoom.endGesture(
            size: canvas, horizontalPresentationScale: 1.5, verticalPresentationScale: 0.75)
        zoom.panChanged(translation: CGSize(width: 1000, height: -1000))
        zoom.endGesture(
            size: canvas, horizontalPresentationScale: 1.5, verticalPresentationScale: 0.75)
        #expect(zoom.offset == CGSize(width: 400, height: -75))
        zoom.panChanged(translation: CGSize(width: 25, height: 20))
        zoom.endGesture(size: canvas, horizontalPresentationScale: 1, verticalPresentationScale: 1)
        #expect(zoom.offset == CGSize(width: 200, height: -55))
    }
    @Test func reducedPresentationCannotInventPanExtentAndResetDropsCommittedOffset() {
        var zoom = MonitorPlaybackZoom()
        let canvas = CGSize(width: 400, height: 300)
        zoom.pinchChanged(magnification: 2, startAnchorX: 0.5, startAnchorY: 0.5, size: canvas)
        zoom.panChanged(translation: CGSize(width: 1000, height: -1000))
        zoom.endGesture(
            size: canvas, horizontalPresentationScale: 0.25, verticalPresentationScale: 0)
        #expect(zoom.offset == .zero)
        zoom.reset()
        zoom.panChanged(translation: CGSize(width: 30, height: 20))
        #expect(zoom.scale == 1 && zoom.offset == .zero)
    }
    @Test func continuousPanBoundsConsumeEachSampleOnceAndReverseFromTheClampedEdge() {
        let canvas = CGSize(width: 400, height: 300)
        var zoom = MonitorPlaybackZoom()
        zoom.pinchChanged(magnification: 2, startAnchorX: 0.5, startAnchorY: 0.5, size: canvas)
        zoom.endGesture(size: canvas)
        zoom.panChangedBounded(
            translation: CGSize(width: 1000, height: -1000), size: canvas,
            horizontalPresentationScale: 1.5, verticalPresentationScale: 0.75)
        #expect(zoom.offset == CGSize(width: 400, height: -75))
        zoom.panChangedBounded(
            translation: CGSize(width: 950, height: -950), size: canvas,
            horizontalPresentationScale: 1.5, verticalPresentationScale: 0.75)
        #expect(zoom.offset == CGSize(width: 350, height: -25))
        zoom.panChangedBounded(
            translation: CGSize(width: 800, height: -900), size: canvas,
            horizontalPresentationScale: 1.5, verticalPresentationScale: 0.75)
        #expect(zoom.offset == CGSize(width: 200, height: 25))
        zoom.panChangedBounded(
            translation: .zero, size: canvas,
            horizontalPresentationScale: 1.5, verticalPresentationScale: 0.75)
        #expect(zoom.offset == CGSize(width: -400, height: 75))
        zoom.endGesture(
            size: canvas, horizontalPresentationScale: 1.5, verticalPresentationScale: 0.75)
        zoom.panChangedBounded(
            translation: CGSize(width: 10, height: -5), size: canvas,
            horizontalPresentationScale: 1.5, verticalPresentationScale: 0.75)
        #expect(zoom.offset == CGSize(width: -390, height: 70))
        var legacy = MonitorPlaybackZoom()
        legacy.pinchChanged(magnification: 2, startAnchorX: 0.5, startAnchorY: 0.5, size: canvas)
        legacy.endGesture(size: canvas)
        legacy.panChanged(translation: CGSize(width: 1000, height: -1000))
        #expect(legacy.offset == CGSize(width: 1000, height: -1000))
    }
    @Test func continuousPinchBoundsDoNotCommitMagnificationBeforeReturnToTheGestureOrigin() {
        var zoom = MonitorPlaybackZoom()
        let picture = CGSize(width: 200, height: 100)
        let bounds = CGSize(width: 100, height: 50)
        zoom.pinchChangedBounded(
            magnification: 4, startAnchorX: 1, startAnchorY: 0.5,
            size: picture, boundsSize: bounds)
        #expect(zoom.scale == 4 && zoom.offset.width == -150)
        zoom.pinchChangedBounded(
            magnification: 2, startAnchorX: 1, startAnchorY: 0.5,
            size: picture, boundsSize: bounds)
        #expect(zoom.scale == 2 && zoom.offset.width == -25)
        zoom.pinchChangedBounded(
            magnification: 1, startAnchorX: 1, startAnchorY: 0.5,
            size: picture, boundsSize: bounds)
        #expect(zoom.scale == 1 && zoom.offset == .zero)
        zoom.endGesture(size: bounds)
        #expect(zoom == MonitorPlaybackZoom())
    }

}
