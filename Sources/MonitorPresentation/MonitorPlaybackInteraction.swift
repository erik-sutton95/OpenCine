import Foundation
import OpenCineMedia

/// Source presentation geometry consumed by the common canvas gesture owner.
public struct MonitorPlaybackInteractionOptions: Equatable, Sendable {
    public var doubleTapResetsZoom: Bool
    public var continuousPanBounds: Bool
    public var zoomAgainstCanvas: Bool
    public var horizontalPresentationScale: CGFloat
    public var verticalPresentationScale: CGFloat
    public init(doubleTapResetsZoom: Bool = false, continuousPanBounds: Bool = false,
        zoomAgainstCanvas: Bool = false, horizontalPresentationScale: CGFloat = 1,
        verticalPresentationScale: CGFloat = 1) {
        self.doubleTapResetsZoom = doubleTapResetsZoom
        self.continuousPanBounds = continuousPanBounds
        self.zoomAgainstCanvas = zoomAgainstCanvas
        self.horizontalPresentationScale = horizontalPresentationScale
        self.verticalPresentationScale = verticalPresentationScale
    }
}

/// Transient picture geometry. It has no native player or transport state.
public struct MonitorPlaybackZoom: Equatable, Sendable {
    public static let maxScale: CGFloat = 4
    public let maximumScale: CGFloat
    public private(set) var scale: CGFloat = 1
    public private(set) var offset: CGSize = .zero
    private var pinchStartScale: CGFloat?
    private var lastPanTranslation: CGSize = .zero
    public init(maximumScale: CGFloat = Self.maxScale) {
        self.maximumScale = maximumScale.isFinite ? max(1, maximumScale) : Self.maxScale
    }
    public var isZoomed: Bool { scale > 1.001 }

    /// A cumulative native gesture is projected from its committed origin without mutating it.
    public func preview(magnification: CGFloat, anchor: CGPoint?, translation: CGSize, size: CGSize) -> Self {
        var value = self
        if let anchor, size.width > 0, size.height > 0 {
            value.pinchChanged(magnification: magnification,
                startAnchorX: anchor.x / size.width, startAnchorY: anchor.y / size.height,
                size: size)
        }
        value.panChangedBounded(translation: translation, size: size)
        return value
    }

    /// Inverts the same center-anchored picture transform for camera-coordinate focus.
    public func sourcePoint(_ point: CGPoint, size: CGSize) -> CGPoint {
        guard scale > 1.0001 else { return point }
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        return CGPoint(x: center.x + (point.x - center.x - offset.width) / scale,
            y: center.y + (point.y - center.y - offset.height) / scale)
    }
    /// Platforms that report incremental centroid/scale/pan events use the same bounded transform.
    public func transformed(zoomChange: CGFloat, centroid: CGPoint, panChange: CGSize,
        frame: CGSize, picture: CGSize? = nil) -> Self {
        var value = self
        let target = min(maximumScale, max(1, scale * zoomChange))
        guard target > 1 else { value.reset(); return value }
        let ratio = scale > 0 ? target / scale : 1
        let x = centroid.x - frame.width / 2, y = centroid.y - frame.height / 2
        value.scale = target
        value.offset = Self.boundPan(CGSize(width: x - (x - offset.width) * ratio + panChange.width,
            height: y - (y - offset.height) * ratio + panChange.height), frame: frame, scale: target, picture: picture)
        return value
    }
    public static func boundPan(_ offset: CGSize, frame: CGSize, scale: CGFloat, picture: CGSize? = nil) -> CGSize {
        let source = picture ?? frame, safeScale = max(scale, 1)
        let x = max(0, (source.width * safeScale - frame.width) / 2)
        let y = max(0, (source.height * safeScale - frame.height) / 2)
        return CGSize(width: min(x, max(-x, offset.width)), height: min(y, max(-y, offset.height)))
    }
    /// The part of the playback canvas the picture covers. The picture is the letterboxed `feed`
    /// scaled about its centre and moved by the offset; it is shown up to the canvas edge, never
    /// beyond it. At scale 1 this is `feed` itself, so the letterbox is unchanged.
    public func visiblePictureRect(feed: CGRect, canvas: CGSize) -> CGRect {
        guard scale > 1 else { return feed }
        let width = feed.width * scale, height = feed.height * scale
        let drawn = CGRect(x: feed.midX - width / 2 + offset.width,
            y: feed.midY - height / 2 + offset.height, width: width, height: height)
        let visible = drawn.intersection(CGRect(origin: .zero, size: canvas))
        return visible.isNull ? .zero : visible
    }
    public func settled() -> Self {
        guard scale < 1.05 else { return self }
        var value = self; value.reset(); return value
    }

    public mutating func pinchChanged(
        magnification: CGFloat, startAnchorX: CGFloat,
        startAnchorY: CGFloat, size: CGSize
    ) {
        guard magnification.isFinite, magnification > 0 else { return }
        if pinchStartScale == nil { pinchStartScale = scale }
        let target = min(maximumScale, max(1, (pinchStartScale ?? scale) * magnification))
        let ratio = target / scale
        let centroid = CGSize(
            width: (startAnchorX - 0.5) * size.width,
            height: (startAnchorY - 0.5) * size.height)
        offset = CGSize(
            width: centroid.width - (centroid.width - offset.width) * ratio,
            height: centroid.height - (centroid.height - offset.height) * ratio)
        scale = target
    }
    public mutating func panChanged(translation: CGSize) {
        guard isZoomed else { return }
        offset = CGSize(
            width: offset.width + translation.width - lastPanTranslation.width,
            height: offset.height + translation.height - lastPanTranslation.height)
        lastPanTranslation = translation
    }
    /// Continuous bounds preserve gesture origins while consuming each cumulative pan sample once.
    /// `size` is the area the zoomed picture may cover; `picture` is its unzoomed size, centred in
    /// that area (by default the same size). The picture's edge stops at the edge of `size`.
    public mutating func panChangedBounded(
        translation: CGSize, size: CGSize,
        horizontalPresentationScale: CGFloat = 1, verticalPresentationScale: CGFloat = 1,
        picture: CGSize? = nil
    ) {
        panChanged(translation: translation)
        constrain(
            size: size, picture: picture, horizontalPresentationScale: horizontalPresentationScale,
            verticalPresentationScale: verticalPresentationScale)
    }
    /// Target scale remains relative to the original gesture, never a mid-gesture commit.
    public mutating func pinchChangedBounded(
        magnification: CGFloat, startAnchorX: CGFloat,
        startAnchorY: CGFloat, size: CGSize, boundsSize: CGSize,
        horizontalPresentationScale: CGFloat = 1, verticalPresentationScale: CGFloat = 1,
        picture: CGSize? = nil
    ) {
        pinchChanged(magnification: magnification, startAnchorX: startAnchorX,
            startAnchorY: startAnchorY, size: size)
        constrain(
            size: boundsSize, picture: picture,
            horizontalPresentationScale: horizontalPresentationScale,
            verticalPresentationScale: verticalPresentationScale)
    }
    /// The drawn picture is `picture * scale * presentation scale`, centred in `size`; its edge may
    /// travel to the edge of `size` and no further. Smaller than `size` on an axis, it stays centred.
    private mutating func constrain(
        size: CGSize, picture: CGSize?, horizontalPresentationScale: CGFloat,
        verticalPresentationScale: CGFloat
    ) {
        let source = picture ?? size
        let maxX = max(0, max(0, source.width) * scale * max(0, horizontalPresentationScale)
            - max(0, size.width)) / 2
        let maxY = max(0, max(0, source.height) * scale * max(0, verticalPresentationScale)
            - max(0, size.height)) / 2
        offset = CGSize(
            width: min(maxX, max(-maxX, offset.width)),
            height: min(maxY, max(-maxY, offset.height)))
    }
    /// Ending a pinch must not retire the cumulative translation of a still-active pan.
    public mutating func endPinch(
        size: CGSize, horizontalPresentationScale: CGFloat = 1,
        verticalPresentationScale: CGFloat = 1, picture: CGSize? = nil
    ) {
        finish(size: size, picture: picture, horizontalPresentationScale: horizontalPresentationScale,
            verticalPresentationScale: verticalPresentationScale)
        pinchStartScale = nil
    }
    /// Ending a pan must not change the starting scale of a still-active pinch.
    public mutating func endPan(
        size: CGSize, horizontalPresentationScale: CGFloat = 1,
        verticalPresentationScale: CGFloat = 1, picture: CGSize? = nil
    ) {
        finish(size: size, picture: picture, horizontalPresentationScale: horizontalPresentationScale,
            verticalPresentationScale: verticalPresentationScale)
        lastPanTranslation = .zero
    }
    /// Context replacement cancels both gesture transactions and bounds the retained picture.
    public mutating func endGesture(
        size: CGSize, horizontalPresentationScale: CGFloat = 1,
        verticalPresentationScale: CGFloat = 1, picture: CGSize? = nil
    ) {
        finish(size: size, picture: picture, horizontalPresentationScale: horizontalPresentationScale,
            verticalPresentationScale: verticalPresentationScale)
        pinchStartScale = nil
        lastPanTranslation = .zero
    }
    private mutating func finish(
        size: CGSize, picture: CGSize?, horizontalPresentationScale: CGFloat,
        verticalPresentationScale: CGFloat
    ) {
        if scale < 1.05 {
            reset()
            return
        }
        constrain(size: size, picture: picture, horizontalPresentationScale: horizontalPresentationScale,
            verticalPresentationScale: verticalPresentationScale)
    }
    public mutating func reset() { self = MonitorPlaybackZoom(maximumScale: maximumScale) }
}

public enum MonitorPlaybackChromeSwipe: Equatable, Sendable {
    case show, hide, none
    public static func classify(dx: Double, dy: Double) -> Self {
        guard hypot(dx, dy) >= 28, abs(dy) > abs(dx) + 8, abs(dy) > 44 else { return .none }
        return dy < 0 ? .show : .hide
    }
}

/// The admitted edit is removed before invoking the host, so a late cancel cannot take its successor.
public struct MonitorPlaybackEditing: Equatable, Sendable {
    public private(set) var token: MonitorPlaybackScrubToken?
    public init() {}
    public mutating func admit(_ edit: MonitorPlaybackScrubToken?, item: MonitorPlaybackItemToken?)
        -> Bool
    {
        guard token == nil, let edit, edit.item == item else { return false }
        token = edit
        return true
    }
    public mutating func take(_ expected: MonitorPlaybackScrubToken? = nil)
        -> MonitorPlaybackScrubToken?
    {
        guard expected == nil || token == expected else { return nil }
        let admitted = token
        token = nil
        return admitted
    }
}
