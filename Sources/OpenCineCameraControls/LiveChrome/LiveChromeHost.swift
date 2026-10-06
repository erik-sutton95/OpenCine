#if os(iOS)
    import MonitorPresentation
    import MonitorUI
    import OpenCineAppKit

    /// What the live chrome (status row, telemetry gauges, assist palette, chrome editing) needs from
    /// an app on top of the capture sheets: the operator's display chrome per DISP mode, the assist
    /// state, which overlays are open and the live link telemetry. App differences arrive as values.
    @MainActor
    public protocol LiveChromeHost: CaptureSheetHost {
        /// The status row's recording state and clock, as this app projects it.
        var liveStatus: MonitorStatusPresentation { get }
        /// Whether the body reports a timecode the status row can show.
        var timecodeAvailable: Bool { get }
        /// Live link health, 0 to 4 bars (frame delivery, not radio RSSI).
        var liveSignalBars: Int { get }
        /// The feed rate label ("25.00", or LINK / RECOV / FAIL).
        var liveFPS: String { get }

        var assist: MonitorAssistState<MonitorLUTLooks> { get }
        var assistToolUsage: MonitorToolUsage { get set }
        var gimbalPanelOpen: Bool { get }

        /// The DISP mode whose chrome is being edited, if any.
        var chromeEditorMode: MonitorDisplayMode? { get }
        var isEditingChrome: Bool { get }
        /// Whether a chrome section is mounted in the current DISP mode (or shown for editing).
        func chromeSectionMounts(_ section: MonitorDisplayChrome.Section) -> Bool
        func chrome(for mode: MonitorDisplayMode) -> MonitorDisplayChrome
        func toggleChrome(_ section: MonitorDisplayChrome.Section, for mode: MonitorDisplayMode)
        func endChromeEditing()

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
    }
#endif
