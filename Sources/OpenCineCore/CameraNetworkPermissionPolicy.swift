import Foundation

/// Current evidence, distinct from a remembered permission acknowledgement.
public enum CameraNetworkPermissionState: String, Equatable, Sendable {
    case unknown, requested, allowed, denied
}

/// Only a completed local operation or an explicit policy signal determines permission.
public enum CameraNetworkPermissionEvidence: Sendable {
    case waiting, operationSucceeded, policyDenied
}

/// Attempt-scoped evidence. Retired callbacks cannot change a replacement's permission state.
public struct CameraNetworkPermissionObservation: Sendable {
    public private(set) var state: CameraNetworkPermissionState = .unknown
    private var current: UUID?

    public init() {}

    /// Starts fresh observation without treating an unanswered request as denial.
    @discardableResult public mutating func begin() -> UUID {
        let attempt = UUID()
        current = attempt
        state = .requested
        return attempt
    }

    public mutating func observe(_ evidence: CameraNetworkPermissionEvidence, attempt: UUID) {
        guard current == attempt else { return }
        switch evidence {
        case .waiting: break
        case .operationSucceeded: state = .allowed
        case .policyDenied: state = .denied
        }
    }

    public mutating func retire(attempt: UUID) {
        guard current == attempt else { return }
        current = nil
    }
}

/// Platform adapters supply actual error/path facts; Core never performs networking.
public enum CameraNetworkPermissionPolicy {
    public static func isLocalNetworkDenied(dnsErrorCode: Int32?, pathDenied: Bool) -> Bool {
        pathDenied || dnsErrorCode == -65570
    }
}
