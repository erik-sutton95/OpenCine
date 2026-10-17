#if os(iOS)
    import Foundation
    import MonitorPresentation
    import OpenCineMedia
    import SwiftUI

    extension MonitorPlaybackZoom {
        public mutating func pinchChanged(
            magnification: CGFloat, startAnchor: UnitPoint, size: CGSize
        ) {
            pinchChanged(
                magnification: magnification, startAnchorX: startAnchor.x,
                startAnchorY: startAnchor.y, size: size)
        }
    }

    public enum MonitorPlaybackZoomBoundary: Equatable, Sendable { case picture, canvas }

    /// Immutable facts accepted by the playback owner plus app-supplied source labels.
    public struct MonitorPlaybackPresentation {
        public var item: MonitorPlaybackItemToken?
        public var title: String
        public var subtitle: String
        public var source: String?
        public var metadata: [MonitorMetadataRow]
        public var aspect: Double
        public var mirrorHorizontal: Bool
        public var mirrorVertical: Bool
        public var ready: Bool
        public var error: String?
        public var progress: Double?
        public var position: Double
        public var duration: Double
        public var buffered: Double
        public var positionLabel: String
        public var durationLabel: String
        public var playing: Bool
        public var reachedEnd: Bool
        public var scrubbing: Bool
        public var muted: Bool
        public var looping: Bool
        public var previous: Bool
        public var next: Bool
        public var favorite: Bool
        public var conform: MonitorConformPreview.Source
        public var conformTarget: Double?
        public var haptics: Bool
        public var toast: String?
        public var initialChromeVisible: Bool
        public var loopAvailable: Bool
        public var shareEnabled: Bool
        public var doubleTapResetsZoom: Bool
        public var continuousPanBounds: Bool
        public var zoomBoundary: MonitorPlaybackZoomBoundary
        public var horizontalPresentationScale: CGFloat
        public var verticalPresentationScale: CGFloat
        public init(
            item: MonitorPlaybackItemToken?, title: String, subtitle: String, source: String?,
            metadata: [MonitorMetadataRow], aspect: Double, mirrorHorizontal: Bool = false,
            mirrorVertical: Bool = false, ready: Bool, error: String? = nil,
            progress: Double? = nil,
            position: Double, duration: Double, buffered: Double = 0, positionLabel: String,
            durationLabel: String, playing: Bool, reachedEnd: Bool, scrubbing: Bool, muted: Bool,
            looping: Bool, previous: Bool, next: Bool, favorite: Bool,
            conform: MonitorConformPreview.Source, conformTarget: Double?, haptics: Bool,
            toast: String? = nil,
            initialChromeVisible: Bool = true, loopAvailable: Bool = true,
            shareEnabled: Bool = true,
            doubleTapResetsZoom: Bool = false, continuousPanBounds: Bool = false,
            zoomBoundary: MonitorPlaybackZoomBoundary = .picture,
            horizontalPresentationScale: CGFloat = 1, verticalPresentationScale: CGFloat = 1
        ) {
            self.item = item
            self.title = title
            self.subtitle = subtitle
            self.source = source
            self.metadata = metadata
            self.aspect = aspect
            self.mirrorHorizontal = mirrorHorizontal
            self.mirrorVertical = mirrorVertical
            self.ready = ready
            self.error = error
            self.progress = progress
            self.position = position
            self.duration = duration
            self.buffered = buffered
            self.positionLabel = positionLabel
            self.durationLabel = durationLabel
            self.playing = playing
            self.reachedEnd = reachedEnd
            self.scrubbing = scrubbing
            self.muted = muted
            self.looping = looping
            self.previous = previous
            self.next = next
            self.favorite = favorite
            self.conform = conform
            self.conformTarget = conformTarget
            self.haptics = haptics
            self.toast = toast
            self.initialChromeVisible = initialChromeVisible
            self.loopAvailable = loopAvailable
            self.shareEnabled = shareEnabled
            self.doubleTapResetsZoom = doubleTapResetsZoom
            self.continuousPanBounds = continuousPanBounds
            self.zoomBoundary = zoomBoundary
            self.horizontalPresentationScale = horizontalPresentationScale
            self.verticalPresentationScale = verticalPresentationScale
        }
    }

    @MainActor public struct MonitorPlaybackDeletionActions {
        public let capture: (MonitorPlaybackItemToken) -> MonitorPlaybackDeletionConfirmation?
        public let isCurrent: (UUID) -> Bool
        public let confirm: (UUID) -> Void
        public let cancel: (UUID) -> Void
        public init(capture: @escaping (MonitorPlaybackItemToken) -> MonitorPlaybackDeletionConfirmation?,
            isCurrent: @escaping (UUID) -> Bool, confirm: @escaping (UUID) -> Void,
            cancel: @escaping (UUID) -> Void) {
            self.capture = capture; self.isCurrent = isCurrent; self.confirm = confirm; self.cancel = cancel
        }
    }

    @MainActor public struct MonitorPlaybackActions {
        public var back: () -> Void
        public var play: (MonitorPlaybackItemToken, Bool) -> Void
        public var restart: (MonitorPlaybackItemToken) -> Void
        public var seekBy: (MonitorPlaybackItemToken, Double) -> Void
        public var mute: (MonitorPlaybackItemToken, Bool) -> Void
        public var loop: (MonitorPlaybackItemToken, Bool) -> Void
        public var conform: (MonitorPlaybackItemToken, Double?) -> Void
        public var adjacent: (MonitorPlaybackItemToken, Int) -> Void
        public var favorite: (MonitorPlaybackItemToken) -> Void
        public var share: (MonitorPlaybackItemToken) -> Void
        public var delete: ((MonitorPlaybackItemToken) -> Void)?
        public var deletionConfirmation: MonitorPlaybackDeletionActions? = nil
        public var beginScrub: (MonitorPlaybackItemToken) -> MonitorPlaybackScrubToken?
        public var updateScrub: (MonitorPlaybackScrubToken, Double) -> Void
        public var updateFrameScrub: (MonitorPlaybackScrubToken, Double, Double) -> Void
        public var commitScrub: (MonitorPlaybackScrubToken) -> Void
        public var cancelScrub: (MonitorPlaybackScrubToken, MonitorEditingCancellation) -> Void
        public init(
            back: @escaping () -> Void, play: @escaping (MonitorPlaybackItemToken, Bool) -> Void,
            restart: @escaping (MonitorPlaybackItemToken) -> Void,
            seekBy: @escaping (MonitorPlaybackItemToken, Double) -> Void,
            mute: @escaping (MonitorPlaybackItemToken, Bool) -> Void,
            loop: @escaping (MonitorPlaybackItemToken, Bool) -> Void,
            conform: @escaping (MonitorPlaybackItemToken, Double?) -> Void,
            adjacent: @escaping (MonitorPlaybackItemToken, Int) -> Void,
            favorite: @escaping (MonitorPlaybackItemToken) -> Void,
            share: @escaping (MonitorPlaybackItemToken) -> Void,
            delete: ((MonitorPlaybackItemToken) -> Void)? = nil,
            beginScrub: @escaping (MonitorPlaybackItemToken) -> MonitorPlaybackScrubToken?,
            updateScrub: @escaping (MonitorPlaybackScrubToken, Double) -> Void,
            updateFrameScrub: @escaping (MonitorPlaybackScrubToken, Double, Double) -> Void,
            commitScrub: @escaping (MonitorPlaybackScrubToken) -> Void,
            cancelScrub: @escaping (MonitorPlaybackScrubToken, MonitorEditingCancellation) -> Void
        ) {
            self.back = back
            self.play = play
            self.restart = restart
            self.seekBy = seekBy
            self.mute = mute
            self.loop = loop
            self.conform = conform
            self.adjacent = adjacent
            self.favorite = favorite
            self.share = share
            self.delete = delete
            self.beginScrub = beginScrub
            self.updateScrub = updateScrub
            self.updateFrameScrub = updateFrameScrub
            self.commitScrub = commitScrub
            self.cancelScrub = cancelScrub
        }
    }

    public struct MonitorPlaybackPictureGeometry: Equatable {
        public let item: MonitorPlaybackItemToken?
        public let canvas: CGSize
        public let feed: CGRect
        public let zoom: MonitorPlaybackZoom
    }

    public struct MonitorPlaybackToolsContext {
        public let presentation: FieldMonitorLayout
        public let safeTop: CGFloat
        public let expanded: Binding<Bool>
    }
    /// Native/source content fills finite accessory slots; page state remains in MonitorPlaybackScreen.
    @MainActor public struct MonitorPlaybackPageSlots {
        public var headerAccessory: () -> AnyView
        /// Compact content alongside the header actions; expanded content uses headerAccessory.
        public var headerActionAccessory: () -> AnyView
        public var canvasDetails: (MonitorPlaybackCanvasContext) -> AnyView
        /// UIKit window coordinates of the actual share button, distinct from the assist bar frame.
        public var onShareButtonFrame: (CGRect) -> Void
        public var onChromeVisibilityChanged: (Bool) -> Void
        public var onAssistExpansionChanged: (Bool) -> Void
        public init(
            headerAccessory: @escaping () -> AnyView = { AnyView(EmptyView()) },
            canvasDetails: @escaping (MonitorPlaybackCanvasContext) -> AnyView = { _ in
                AnyView(EmptyView())
            },
            onShareButtonFrame: @escaping (CGRect) -> Void = { _ in },
            onChromeVisibilityChanged: @escaping (Bool) -> Void = { _ in },
            headerActionAccessory: @escaping () -> AnyView = { AnyView(EmptyView()) },
            onAssistExpansionChanged: @escaping (Bool) -> Void = { _ in }
        ) {
            self.headerAccessory = headerAccessory
            self.headerActionAccessory = headerActionAccessory
            self.canvasDetails = canvasDetails
            self.onShareButtonFrame = onShareButtonFrame
            self.onChromeVisibilityChanged = onChromeVisibilityChanged
            self.onAssistExpansionChanged = onAssistExpansionChanged
        }
    }

    public struct MonitorPlaybackCanvasContext {
        public let canvas: CGSize
        public let feed: CGRect
        public let zoom: MonitorPlaybackZoom
        public let chromeVisible: Bool
        public let assistExpanded: Bool
    }
#endif
