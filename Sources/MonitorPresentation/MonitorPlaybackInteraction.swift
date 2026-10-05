import Foundation
import OpenCineMedia

/// Transient picture geometry. It has no native player or transport state.
public struct MonitorPlaybackZoom: Equatable, Sendable {
    public static let maxScale: CGFloat = 4
    public private(set) var scale: CGFloat = 1
    public private(set) var offset: CGSize = .zero
    private var committedScale: CGFloat = 1
    private var committedOffset: CGSize = .zero
    private var lastPanTranslation: CGSize = .zero
    public init() {}
    public var isZoomed: Bool { scale > 1.001 }

    public mutating func pinchChanged(
        magnification: CGFloat, startAnchorX: CGFloat,
        startAnchorY: CGFloat, size: CGSize
    ) {
        let target = min(Self.maxScale, max(1, committedScale * magnification))
        guard committedScale > 0 else { return }
        let ratio = target / committedScale
        let centroid = CGSize(
            width: (startAnchorX - 0.5) * size.width,
            height: (startAnchorY - 0.5) * size.height)
        offset = CGSize(
            width: centroid.width - (centroid.width - committedOffset.width) * ratio,
            height: centroid.height - (centroid.height - committedOffset.height) * ratio)
        scale = target
    }
    public mutating func panChanged(translation: CGSize) {
        guard isZoomed else { return }
        offset = CGSize(
            width: committedOffset.width + translation.width,
            height: committedOffset.height + translation.height)
    }
    /// Continuous bounds preserve gesture origins while consuming each cumulative pan sample once.
    public mutating func panChangedBounded(
        translation: CGSize, size: CGSize,
        horizontalPresentationScale: CGFloat = 1, verticalPresentationScale: CGFloat = 1
    ) {
        guard isZoomed else { return }
        offset = CGSize(
            width: offset.width + translation.width - lastPanTranslation.width,
            height: offset.height + translation.height - lastPanTranslation.height)
        lastPanTranslation = translation
        constrain(
            size: size, horizontalPresentationScale: horizontalPresentationScale,
            verticalPresentationScale: verticalPresentationScale)
    }
    /// Target scale remains relative to the original gesture, never a mid-gesture commit.
    public mutating func pinchChangedBounded(
        magnification: CGFloat, startAnchorX: CGFloat,
        startAnchorY: CGFloat, size: CGSize, boundsSize: CGSize,
        horizontalPresentationScale: CGFloat = 1, verticalPresentationScale: CGFloat = 1
    ) {
        let target = min(Self.maxScale, max(1, committedScale * magnification))
        guard scale > 0 else { return }
        let ratio = target / scale
        let x = (startAnchorX - 0.5) * size.width
        let y = (startAnchorY - 0.5) * size.height
        offset = CGSize(
            width: x - (x - offset.width) * ratio,
            height: y - (y - offset.height) * ratio)
        scale = target
        constrain(
            size: boundsSize, horizontalPresentationScale: horizontalPresentationScale,
            verticalPresentationScale: verticalPresentationScale)
    }
    private mutating func constrain(
        size: CGSize, horizontalPresentationScale: CGFloat,
        verticalPresentationScale: CGFloat
    ) {
        let maxX = max(0, size.width) * max(0, scale * max(0, horizontalPresentationScale) - 1) / 2
        let maxY = max(0, size.height) * max(0, scale * max(0, verticalPresentationScale) - 1) / 2
        offset = CGSize(
            width: min(maxX, max(-maxX, offset.width)),
            height: min(maxY, max(-maxY, offset.height)))
    }
    public mutating func endGesture(
        size: CGSize, horizontalPresentationScale: CGFloat = 1,
        verticalPresentationScale: CGFloat = 1
    ) {
        if scale < 1.05 {
            reset()
            return
        }
        let maxX = max(0, size.width) * max(0, scale * max(0, horizontalPresentationScale) - 1) / 2
        let maxY = max(0, size.height) * max(0, scale * max(0, verticalPresentationScale) - 1) / 2
        offset = CGSize(
            width: min(maxX, max(-maxX, offset.width)),
            height: min(maxY, max(-maxY, offset.height)))
        committedScale = scale
        committedOffset = offset
        lastPanTranslation = .zero
    }
    public mutating func reset() { self = MonitorPlaybackZoom() }
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
