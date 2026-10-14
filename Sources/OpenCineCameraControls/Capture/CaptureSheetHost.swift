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
        func commitNativeCaptureQuick(_ selection: String, sheet: CaptureSheet)

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
        var captureCapabilities: CaptureSheetCapabilities { get }
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
    }
    public extension CaptureSheetHost {
        func nativeCapturePanel(_ sheet: CaptureSheet, enabled: Bool) -> NativeCapturePanel? { nil }
        var nativeMeteringSource: CaptureNativeMeteringSource? { nil }
        func commitNativeCaptureQuick(_ selection: String, sheet: CaptureSheet) {}
        /// Compatibility for existing hosts; migrated composition supplies routing explicitly.
        var captureRouting: CaptureSheetRouting {
            .init(commonExposureCompensation: captureCapabilities.commonExposureCompensation,
                commonFocusMode: captureCapabilities.commonFocusMode)
        }
    }
#endif
