import Foundation
import OpenCineMedia

/// One construction path for every incident producer. Host identity and observed camera values
/// arrive as values; hardware and OS use the same diagnostics vocabulary as problem reports.
public struct FeedIncidentProducerContext: Sendable {
    private let host: DiagnosticsHost
    private let device: DiagnosticsDevice

    public init(host: DiagnosticsHost, device: DiagnosticsDevice = .current) {
        self.host = host
        self.device = device
    }

    public func make(
        sessionID: String = UUID().uuidString, cameraFamily: String,
        cameraFirmware: String? = nil, decoderGeneration: Int = 0, socketGeneration: Int = 0,
        testSource: FeedIncidentTestSource = .unknown, buildIdentity: String = "unknown"
    )
        -> FeedIncidentSessionContext
    {
        FeedIncidentSessionContext(
            sessionID: host.redact(sessionID), appVersion: host.redact(host.version),
            appBuild: host.redact(host.build), sourceRevision: host.redact(host.sourceRevision),
            osName: host.redact(device.osName),
            osVersion: host.redact(device.osVersion),
            hardwareClass: host.redact(device.hardwareClass),
            cameraFamily: host.redact(cameraFamily),
            cameraFirmware: cameraFirmware.map(host.redact),
            decoderGeneration: decoderGeneration, socketGeneration: socketGeneration,
            testSource: testSource, buildIdentity: host.redact(buildIdentity))
    }
}
