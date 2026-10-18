#if os(iOS)
    import Foundation
    import MonitorPresentation
    import MonitorUI
    import OpenCineAppKit
    import OpenCineCameraVocabulary

    /// What the live chrome (status row, telemetry gauges, assist palette, chrome editing) needs from
    /// an app on top of the capture sheets: the operator's display chrome per DISP mode, the assist
    /// state, which overlays are open and the live link telemetry, plus the recovery card's
    /// `SessionRecoveryHost` and the chrome editor's `ChromeEditHost` over the shared DISP
    /// sections. App differences arrive as values.
    @MainActor
    public protocol LiveChromeHost: CaptureSheetHost, SessionRecoveryHost, ChromeEditHost, LegacyLiveClockAvailability
    where ChromeSection == MonitorDisplayChrome.Section, ChromeMode == MonitorDisplayMode {
        /// The status row's recording state and clock, as this app projects it.
        var liveStatus: MonitorStatusPresentation { get }
        /// Live link health, 0 to 4 bars (frame delivery, not radio RSSI).
        var liveSignalBars: Int { get }
        /// The feed rate label ("25.00", or LINK / RECOV / FAIL).
        var liveFPS: String { get }

        /// The one display owner: modes, chrome, editor, lock and connect arming.
        var operatorSession: MonitorOperatorSessionModel<MonitorLUTLooks> { get }
        var assist: MonitorAssistState<MonitorLUTLooks> { get }
        var assistToolUsage: MonitorToolUsage { get set }
        var gimbalPanelOpen: Bool { get }

        /// The DISP mode whose chrome is being edited, if any.
        var chromeEditorMode: MonitorDisplayMode? { get }
        var isEditingChrome: Bool { get }
        /// Whether a chrome section is mounted in the current DISP mode (or shown for editing).
        func chromeSectionMounts(_ section: MonitorDisplayChrome.Section) -> Bool
        func chrome(for mode: MonitorDisplayMode) -> MonitorDisplayChrome

        /// Returns to the multiview grid when this live view borrowed one of its cameras.
        var multiviewExit: (() -> Void)? { get }
        /// The camera is borrowed from multiview, so recording stays with the grid.
        var multiviewBorrowed: Bool { get }
        func openSettings()
        func openMedia()
        /// A held press on the focus box locks it against tap focus.
        var focusBoxLocked: Bool { get set }
        func resetFocusPoint()
        func unlockAutoExposure()

        /// The zoom the chip shows (a pending edit first, where the host has one).
        var zoomFactor: Double { get }
        /// Where a tap cycle starts: the unsnapped live or preview zoom.
        var zoomCycleOrigin: Double { get }
        /// The live pinch preview, while a pinch runs.
        var zoomPinchPreview: Double? { get }
        /// The chip label's top factor.
        var zoomCeiling: Double { get }
        var zoomTapStops: MonitorZoomTapStops { get }
        /// The stops a pinch ticks on.
        var zoomStops: [Double] { get }
        func cycleZoom(to ratio: Double)
        /// A pinch starts (the host may drop a pending zoom edit).
        func zoomPinchWillBegin()
        func updateZoomPinch(magnification: Double)
        func endZoomPinch()

        /// DISP 2 (clean) or DISP 1 (live), from a vertical swipe on the feed.
        func setDisplayMode(clean: Bool)
        var livePictureViewFlip: Bool { get }
        var canLockAutoExposure: Bool { get }
        /// Locks auto exposure from a held press; false when the camera cannot.
        func lockAutoExposure() -> Bool
        func showControlNote(_ note: String)
        /// The tap focus box's camera point, when the body takes tap focus and the box shows.
        var tapFocusPoint: CGPoint? { get }
        func handleFeedTap(at point: CGPoint)
        func startTracking(_ box: TrackingBox)

    }

    /// Every editor over the shared DISP sections names and offers them the same way.
    extension ChromeEditHost
    where ChromeSection == MonitorDisplayChrome.Section, ChromeMode == MonitorDisplayMode {
        /// Section order is the eye-badge placement priority. The lock and batteries take their
        /// corners first, then CODEC: its portrait detail box nests inside the status band, and a
        /// nested box cannot stack outward when the enclosing status eye has already taken the
        /// only free corner. Enum raw values and the persisted preference order are untouched.
        public var chromeEditSections: [MonitorDisplayChrome.Section] {
            let cornerFirst: [MonitorDisplayChrome.Section] = [.lockButton, .batteries, .codec]
            return cornerFirst + MonitorDisplayChrome.Section.allCases.filter { !cornerFirst.contains($0) }
        }

        public func chromeSectionTitle(_ section: MonitorDisplayChrome.Section) -> String {
            section.title
        }

        public func chromeSectionID(_ section: MonitorDisplayChrome.Section) -> String {
            section.rawValue
        }

        public func chromeModeTitle(_ mode: MonitorDisplayMode) -> String { mode.title }

        public func isChromeConfigurable(
            _ section: MonitorDisplayChrome.Section, in mode: MonitorDisplayMode
        ) -> Bool {
            MonitorDisplayChrome.isConfigurable(section, in: mode)
        }
    }

    extension LiveChromeHost {
        public func isChromeVisible(
            _ section: MonitorDisplayChrome.Section, in mode: MonitorDisplayMode
        ) -> Bool {
            chrome(for: mode).isVisible(section)
        }
    }
#endif
