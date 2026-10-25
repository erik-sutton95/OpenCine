import Foundation

/// A fresh, complete focus-rack safety readback. Live-frame focus evidence is supplied separately.
public struct NikonFocusRackSafetySnapshot: Equatable, Sendable {
    /// Whether the freshly read capture selector is movie mode.
    public let movieMode: Bool
    /// Decoded movie focus mode.
    public let focusMode: String
    /// Decoded movie AF-area mode.
    public let focusArea: String
    /// Decoded movie subject-detection mode.
    public let focusSubject: String
    /// Decoded lens range and maximum-aperture identity.
    public let lens: String
    /// Decoded current focal length.
    public let focalLength: String

    /// Rejects incomplete or undecoded values rather than treating retained data as fresh.
    public init(reported: PTPCameraPropertySnapshot) throws {
        guard let selector = reported.captureSelector,
            let mode = reported.focusMode, ["AF-S", "AF-C", "AF-F", "MF"].contains(mode),
            let area = reported.focusArea, !area.hasPrefix("0x"),
            let subject = reported.focusSubject, !subject.hasPrefix("0x"),
            let lens = reported.lens, let focalLength = reported.focalLength
        else { throw NikonFocusRackAccessError.safetyUnavailable }
        movieMode = selector == .video
        focusMode = mode
        focusArea = area
        focusSubject = subject
        self.lens = lens
        self.focalLength = focalLength
    }

    package static let properties: [(PTPPropertyCode, Int)] = [
        (.liveViewSelector, 1), (.movieFocusMode, 1), (.movieFocusMeteringMode, 2),
        (.movieAFSubjectDetection, 1), (.focalLength, 4), (.lensFocalMin, 4),
        (.lensFocalMax, 4), (.lensApertureMin, 2),
    ]
}

/// A native access failure; no failure establishes fresh safety observations.
public enum NikonFocusRackAccessError: Error, LocalizedError, Sendable {
    case authorityExpired
    case safetyUnavailable

    public var errorDescription: String? {
        switch self {
        case .authorityExpired: "Focus-rack camera authority expired."
        case .safetyUnavailable: "Fresh camera focus and lens safety readings are unavailable."
        }
    }
}

/// A narrow established-owner binding for a portable focus-rack execution controller.
/// Stop publication is synchronous and never waits for a camera command or an async runner.
public struct NikonFocusRackAccess: Sendable {
    /// Checks the captured native owner and revocable operator authority.
    public let isCurrent: @Sendable () -> Bool
    /// Prepares an increasing run identity without acquiring a camera command lock.
    public let prepareRun: @Sendable (Int64) -> Bool
    /// Publishes stop synchronously; an activated chunk owns serialized cleanup.
    public let requestStop: @Sendable (Int64) -> Void
    /// Executes one chunk without retries and reports confirmed or uncertain displacement.
    public let driveChunk: @Sendable (Int64, Bool, UInt32) async -> NikonFocusRackDriveOutcome
    /// Reads all required fields and confirms readiness; failure establishes no freshness.
    public let refreshSafety: @Sendable () async throws -> NikonFocusRackSafetySnapshot

    /// Binds native operations without exposing a transport, session registry, or JNI environment.
    public init(
        isCurrent: @escaping @Sendable () -> Bool,
        prepareRun: @escaping @Sendable (Int64) -> Bool,
        requestStop: @escaping @Sendable (Int64) -> Void,
        driveChunk: @escaping @Sendable (Int64, Bool, UInt32) async -> NikonFocusRackDriveOutcome,
        refreshSafety: @escaping @Sendable () async throws -> NikonFocusRackSafetySnapshot
    ) {
        self.isCurrent = isCurrent
        self.prepareRun = prepareRun
        self.requestStop = requestStop
        self.driveChunk = driveChunk
        self.refreshSafety = refreshSafety
    }
}
