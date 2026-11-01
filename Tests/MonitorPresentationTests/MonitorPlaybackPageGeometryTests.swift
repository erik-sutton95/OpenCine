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

    // Owner request 2026-10-28: a zoomed clip fills the playback area instead of staying cropped
    // to its letterboxed 16:9 or 9:16 frame. Kotlin twin: MonitorPlaybackPageGeometryTest.
    @Test func zoomedPictureCoversTheCanvasPastItsLetterboxAndOneTimesKeepsTheFrame() {
        let portrait = CGSize(width: 400, height: 800)
        let wide = CGRect(x: 0, y: 287.5, width: 400, height: 225)
        #expect(MonitorPlaybackZoom().visiblePictureRect(feed: wide, canvas: portrait) == wide)
        var zoom = MonitorPlaybackZoom()
        zoom.pinchChanged(magnification: 2, startAnchorX: 0.5, startAnchorY: 0.5, size: portrait)
        #expect(zoom.visiblePictureRect(feed: wide, canvas: portrait)
            == CGRect(x: 0, y: 175, width: 400, height: 450))
        zoom.pinchChanged(magnification: 4, startAnchorX: 0.5, startAnchorY: 0.5, size: portrait)
        #expect(zoom.visiblePictureRect(feed: wide, canvas: portrait)
            == CGRect(origin: .zero, size: portrait))

        let landscape = CGSize(width: 800, height: 400)
        let tall = CGRect(x: 287.5, y: 0, width: 225, height: 400)
        #expect(MonitorPlaybackZoom().visiblePictureRect(feed: tall, canvas: landscape) == tall)
        var upright = MonitorPlaybackZoom()
        upright.pinchChanged(magnification: 2, startAnchorX: 0.5, startAnchorY: 0.5, size: landscape)
        #expect(upright.visiblePictureRect(feed: tall, canvas: landscape)
            == CGRect(x: 175, y: 0, width: 450, height: 400))
    }

    @Test func zoomedPanStopsWhereThePictureMeetsTheCanvasEdgeNotTheLetterbox() {
        // 16:9 in portrait: at 2x the picture is narrower than the canvas is tall, so it stays
        // centred vertically; at 4x it overhangs the canvas by 50 points top and bottom.
        let portrait = CGSize(width: 400, height: 800), wide = CGSize(width: 400, height: 225)
        var zoom = MonitorPlaybackZoom()
        zoom.pinchChanged(magnification: 2, startAnchorX: 0.5, startAnchorY: 0.5, size: portrait)
        zoom.panChanged(translation: CGSize(width: 1000, height: -1000))
        zoom.endGesture(size: portrait, picture: wide)
        #expect(zoom.offset == CGSize(width: 200, height: 0))
        zoom.pinchChanged(magnification: 2, startAnchorX: 0.5, startAnchorY: 0.5, size: portrait)
        zoom.panChanged(translation: CGSize(width: -3000, height: 3000))
        zoom.endGesture(size: portrait, picture: wide)
        #expect(zoom.scale == 4 && zoom.offset == CGSize(width: -600, height: 50))

        // 16:9 pillarboxed in landscape: the edge stops at the canvas (300), not at the
        // letterboxed frame (400), and the continuous path holds the same limit.
        let landscape = CGSize(width: 1000, height: 450), frame = CGSize(width: 800, height: 450)
        var held = MonitorPlaybackZoom()
        held.pinchChangedBounded(magnification: 2, startAnchorX: 0.5, startAnchorY: 0.5,
            size: landscape, boundsSize: landscape, picture: frame)
        held.panChangedBounded(translation: CGSize(width: -2000, height: 2000), size: landscape,
            picture: frame)
        #expect(held.offset == CGSize(width: -300, height: 225))
        held.endPan(size: landscape, picture: frame)
        held.endPinch(size: landscape, picture: frame)
        #expect(held.scale == 2 && held.offset == CGSize(width: -300, height: 225))
    }

    // Owner hardware pass 2026-10-31: a vertical photo zoomed on the iPad stayed clipped to its
    // 9:16 frame. A still's pinch and pan are projected over the whole canvas and bounded by the
    // still's own frame, so it fills the screen like a clip. Kotlin twin: MonitorPlaybackPageGeometryTest.
    @Test func zoomedStillCoversTheCanvasAndPansToItsEdgeNotItsFrame() {
        let landscape = CGSize(width: 1194, height: 834)
        let tall = CGRect(x: 362.4375, y: 0, width: 469.125, height: 834)
        let pinched = MonitorPlaybackZoom().preview(magnification: 4,
            anchor: CGPoint(x: landscape.width / 2, y: landscape.height / 2), translation: .zero,
            size: landscape, picture: tall.size)
        #expect(pinched.scale == 4)
        #expect(pinched.visiblePictureRect(feed: tall, canvas: landscape)
            == CGRect(origin: .zero, size: landscape))

        // Pan far right: the still's left edge comes to the canvas's left edge and stops there.
        var committed = pinched
        committed.endPinch(size: landscape, picture: tall.size)
        var panned = committed.preview(magnification: 1, anchor: nil,
            translation: CGSize(width: 5000, height: 0), size: landscape, picture: tall.size)
        panned.endPan(size: landscape, picture: tall.size)
        let maximum = (tall.width * 4 - landscape.width) / 2
        #expect(panned.offset == CGSize(width: maximum, height: 0))
        #expect(panned.visiblePictureRect(feed: tall, canvas: landscape)
            == CGRect(origin: .zero, size: landscape))

        // At 1x nothing moves and the still keeps its frame.
        let still = MonitorPlaybackZoom().preview(magnification: 1, anchor: nil,
            translation: CGSize(width: 300, height: 300), size: landscape, picture: tall.size)
        #expect(still == MonitorPlaybackZoom())
        #expect(still.visiblePictureRect(feed: tall, canvas: landscape) == tall)
    }

    @Test func zoomedStillNarrowerThanTheCanvasStaysCentredOnThatAxis() {
        let landscape = CGSize(width: 1000, height: 400)
        let tall = CGSize(width: 225, height: 400)
        var zoom = MonitorPlaybackZoom().preview(magnification: 2,
            anchor: CGPoint(x: 900, y: 200), translation: .zero, size: landscape, picture: tall)
        zoom.endPinch(size: landscape, picture: tall)
        // 450 wide in a 1000 wide canvas: no horizontal travel; 800 tall in 400: 200 each way.
        #expect(zoom.offset.width == 0)
        zoom = zoom.preview(magnification: 1, anchor: nil, translation: CGSize(width: 0, height: -900),
            size: landscape, picture: tall)
        #expect(zoom.offset == CGSize(width: 0, height: -200))
    }
}
