#if os(iOS)
    import Foundation
    import Observation
    import OpenCineAppKit
    import OpenCineCameraVocabulary
    import OpenCineCore
    import SwiftUI

    /// Where a capture commit came from, so the app can route it along its own path.
    public enum CaptureCommitOrigin {
        /// A capture sheet, with the common field it opened (nil when the session offers none).
        case sheet(MonitorCaptureField?)
        /// A held readout drum, with the editor its snapshot captured (nil when it took none).
        case readout(MonitorControlModel.Editor?)
    }

    /// App composition selects a route independently of what the camera supports.
    public struct CaptureSheetRouting: Equatable, Sendable {
        public var commonExposureCompensation: Bool
        public var commonFocusMode: Bool
        public init(commonExposureCompensation: Bool = false, commonFocusMode: Bool = false) {
            self.commonExposureCompensation = commonExposureCompensation
            self.commonFocusMode = commonFocusMode
        }
    }

    /// What the session offers the capture sheets beyond its report.
    public struct CaptureSheetCapabilities: Equatable, Sendable {
        /// The FOCUS sheet shows its rows.
        public var focusMode: Bool
        /// The APERTURE sheet shows its strategies.
        public var aperture: Bool
        /// Source declarations retain unknown support independently of the UI's visibility.
        public var nativeISO: CaptureNativeISOCapabilities
        /// Compatibility visibility for hosts using the original Boolean interface.
        public var nativeIsoHop: Bool {
            get { nativeISO.hop == true }
            set { nativeISO.hop = newValue }
        }
        public var isoLimit: Bool {
            get { nativeISO.ceiling == true }
            set { nativeISO.ceiling = newValue }
        }
        /// EV is edited through the common field's drum rather than the app's EV wheel.
        public var commonExposureCompensation: Bool
        /// The FOCUS sheet opens the common focus field (the app routes its rows through it).
        public var commonFocusMode: Bool
        /// The body records audio the AUDIO tile and sheet can set.
        public var audio: Bool
        /// The body meters on faces, so the strip gives the host's metering tile a column.
        public var faceMetering: Bool

        public init(
            focusMode: Bool, aperture: Bool, nativeIsoHop: Bool, isoLimit: Bool,
            commonExposureCompensation: Bool, commonFocusMode: Bool, audio: Bool,
            faceMetering: Bool
        ) {
            self.focusMode = focusMode
            self.aperture = aperture
            self.nativeISO = .init(hop: nativeIsoHop, ceiling: isoLimit)
            self.commonExposureCompensation = commonExposureCompensation
            self.commonFocusMode = commonFocusMode
            self.audio = audio
            self.faceMetering = faceMetering
        }

        public init(focusMode: Bool, aperture: Bool, nativeISO: CaptureNativeISOCapabilities,
            commonExposureCompensation: Bool = false, commonFocusMode: Bool = false, audio: Bool, faceMetering: Bool) {
            self.focusMode = focusMode
            self.aperture = aperture
            self.nativeISO = nativeISO
            self.commonExposureCompensation = commonExposureCompensation
            self.commonFocusMode = commonFocusMode
            self.audio = audio
            self.faceMetering = faceMetering
        }
    }

    extension CaptureSheetCapabilities {
        /// The legacy flags as a view of the one model (routing stays the host's
        /// `CaptureSheetRouting`).
        public init(controls: ControlCapabilities) {
            self.init(focusMode: controls.focus.isOffered, aperture: controls.iris.isOffered,
                nativeISO: controls.iso.offer?.nativeISO ?? .init(), audio: controls.audio.isOffered,
                faceMetering: controls.faceMetering.isOffered)
        }
    }

    extension ControlCapabilities {
        /// The model with a legacy host's capture-sheet flags laid over it, so a host that has not
        /// adopted `controlCapabilities` offers exactly what its flags said. A flag that is off hides
        /// the family (unknown unless the model already knows it is not offered).
        public func overlaying(_ legacy: CaptureSheetCapabilities) -> ControlCapabilities {
            func flag<Offer>(_ on: Bool, _ capability: ControlCapability<Offer>) -> ControlCapability<Offer> {
                if on { return capability.isOffered ? capability : .supported(capability.offer) }
                return capability.isOffered ? .unknown : capability
            }
            var controls = self
            controls.focus = flag(legacy.focusMode, focus)
            controls.iris = flag(legacy.aperture, iris)
            controls.audio = flag(legacy.audio, audio)
            // A legacy host showed its level meter wherever it offered the AUDIO tile.
            controls.liveAudioLevels = flag(legacy.audio, liveAudioLevels)
            controls.faceMetering = flag(legacy.faceMetering, faceMetering)
            var iso = controls.iso.offer ?? ISOOffer()
            iso.nativeISO = legacy.nativeISO
            controls.iso = ControlCapability(support: controls.iso.support, access: controls.iso.access, offer: iso)
            return controls
        }
    }

    /// Optional integration-owned metering; unknown has no toggle target.
    @MainActor public struct CaptureNativeMeteringSource {
        public let face: Bool?
        public let isCurrent: () -> Bool
        public let setFace: (Bool) -> Void
        public init(face: Bool?, isCurrent: @escaping () -> Bool, setFace: @escaping (Bool) -> Void) {
            self.face = face; self.isCurrent = isCurrent; self.setFace = setFace
        }
    }

    /// What the capture sheets and readout drums need from an app: its session's report and
    /// flags, its operator choices, one typed commit and two refreshes. App differences arrive
    /// here as values, never as brand branches.
    @MainActor
    public protocol CaptureSheetHost: AnyObject, Observable {
        associatedtype Palette: LiveChromePalette
        associatedtype NativeCapturePanel: View = EmptyView
        /// Integration-owned typed controls remain inside the shared sheet chrome.
        func nativeCapturePanel(_ sheet: CaptureSheet, enabled: Bool) -> NativeCapturePanel?
        var nativeMeteringSource: CaptureNativeMeteringSource? { get }
        func commitNativeCaptureQuick(_ sheet: CaptureSheet, selection: String)

        /// The camera's reported status.
        var cameraStatus: CameraStatus { get }
        /// The reported status as the sheets show it (a pending white balance request over the
        /// reported one, where the session keeps one).
        var displayStatus: CameraStatus { get }
        /// The capture strip shows an ISO, shutter speed or custom white balance request at once,
        /// through the common readout. False: it shows what the camera reported until it answers.
        var captureStripShowsPendingEdits: Bool { get }
        var connectedCameraID: UUID? { get }
        /// The connected body, or nil before one is known.
        var connectedBody: CameraModel? { get }
        var sessionPhaseLabel: String { get }
        var bodyFamily: CameraBodyFamily { get }
        var labelProfile: CameraLabelProfile { get }
        var colorModes: [ColorMode] { get }
        var currentShootingMode: ShootingMode? { get }
        var sessionLocked: Bool { get }
        /// The FORMAT sheet does not reseat while a format change waits for the camera.
        var formatPinActive: Bool { get }
        var autoExposureLocked: Bool { get }
        var autoWhiteBalanceLocked: Bool { get }
        /// Whether AWB lock can pin the live Auto Kelvin now.
        var canLockAutoWhiteBalance: Bool { get }
        /// Compatibility flags for hosts that have not adopted `controlCapabilities`.
        var captureCapabilities: CaptureSheetCapabilities { get }
        /// The one typed capability model of the connected camera: what the shared sheets, tiles
        /// and readouts offer. Supply the integration's model (its static body facts merged with the
        /// live snapshot); the default reads the legacy `captureCapabilities` over the Core snapshot.
        var controlCapabilities: ControlCapabilities { get }
        var captureRouting: CaptureSheetRouting { get }
        var audioService: CaptureAudioService? { get }
        /// The FOCUS rows this app offers.
        var focusOptions: [FocusOption] { get }

        var control: MonitorControlModel { get }
        var hapticsEnabled: Bool { get }
        var facePriorityExposureEnabled: Bool { get set }
        var nativeISOHopEnabled: Bool { get set }
        var shutterUsesAngle: Bool { get set }
        var shutterAngleDegrees: Double { get }
        var captureSheet: CaptureSheet? { get set }
        var captureDrum: CaptureDrumPresentation? { get set }
        /// An operator panel covers the live view, so readouts do not begin a drag.
        var operatorPanelOpen: Bool { get }
        /// A full-screen cover (settings, media) is up, so readouts do not open a drum.
        var coverOpen: Bool { get }

        /// The readout drum's primary choices for `sheet`, or nil when it has none.
        func quickSnapshot(_ sheet: CaptureSheet) -> CaptureQuickSnapshot?
        /// Sends `setting` to the camera along the app's own path.
        func commit(_ setting: CaptureSetting, from origin: CaptureCommitOrigin)
        /// A common drum committed `value` through its field.
        func captureDrumDidCommit(_ value: SettingValue)
        /// The ISO GET the ISO sheet asks for on open; returns once the reply arrived.
        func refreshIsoLimit() async

        /// What the one codec and colour popup lists: the codec choices the camera offers (none
        /// when it has none) and the colour choices valid for the selected codec.
        var recordingCodecColor: CaptureCodecColorChoices { get }
        /// Sends the codec choice `id` (a `recordingCodecColor.codecs` identity).
        func commitRecordingCodec(_ id: String)
    }
    public extension CaptureSheetHost {
        func nativeCapturePanel(_ sheet: CaptureSheet, enabled: Bool) -> NativeCapturePanel? { nil }
        var nativeMeteringSource: CaptureNativeMeteringSource? { nil }
        func commitNativeCaptureQuick(_ sheet: CaptureSheet, selection: String) {}
        /// A camera without codec choices: the colour modes it offers, by their shown label.
        var recordingCodecColor: CaptureCodecColorChoices {
            let labels = CaptureLists.colorDrumLabels(
                offered: colorModes, current: cameraStatus.colorMode, family: bodyFamily,
                profile: labelProfile)
            return CaptureCodecColorChoices(
                colors: labels.map { CaptureCodecColorChoice(id: $0, label: $0) },
                selectedColor: cameraStatus.colorMode?.label(for: bodyFamily, in: labelProfile))
        }
        func commitRecordingCodec(_ id: String) {}
        var controlCapabilities: ControlCapabilities {
            ControlCapabilities(snapshot: control.snapshot?.capabilities ?? CapabilitySnapshot(),
                profile: connectedBody?.captureProfile, codecColor: recordingCodecColor)
                .overlaying(captureCapabilities)
        }
        /// A format change or a shutter write still settling: the angle readout holds the
        /// operator's angle instead of pairing a rate and a speed from two moments. The whole
        /// window from the tap to the camera's speed at the new rate: the app's format pin (tap to
        /// readback), a reported rate change (readback to the re-sent speed, including a speed the
        /// camera clamps itself) and the pending shutter write (re-send to confirmation).
        var shutterAngleSettling: Bool {
            formatPinActive || control.pending[.shutter] != nil || control.frameRateSettling
        }

        /// The one emulated-angle readout of the strip, the control bar and the panel: the held
        /// angle and, when the camera makes it through the nearest legal speed, what it really is.
        func shutterAngleReadout(selection: MonitorCaptureSelection) -> (value: String, achieved: String?) {
            let shutter: ShutterValue?
            if case .shutter(let value)? = control.captureValue(.shutter, selection: selection) {
                shutter = value
            } else { shutter = nil }
            let rate: Rational?
            if case .frameRate(let value)? = control.snapshot?.value(of: .frameRate).value { rate = value } else { rate = nil }
            let available = CaptureLists.shutterDenoms(from: cameraStatus)
            let settling = shutterAngleSettling
            return (CaptureNativeReadoutPresentation.shutterAngle(common: shutter, frameRate: rate,
                    available: available, preferredAngle: shutterAngleDegrees, settling: settling),
                CaptureNativeReadoutPresentation.shutterAngleAchieved(common: shutter, frameRate: rate,
                    available: available, preferredAngle: shutterAngleDegrees, settling: settling))
        }

        /// The shutter panel's subtitle: the tabs, or what the camera really makes for the held angle.
        func shutterPanelSubtitle(selection: MonitorCaptureSelection) -> String {
            if cameraStatus.isPhoto { return "Speed" }
            guard shutterUsesAngle, let achieved = shutterAngleReadout(selection: selection).achieved else {
                return "Angle · speed"
            }
            return "Angle · actual \(achieved)"
        }

        /// Compatibility for existing hosts; migrated composition supplies routing explicitly.
        var captureRouting: CaptureSheetRouting {
            .init(commonExposureCompensation: captureCapabilities.commonExposureCompensation,
                commonFocusMode: captureCapabilities.commonFocusMode)
        }
    }
#endif
