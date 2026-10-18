#if os(iOS)
    import Foundation
    import MonitorPresentation
    import Observation
    import OpenCineAppKit
    import OpenCineCameraVocabulary
    import OpenCineMedia

    /// The app's official looks: the rows its official tab lists and the bundled Rec.709
    /// conversion an official source resolves to.
    public struct OfficialLUTs: Sendable {
        /// The official rows; live Photo (`isPhotoLive`) lists only what applies to Rec.709.
        public let catalog: @Sendable (_ isPhotoLive: Bool) -> [LUTSelection]
        /// The bundled cube for an official source; nil when the app ships none for it.
        public let cube: @MainActor @Sendable (LUTSource) -> CubeLUT?

        public init(
            catalog: @escaping @Sendable (_ isPhotoLive: Bool) -> [LUTSelection],
            cube: @escaping @MainActor @Sendable (LUTSource) -> CubeLUT?
        ) {
            self.catalog = catalog
            self.cube = cube
        }
    }

    /// LUT looks behind the shared assist state: the operator's selection, the monitored colour
    /// and body, and the cube they resolve to. The app supplies its official cubes, its saved
    /// choices and its custom LUT folder.
    @MainActor @Observable
    public final class MonitorLUTLooks: MonitorLookProvider {
        public let official: OfficialLUTs
        public let preferences: LUTPreferences
        public let customLUTs: CustomLUTStore
        /// Shared initialization may read the provider. A host whose cube lookup waits for its
        /// saved choices starts this false and sets it once they load.
        public var preparationReady: Bool
        public var lutSelection: LUTSelection = .officialAuto
        public var monitorColorMode: ColorMode?
        public var monitorFamily: CameraBodyFamily = .fallback
        public var monitorCameraName: String?
        public var monitorLookProfile: CameraLUTProfile?
        public let colorSourceProfile: MonitorColorSourceProfile
        public var liveIsPhoto = false

        public init(
            official: OfficialLUTs, preferences: LUTPreferences, customLUTs: CustomLUTStore,
            preparationReady: Bool = true, lookProfile: CameraLUTProfile? = nil,
            colorSourceProfile: MonitorColorSourceProfile = .init()
        ) {
            self.official = official
            self.preferences = preferences
            self.customLUTs = customLUTs
            self.preparationReady = preparationReady
            self.monitorLookProfile = lookProfile
            self.colorSourceProfile = colorSourceProfile
        }

        public var referenceClipByte: Int {
            OpenCineMedia.ScopeExposureCeiling(profile: colorSourceProfile.clip).clipByte(transfer: transfer)
        }
        public func lutExposureTransfer(for transfer: MonitorTransfer) -> MonitorTransfer {
            transfer.lutExposureTransfer
        }
        public var selection: LUTSelection { lutSelection }
        public var transfer: MonitorTransfer { MonitorTransfer(monitorColorMode ?? .normal) }
        /// Unknown before the camera's first colour report and in Dolby Vision (product ruling
        /// 2026-10-16); `syncLUT` updates it, so the curve tools return without operator action.
        public var sourceTransfer: MonitorTransfer? { MonitorTransfer.known(monitorColorMode) }
        /// LUT input exposure is in stops of the source curve, so it waits for a known one.
        public var appliesLUTExposure: Bool { sourceTransfer != nil }
        public func statusLabel(enabled: Bool) -> String {
            if liveIsPhoto, enabled, lutSelection == .auto || lutSelection == .officialAuto {
                return "Auto · Rec.709"
            }
            return LUTResolver.statusLabel(
                enabled: enabled, selection: lutSelection, source: resolvedSource())
        }
        public func resolvedSource() -> LUTSource {
            LiveLUTResolver.resolve(
                selection: lutSelection,
                colorMode: monitorColorMode,
                profile: monitorLookProfile,
                hasCustomDLog: customLUTs.hasCube(.dLog),
                hasCustomDLog2: customLUTs.hasCube(.dLog2),
                hasCustomRec709: customLUTs.hasCube(.rec709),
                customFileName: preferences.selectedCustomFileName,
                isPhoto: liveIsPhoto
            )
        }

        public var cube: CubeLUT? {
            guard preparationReady else { return nil }
            let source = resolvedSource()
            switch source {
            case .creative(let look):
                return look.cube()
            case .custom(let slot):
                return customLUTs.cube(slot)
            case .file(let name):
                return customLUTs.cube(fileName: name)
            case .off:
                return nil
            default:
                return official.cube(source)
            }
        }
    }

    extension MonitorAssistState {
        public var longPressAnchor: CGRect {
            get {
                CGRect(
                    x: longPressAnchorRect.x, y: longPressAnchorRect.y,
                    width: longPressAnchorRect.width, height: longPressAnchorRect.height)
            }
            set { longPressAnchorRect = MonitorRect(newValue) }
        }
    }

    extension MonitorAssistState where Looks == MonitorLUTLooks {
        public var lutSelection: LUTSelection {
            get { looks.lutSelection }
            set { looks.lutSelection = newValue }
        }
        public var monitorColorMode: ColorMode? {
            get { looks.monitorColorMode }
            set { looks.monitorColorMode = newValue }
        }
        public var monitorFamily: CameraBodyFamily {
            get { looks.monitorFamily }
            set { looks.monitorFamily = newValue }
        }
        public var monitorCameraName: String? {
            get { looks.monitorCameraName }
            set { looks.monitorCameraName = newValue }
        }
        public var monitorLookProfile: CameraLUTProfile? {
            get { looks.monitorLookProfile }
            set { looks.monitorLookProfile = newValue }
        }
        public var liveIsPhoto: Bool {
            get { looks.liveIsPhoto }
            set { looks.liveIsPhoto = newValue; allowsTransferInference = !newValue }
        }
        public var lutStatusLabel: String { looks.statusLabel(enabled: lutEnabled) }
        public func resolvedSource() -> LUTSource { looks.resolvedSource() }

        /// Picking a look turns LUT on. Auto stays Auto until the operator picks something else.
        public func selectLUT(_ selection: LUTSelection) {
            lutSelection = selection
            lutEnabled = true
            looks.preferences.lutSelection = selection
            refreshLUTCube()
            persist()
        }

        /// Color / zoom / body changes only swap the cube while an Auto row is selected.
        /// Photo does not persist Rec.709 over last live log, and does not rewrite LUT prefs.
        public func syncLUT(
            to colorMode: ColorMode?,
            family: CameraBodyFamily = .fallback,
            cameraName: String? = nil,
            lookProfile: CameraLUTProfile? = nil,
            isPhoto: Bool = false,
            persistLast: Bool = true
        ) {
            liveIsPhoto = isPhoto && !gradesClip
            monitorColorMode = LiveMonitorColorScience.colorMode(
                isPhoto: liveIsPhoto, colorMode: colorMode)
            monitorFamily = family
            if let cameraName { monitorCameraName = cameraName }
            if let lookProfile { monitorLookProfile = lookProfile }
            if persistLast, let colorMode, !liveIsPhoto {
                looks.preferences.lastMonitorColorMode = colorMode
            }
            refreshLUTCube()
        }

        /// Playback Auto follows the clip's ColorGammaSxS. Do not persist Rec.709
        /// from a Normal take over last live D-Log / D-Log2.
        public func adoptPlaybackColor(
            _ colorMode: ColorMode,
            family: CameraBodyFamily = .fallback,
            cameraName: String? = nil,
            lookProfile: CameraLUTProfile? = nil
        ) {
            liveIsPhoto = false
            monitorColorMode = colorMode
            monitorFamily = family
            if let cameraName { monitorCameraName = cameraName }
            if let lookProfile { monitorLookProfile = lookProfile }
            refreshLUTCube()
        }

        /// LUT sheet appear. Live SET must not replace the clip's Auto cube -
        /// including disconnected library playback (`gradesClip`, no camera SET).
        /// Watcher isolation: do not restamp from the camera session.
        public func bindLUTPicker(
            live: ColorMode?,
            inPlayback: Bool,
            family: CameraBodyFamily = .fallback,
            cameraName: String? = nil,
            lookProfile: CameraLUTProfile? = nil,
            isPhoto: Bool = false,
            isWatching: Bool = false
        ) {
            if inPlayback || gradesClip {
                liveIsPhoto = false
                refreshLUTCube()
                return
            }
            if isWatching {
                refreshLUTCube()
                return
            }
            syncLUT(to: live, family: family, cameraName: cameraName, lookProfile: lookProfile, isPhoto: isPhoto)
        }

        /// Import adds a custom cube. Auto rows keep following color; otherwise this file arms.
        public func importCustom(fileName: String) {
            looks.preferences.selectedCustomFileName = fileName
            if lutSelection != .auto, lutSelection != .officialAuto {
                lutSelection = .customFile
                looks.preferences.lutSelection = .customFile
            }
            lutEnabled = true
            refreshLUTCube()
            persist()
        }

        public func importCustom(slot: CustomLUTSlot, fileName: String) {
            looks.preferences.setCustomFileName(fileName, for: slot)
            importCustom(fileName: fileName)
        }

        public func clearCustomSlot(_ slot: CustomLUTSlot) {
            let preferences = looks.preferences
            if lutSelection == slot.selection
                || preferences.selectedCustomFileName == preferences.customFileName(for: slot)
            {
                lutSelection = .auto
                preferences.lutSelection = .auto
                preferences.selectedCustomFileName = nil
            }
            refreshLUTCube()
            persist()
        }

        public func selectCustomFile(_ fileName: String) {
            looks.preferences.selectedCustomFileName = fileName
            selectLUT(.customFile)
        }

        public func clearCustomFile(_ fileName: String) {
            let preferences = looks.preferences
            if preferences.selectedCustomFileName == fileName || lutSelection == .customFile {
                lutSelection = .auto
                preferences.lutSelection = .auto
                preferences.selectedCustomFileName = nil
            }
            for slot in CustomLUTSlot.allCases where preferences.customFileName(for: slot) == fileName
            {
                preferences.setCustomFileName(nil, for: slot)
            }
            try? looks.customLUTs.remove(StoredCustomLUT(fileName: fileName))
            refreshLUTCube()
            persist()
        }

        public func exportLUTCube(bakeExposure: Bool) -> CubeLUT? {
            let color = PlaybackLUTColor.resolve(
                clip: monitorColorMode, live: monitorColorMode,
                last: looks.preferences.lastMonitorColorMode)
            return exportCube(bakeExposure: bakeExposure, transfer: MonitorTransfer(color ?? .normal))
        }
    }
#endif
