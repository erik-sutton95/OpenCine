import Foundation

/// Camera-reported recording facts. Preview dimensions and transport codec are separate facts.
public struct CameraRecordingFormat: Hashable, Codable, Sendable {
    public let dimensions: Dimensions?
    public let frameRate: Rational?
    /// Content identifier supplied by the integration, never a command or wire byte.
    public let profile: String?
    /// Content reported by the camera, including depth/container when the source supplies them.
    public let codec: String?

    public struct Dimensions: Hashable, Codable, Sendable {
        public let width: Int
        public let height: Int
        public init?(width: Int, height: Int) {
            guard width > 0, height > 0 else { return nil }
            self.width = width; self.height = height
        }
        private enum CodingKeys: String, CodingKey { case width, height }
        public init(from decoder: any Decoder) throws {
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            let width = try fields.decode(Int.self, forKey: .width)
            let height = try fields.decode(Int.self, forKey: .height)
            guard let value = Self(width: width, height: height) else {
                throw DecodingError.dataCorruptedError(forKey: .width, in: fields,
                    debugDescription: "Recording dimensions must be positive")
            }
            self = value
        }
    }

    public init(dimensions: Dimensions? = nil, frameRate: Rational? = nil,
        profile: String? = nil, codec: String? = nil) {
        self.dimensions = dimensions
        self.frameRate = frameRate.flatMap { $0.numerator > 0 ? $0 : nil }
        self.profile = profile.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
        self.codec = codec.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
    }
    private enum CodingKeys: String, CodingKey { case dimensions, frameRate, profile, codec }
    public init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        self.init(dimensions: try fields.decodeIfPresent(Dimensions.self, forKey: .dimensions),
            frameRate: try fields.decodeIfPresent(Rational.self, forKey: .frameRate),
            profile: try fields.decodeIfPresent(String.self, forKey: .profile),
            codec: try fields.decodeIfPresent(String.self, forKey: .codec))
    }

}
