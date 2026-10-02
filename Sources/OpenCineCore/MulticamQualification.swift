import Foundation

/// An integration's verdict for adding a camera configuration to a multiview stage. This
/// qualifies the requested configuration, not unreported camera state or a future command.
public enum MulticamQualification: Hashable, Codable, Sendable {
    case qualified
    /// The integration has not established whether this configuration is supported.
    case unknown
    case refused(MulticamQualificationRefusal)
}

/// Common policy explanations. Integrations keep their more specific explanations beside
/// their own qualification rules; shared admission needs only these actionable categories.
public enum MulticamQualificationRefusal: String, Hashable, Codable, Sendable {
    case alreadyMember
    case unsupportedConfiguration
    case operationUnavailable
    case notReachable
}
