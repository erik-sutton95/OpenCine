#if os(iOS)
    import MonitorPresentation
    import MonitorUI
    import OpenCineAppKit
    import OpenCineCameraVocabulary
    import SwiftUI

    public struct MonitorOperatorFramingComparison {
        public let vertical: Bool
        public let originalLabel: String
        public let processedLabel: String
        public init(vertical: Bool, originalLabel: String = "LOG", processedLabel: String = "LUT") {
            self.vertical = vertical; self.originalLabel = originalLabel; self.processedLabel = processedLabel
        }
    }

    /// Framing and comparison marks share one value composition for live, still and playback.
    /// Native AF boxes, calibrated level and camera-fed exposure observations compose beside it.
    public struct MonitorOperatorFramingMarks<Looks: MonitorLookProvider>: View {
        private let assist: MonitorAssistState<Looks>
        private let feed: CGRect
        private let visible: Set<MonitorAssistSelection>
        private let guideFallback: MonitorGuideAspect?
        private let comparison: MonitorOperatorFramingComparison?
        public init(assist: MonitorAssistState<Looks>, feed: CGRect,
            visible: Set<MonitorAssistSelection>, guideFallback: MonitorGuideAspect? = nil,
            comparison: MonitorOperatorFramingComparison? = nil) {
            self.assist = assist; self.feed = feed; self.visible = visible
            self.guideFallback = guideFallback; self.comparison = comparison
        }
        public var body: some View {
            ZStack {
                if visible.contains(.guides) {
                    if let guideFallback { GuidesAssist.overlay(feed: feed, assist: assist, fallback: guideFallback) }
                    else { MonitorAspectGuideFrames(selectedRatios: assist.selectedGuides, maskEnabled: assist.guideMask, feed: feed) }
                }
                if visible.contains(.grid) {
                    MonitorFeedGrid(feed: feed, thirds: assist.gridThirds, phi: assist.gridPhi, diagonal: assist.gridDiagonal)
                }
                if visible.contains(.crosshair) { MonitorFeedCrosshair(feed: feed) }
                if let comparison {
                    MonitorFeedComparisonMarks(vertical: comparison.vertical, feed: feed,
                        originalLabel: comparison.originalLabel, processedLabel: comparison.processedLabel)
                }
            }.allowsHitTesting(false)
        }
    }

    /// The marks drawn on the feed itself: framing guides, grid, crosshair, the LUT split marks,
    /// scene faces, the tracking box and the focus box. Playback passes the letterboxed clip rect as
    /// `feed`; live derives it from the de-squeezed picture.
    public struct FeedAssistMarks<Host: LiveChromeHost>: View {
        var grid: Bool
        var crosshair: Bool
        var guides: Bool
        var guideAspect: MonitorGuideAspect
        var focusPoint: CGPoint
        var overlay: FocusOverlay = .focus
        var sceneFaces: [TrackingBox] = []
        var showFocusChrome = true
        var showTapFocusBox = true
        /// AE lock: the focus / metering box turns yellow with an `AE-L` tag.
        var aeLocked = false
        /// Long-press lock on the tap-focus box: a lock tag at its lower corner.
        var focusLocked = false
        /// When set (letterboxed clip playback), framing overlays align to this rect
        /// instead of the full geometry.
        var feed: CGRect? = nil
        /// Decoded raster aspect before the optical correction.
        var sourceAspect: CGFloat? = nil
        /// Recorded frame width/height. Live 1:1 sits as a square inside a 16:9 well.
        var pictureAspect: CGFloat? = nil
        /// Live 180 / MIRROR compose. Nil uses the assist chip only (playback).
        var pictureMirrored: Bool? = nil
        /// MIRROR Vertical. Nil uses the assist chip only.
        var pictureFlippedVertically: Bool? = nil
        @Environment(Host.self) private var host

        public init(
            grid: Bool, crosshair: Bool, guides: Bool, guideAspect: MonitorGuideAspect,
            focusPoint: CGPoint, overlay: FocusOverlay = .focus, sceneFaces: [TrackingBox] = [],
            showFocusChrome: Bool = true, showTapFocusBox: Bool = true, aeLocked: Bool = false,
            focusLocked: Bool = false, feed: CGRect? = nil, sourceAspect: CGFloat? = nil,
            pictureAspect: CGFloat? = nil, pictureMirrored: Bool? = nil,
            pictureFlippedVertically: Bool? = nil
        ) {
            self.grid = grid
            self.crosshair = crosshair
            self.guides = guides
            self.guideAspect = guideAspect
            self.focusPoint = focusPoint
            self.overlay = overlay
            self.sceneFaces = sceneFaces
            self.showFocusChrome = showFocusChrome
            self.showTapFocusBox = showTapFocusBox
            self.aeLocked = aeLocked
            self.focusLocked = focusLocked
            self.feed = feed
            self.sourceAspect = sourceAspect
            self.pictureAspect = pictureAspect
            self.pictureMirrored = pictureMirrored
            self.pictureFlippedVertically = pictureFlippedVertically
        }

        public var body: some View {
            GeometryReader { proxy in
                let assist = host.assist
                let mirrored = pictureMirrored ?? assist.mirrorsHorizontally
                let flippedV = pictureFlippedVertically ?? assist.flipsVertically
                let shown = { (box: TrackingBox) in
                    box.flipped(horizontal: mirrored, vertical: flippedV)
                }
                let shownFocus = CGPoint(
                    x: mirrored ? 1 - focusPoint.x : focusPoint.x,
                    y: flippedV ? 1 - focusPoint.y : focusPoint.y)
                // Live: framing aids sit on the de-squeezed picture. Playback already
                // letterboxes the raster (`feed`); do not re-apply live desqueeze there.
                let feed =
                    self.feed
                    ?? overlayFeedRect(
                        CGRect(origin: .zero, size: proxy.size), assist,
                        pictureAspect: pictureAspect,
                        sourceAspect: sourceAspect)
                let focusFeed =
                    self.feed
                    ?? DesqueezeAssist.presentationRect(
                        sourceSize: sourceAspect.map { CGSize(width: $0, height: 1) } ?? proxy.size,
                        in: CGRect(origin: .zero, size: proxy.size), effects: assist.effects)
                let marks = trackingMarks(shown: shown, focus: shownFocus)
                ZStack {
                    MonitorOperatorFramingMarks(assist: assist, feed: feed,
                        visible: Set([MonitorAssistSelection.guides, .grid, .crosshair].filter {
                            $0 == .guides ? guides : $0 == .grid ? grid : crosshair
                        }), guideFallback: guideAspect,
                        comparison: assist.splitComparison && assist.isVisible(.lut)
                            ? .init(vertical: assist.splitVertical) : nil)
                    MonitorTrackingLayer(
                        brackets: marks.brackets, focus: marks.focus, feed: focusFeed)
                }
            }
            .allowsHitTesting(false)
        }

        private func trackingMarks(shown: (TrackingBox) -> TrackingBox, focus: CGPoint) -> (
            brackets: [MonitorTrackingBracketValue], focus: MonitorFocusMark?
        ) {
            func bracket(_ box: TrackingBox, _ color: Color, _ width: CGFloat)
                -> MonitorTrackingBracketValue
            {
                let drawn = shown(box)
                return .init(
                    normalizedRect: CGRect(
                        x: drawn.x, y: drawn.y, width: drawn.width, height: drawn.height),
                    color: color, lineWidth: width)
            }
            var brackets = sceneFaces.map {
                bracket($0, Host.Palette.text.opacity(SceneFacePolicy.dimOpacity), 1.6)
            }
            var focusMark: MonitorFocusMark?
            if showFocusChrome {
                switch overlay {
                case .search(let box):
                    brackets.append(bracket(box, Host.Palette.text.opacity(0.88), 1.5))
                    focusMark = .init(
                        point: focus, color: aeLocked ? Host.Palette.aeLock : Host.Palette.accent,
                        aeLocked: aeLocked)
                case .subject(let box): brackets.append(bracket(box, Host.Palette.good, 2))
                case .face(let box):
                    brackets.append(bracket(box, Host.Palette.text.opacity(0.92), 1.6))
                case .focus:
                    if showTapFocusBox || aeLocked {
                        focusMark = .init(
                            point: focus,
                            color: aeLocked ? Host.Palette.aeLock : Host.Palette.accent,
                            aeLocked: aeLocked, focusLocked: focusLocked)
                    }
                }
            }
            return (brackets, focusMark)
        }
    }

    /// Framing aids sit on the visible (de-squeezed) picture, not the full frame.
    @MainActor
    public func overlayFeedRect(
        _ full: CGRect, _ assist: MonitorAssistState<MonitorLUTLooks>, pictureAspect: CGFloat?,
        sourceAspect: CGFloat? = nil
    ) -> CGRect {
        let effects = assist.effects
        let raster = DesqueezeAssist.presentationRect(
            sourceSize: sourceAspect.map { CGSize(width: $0, height: 1) } ?? full.size,
            in: full, effects: effects)
        guard let pictureAspect, pictureAspect > 0 else { return raster }
        // The recorded picture may be letterboxed inside the camera's live raster.
        return DesqueezeAssist.presentationRect(
            sourceSize: CGSize(width: pictureAspect, height: 1), in: raster, effects: effects)
    }

    extension MonitorTrackingGeometry {
        /// The tracking cancel target on the subject's corner of the drawn (mirrored or flipped)
        /// picture.
        public static func cancelRect(
            box: TrackingBox, feed: CGRect, mirrored: Bool, flippedVertically: Bool = false
        ) -> CGRect {
            let drawn = box.flipped(horizontal: mirrored, vertical: flippedVertically)
            return cancelRect(
                for: feedRect(
                    normalized: CGRect(x: drawn.x, y: drawn.y, width: drawn.width, height: drawn.height),
                    in: feed))
        }
    }
#endif
