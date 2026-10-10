#if os(iOS)
    import MonitorPresentation
    import MonitorUI
    import OpenCineAppKit
    import OpenCineCameraVocabulary
    import OpenCineMedia
    import SwiftUI

    /// Presentation of the existing camera/clip level and peak measurements. The meter and its
    /// menu are `MonitorAudioMeter` and `MonitorAudioMenu`; meter values and peak hold remain
    /// the camera's.
    public enum AudioAssist {
        public typealias Orientation = MonitorAudioOrientation
        public typealias Options = MonitorAudioOptions
        public typealias StoredCenter = MonitorAudioStoredCenter

        public static let panelSize = MonitorAudioMetrics.panelSize
        public static let barCrossAxis = MonitorAudioMetrics.barCrossAxis
        public static let helpCopy = "Meters the camera's audio. Available while live view is up."
        public static let playbackHelpCopy = "Meters the playing clip."

        public static func displayedSensitivity(_ value: String?) -> String {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? "\u{2014}" : trimmed.uppercased()
        }

        public static func panelSize(orientation: Orientation) -> CGSize {
            MonitorAudioMetrics.panelSize(orientation: orientation)
        }

        public static func levelFraction(_ db: Double) -> Double {
            MonitorAudioReadout.fraction(db)
        }

        public static func dbText(_ db: Double) -> String {
            MonitorAudioReadout.label(db)
        }

        public static func center(
            stored: StoredCenter?, size: CGSize, canvas: CGRect, movement: CGRect
        ) -> CGPoint {
            let fallback = CGPoint(x: movement.minX + size.width / 2, y: canvas.midY)
            let point = stored?.point(in: canvas) ?? fallback
            let minX = movement.minX + size.width / 2
            let minY = movement.minY + size.height / 2
            return CGPoint(
                x: min(max(minX, point.x), max(minX, movement.maxX - size.width / 2)),
                y: min(max(minY, point.y), max(minY, movement.maxY - size.height / 2)))
        }

        @MainActor
        public static func longPressMenu<Looks: MonitorLookProvider>(
            assist: MonitorAssistState<Looks>, stores: AssistPanelStores, haptics: OperatorHaptics,
            compact: Bool = false
        ) -> AudioLongPressMenu<Looks> {
            AudioLongPressMenu(assist: assist, stores: stores, haptics: haptics, compact: compact)
        }

        @MainActor
        public static func meter(levels: AudioMeterLevels, sensitivity: String?)
            -> AudioMetersPanelMini
        {
            AudioMetersPanelMini(levels: levels, sensitivity: sensitivity)
        }
    }

    public struct AudioLongPressMenu<Looks: MonitorLookProvider>: View {
        public var assist: MonitorAssistState<Looks>
        public var stores: AssistPanelStores
        public var haptics: OperatorHaptics
        public var compact: Bool = false

        public init(
            assist: MonitorAssistState<Looks>, stores: AssistPanelStores, haptics: OperatorHaptics,
            compact: Bool = false
        ) {
            self.assist = assist
            self.stores = stores
            self.haptics = haptics
            self.compact = compact
        }

        public var body: some View {
            let store = stores.audio
            MonitorAudioMenu(
                orientation: Binding(
                    get: { store.options.orientation },
                    set: {
                        store.options.orientation = $0
                        store.persist()
                    }),
                showsDB: Binding(
                    get: { store.options.showsDB },
                    set: {
                        store.options.showsDB = $0
                        store.persist()
                    }),
                help: assist.gradesClip ? AudioAssist.playbackHelpCopy : AudioAssist.helpCopy,
                compact: compact, orientationFeedback: { haptics.selection() })
        }
    }

    /// Draw-only body; movement and options gestures belong to AudioMeterOverlay.
    public struct AudioMetersPanelMini: View {
        public let levels: AudioMeterLevels
        public let sensitivity: String?
        public var orientation: AudioAssist.Orientation = .vertical
        public var showsDB = false

        public init(
            levels: AudioMeterLevels, sensitivity: String?,
            orientation: AudioAssist.Orientation = .vertical, showsDB: Bool = false
        ) {
            self.levels = levels
            self.sensitivity = sensitivity
            self.orientation = orientation
            self.showsDB = showsDB
        }

        public var body: some View {
            MonitorAudioMeter(
                left: levels.left.levelDB, leftPeak: levels.left.peakDB,
                right: levels.right.levelDB, rightPeak: levels.right.peakDB,
                orientation: orientation, showDB: showsDB,
                sensitivityLabel: AudioAssist.displayedSensitivity(sensitivity))
        }
    }
#endif
