#if os(iOS)
    import Foundation
    import Observation
    import OpenCineAppKit
    import OpenCineCameraVocabulary
    import OpenCineCore

    /// Where a capture commit came from, so the app can route it along its own path.
    public enum CaptureCommitOrigin {
        /// A capture sheet, with the common field it opened (nil when the session offers none).
        case sheet(MonitorCaptureField?)
        /// A held readout drum, with the editor its snapshot captured (nil when it took none).
        case readout(MonitorControlModel.Editor?)
    }

    /// What the session offers the capture sheets beyond its report.
    public struct CaptureSheetCapabilities: Equatable, Sendable {
        /// The FOCUS sheet shows its rows.
        public var focusMode: Bool
        /// The APERTURE sheet shows its strategies.
        public var aperture: Bool
        /// The ISO sheet offers the native ISO hop toggle.
        public var nativeIsoHop: Bool
        /// Auto ISO has a settable ceiling (else its drum is one read-only "Auto" stop).
        public var isoLimit: Bool
        /// EV is edited through the common field's drum rather than the app's EV wheel.
        public var commonExposureCompensation: Bool
        /// The FOCUS sheet opens the common focus field (the app routes its rows through it).
        public var commonFocusMode: Bool

        public init(
            focusMode: Bool, aperture: Bool, nativeIsoHop: Bool, isoLimit: Bool,
            commonExposureCompensation: Bool, commonFocusMode: Bool
        ) {
            self.focusMode = focusMode
            self.aperture = aperture
            self.nativeIsoHop = nativeIsoHop
            self.isoLimit = isoLimit
            self.commonExposureCompensation = commonExposureCompensation
            self.commonFocusMode = commonFocusMode
        }
    }

    /// What the capture sheets and readout drums need from an app: its session's report and
    /// flags, its operator choices, one typed commit and two refreshes. App differences arrive
    /// here as values, never as brand branches.
    @MainActor
    public protocol CaptureSheetHost: AnyObject, Observable {
        associatedtype Palette: LiveChromePalette

        /// The camera's reported status.
        var cameraStatus: CameraStatus { get }
        /// The reported status as the sheets show it (a pending white balance request over the
        /// reported one, where the session keeps one).
        var displayStatus: CameraStatus { get }
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

        /// The readout drum's primary choices for `sheet`, or nil when it has none.
        func quickSnapshot(_ sheet: CaptureSheet) -> CaptureQuickSnapshot?
        /// Sends `setting` to the camera along the app's own path.
        func commit(_ setting: CaptureSetting, from origin: CaptureCommitOrigin)
        /// A common drum committed `value` through its field.
        func captureDrumDidCommit(_ value: SettingValue)
        /// The ISO GET the ISO sheet asks for on open; returns once the reply arrived.
        func refreshIsoLimit() async
        /// The audio GET the AUDIO sheet asks for on open.
        func refreshAudioState() async
    }
#endif
