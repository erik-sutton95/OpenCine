import Foundation

/// Recording facts retain their individual source, report time and precision across partial updates.
public struct CameraRecordingObservations: Hashable, Codable, Sendable {
    public var dimensions: ObservedValue<CameraRecordingFormat.Dimensions>
    public var profile: ObservedValue<String>
    public var codec: ObservedValue<String>

    public init(dimensions: ObservedValue<CameraRecordingFormat.Dimensions> = .unknown,
        profile: ObservedValue<String> = .unknown,
        codec: ObservedValue<String> = .unknown) {
        self.dimensions = dimensions
        self.profile = profile; self.codec = codec
    }
    public static let unknown = Self()
    private enum CodingKeys: String, CodingKey { case dimensions, profile, codec }
    public init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        self.init(dimensions: try fields.decodeIfPresent(ObservedValue<CameraRecordingFormat.Dimensions>.self, forKey: .dimensions) ?? .unknown,
            profile: try fields.decodeIfPresent(ObservedValue<String>.self, forKey: .profile) ?? .unknown,
            codec: try fields.decodeIfPresent(ObservedValue<String>.self, forKey: .codec) ?? .unknown)
    }
}
