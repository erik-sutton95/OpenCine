#if os(iOS)
    import MonitorPresentation
    import MonitorUI

    /// The cinema live-monitor set. MAG is retired; PLAY stays off the video toolbar.
    extension MonitorAssistSelection {
        public var isRetired: Bool { self == .magnification }
        public var isPhotographyOnly: Bool { MonitorAssistCapabilities.standard.isPhotographyOnly(self) }

        /// Playback drops LEVEL (needs live camera attitude) and MAG (no on-feed key).
        /// AUDIO rides last, matching the live strip's trailing section.
        public static var playbackToolbarCases: [MonitorAssistSelection] {
            toolbarCases.filter { $0 != .level && $0 != .magnification && $0 != .evMeter } + [
                .audioMeters
            ]
        }

        /// The reference monitor's active tools minus photography-only and AUDIO.
        /// AUDIO is appended as its own trailing section in the assist bar.
        /// ND sits with the exposure meters (HISTO / VECTOR / LIGHTS).
        public static var toolbarGroups: [[MonitorAssistSelection]] {
            [
                [.lut, .peaking, .falseColor],
                [.zebra, .waveform, .parade],
                [.histogram, .vectorscope, .trafficLights, .ndMeter, .evMeter],
                [.guides, .grid, .crosshair, .level],
                [.desqueeze, .mirror],
            ]
        }

        public static var toolbarCases: [MonitorAssistSelection] { toolbarGroups.flatMap { $0 } }

        /// View Assist settings list: the same cinema set as the bar, plus AUDIO.
        public static var settingsCases: [MonitorAssistSelection] {
            toolbarCases + [.audioMeters]
        }

        /// Tools the operator can keep on DISP 2. Camera EV stays exclusive to DISP 1.
        public static var cleanPinCases: [MonitorAssistSelection] {
            settingsCases.filter { $0 != .evMeter }
        }

        /// Compact label for the Display > DISP 2 pin grid.
        public var displaySettingsTitle: String { sharedTool?.displaySettingsTitle ?? title }

        public var hasConfiguration: Bool { sharedTool?.hasConfiguration ?? false }

        /// The approved prototype owns these tool glyphs; app-only tools retain
        /// Lucide fallbacks without inventing a new visual language.
        public var monitorIcon: MonitorAssistIcon? { sharedTool?.monitorIcon }

        /// The remaining assist glyphs from the shared Lucide catalog.
        public var lucideIcon: MonitorIcon? {
            sharedTool?.fallbackIcon
                ?? (self == .instantReview ? .image : self == .magnification ? .zoomIn : nil)
        }

        public var title: String {
            sharedTool?.title ?? (self == .instantReview ? "Instant Playback" : "Magnify")
        }
    }
#endif
