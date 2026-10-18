import Foundation

/// Native ISO extensions are declared by the source; nil means their support is unknown.
public struct CaptureNativeISOCapabilities: Equatable, Sendable {
    public var hop: Bool?
    public var ceiling: Bool?

    public init(hop: Bool? = nil, ceiling: Bool? = nil) {
        self.hop = hop
        self.ceiling = ceiling
    }
}
