/// Connection authority and arriving readings, independent of a camera's supported controls.
/// Kotlin twin: `MonitorConnectionPolicy`.
public struct MonitorConnectionPolicy: Equatable, Sendable {
    public let ownsCameraSession: Bool
    public let receivesCameraMetadata: Bool
    public let holdsRelayControl: Bool

    public init(ownsCameraSession: Bool, receivesCameraMetadata: Bool, holdsRelayControl: Bool = false) {
        self.ownsCameraSession = ownsCameraSession
        self.receivesCameraMetadata = receivesCameraMetadata
        self.holdsRelayControl = holdsRelayControl
    }

    /// A local session or a relay token admits commands; neither invents camera support.
    public var canDriveCamera: Bool { ownsCameraSession || holdsRelayControl }
    public var cameraControls: Bool { canDriveCamera }
    public var recordControl: Bool { canDriveCamera }
    /// Card transfers and source switching require the local session, even with a relay token.
    public var mediaBrowser: Bool { ownsCameraSession }
    public var offersSourceSwitch: Bool { ownsCameraSession }
    public var focusBoxes: Bool { receivesCameraMetadata }
    public var focusConfirmation: Bool { receivesCameraMetadata }
    public var subjectDetectionBoxes: Bool { receivesCameraMetadata }
    public var audioMeters: Bool { receivesCameraMetadata }
    public var cameraTimecode: Bool { receivesCameraMetadata }
    public var cameraLevel: Bool { receivesCameraMetadata }

    public static let owning = Self(ownsCameraSession: true, receivesCameraMetadata: true)
    public static func watcher(holdsControl: Bool) -> Self {
        Self(ownsCameraSession: false, receivesCameraMetadata: true, holdsRelayControl: holdsControl)
    }
}
