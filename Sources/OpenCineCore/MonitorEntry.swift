import Foundation

/// Identity of a picture stream. Frames, decoders and native surfaces live in media runtime
/// products; portable state only names the stream and its generation.
public struct PictureSourceDescriptor: Hashable, Codable, Sendable {
    public var stream: StreamID
    public var generation: StreamGeneration
    /// Display label supplied by the integration or app, for example `HDMI`.
    public var label: String

    public init(stream: StreamID = StreamID(), generation: StreamGeneration = .init(), label: String) {
        self.stream = stream
        self.generation = generation
        self.label = label
    }
}

/// Picture health, kept apart from control-link health and recording state. A frozen picture
/// does not prove a camera stopped recording; a live picture does not prove control works.
public enum PictureHealth: Hashable, Codable, Sendable {
    case starting
    case live
    case stalled
    case failed
}

public enum TelemetrySource: Hashable, Codable, Sendable {
    /// From the entry's own camera session.
    case cameraSession
    /// Forwarded by a relay host while another device holds the camera.
    case relay
}

public enum MonitorEntryError: Error, Hashable, Sendable {
    /// No picture, camera session or telemetry: nothing to monitor.
    case noRole
    /// Owner or lease authority without a camera session to submit through.
    case commandAuthorityWithoutSession
    case sessionTelemetryWithoutSession
}

/// A monitoring slot composing an optional picture, an optional camera session, telemetry and
/// control authority. Control-only and picture-only entries are both valid. Replacing the picture
/// keeps the camera session and its control epoch.
///
/// Serializable description only: runtime ownership of the source, session and subscriptions is
/// held elsewhere.
public struct MonitorEntryDescriptor: Hashable, Codable, Sendable {
    public var id: MonitorEntryID
    public var name: String
    public var device: CameraDeviceID?
    public var picture: PictureSourceDescriptor?
    public var cameraSession: CameraSessionID?
    public var telemetry: TelemetrySource?
    public var controlAuthority: ControlAuthority

    public init(
        id: MonitorEntryID = MonitorEntryID(), name: String, device: CameraDeviceID? = nil,
        picture: PictureSourceDescriptor? = nil, cameraSession: CameraSessionID? = nil,
        telemetry: TelemetrySource? = nil, controlAuthority: ControlAuthority
    ) {
        self.id = id
        self.name = name
        self.device = device
        self.picture = picture
        self.cameraSession = cameraSession
        self.telemetry = telemetry
        self.controlAuthority = controlAuthority
    }

    public func validate() throws(MonitorEntryError) {
        if picture == nil, cameraSession == nil, telemetry == nil { throw .noRole }
        switch controlAuthority {
        case .owner, .lease:
            if cameraSession == nil { throw .commandAuthorityWithoutSession }
        case .readOnly, .unavailable:
            break
        }
        if telemetry == .cameraSession, cameraSession == nil {
            throw .sessionTelemetryWithoutSession
        }
    }
}
