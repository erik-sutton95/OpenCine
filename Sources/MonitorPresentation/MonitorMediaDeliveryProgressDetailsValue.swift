import Foundation

/// Optional delivery details supplied by the host that owns the current run.
/// Neither a filename nor destination is inferred from progress or artwork.
public struct MonitorMediaDeliveryProgressDetailsValue: Equatable, Sendable {
    public let filename: String?
    public let destination: String?

    public init(filename: String? = nil, destination: String? = nil) {
        self.filename = filename
        self.destination = destination
    }
}
