import Foundation

/// One of the driver's fixed inputs. These identifiers never change: a receiving app saves them
/// in its scenes, so changing one loses a user's setup.
public struct VirtualCameraSlot: Hashable, Sendable {
    public static let count = 8
    /// Slots in order. A slot's position is its number minus one.
    public static let all: [VirtualCameraSlot] = (1...count).map { VirtualCameraSlot(number: $0)! }

    public let number: Int

    public init?(number: Int) {
        guard (1...Self.count).contains(number) else { return nil }
        self.number = number
    }

    public var legacyDeviceID: String { "OpenCine.Camera.\(number)" }
    public var sinkStreamName: String { "OpenCine.Camera.\(number).sink" }
    public var deviceUUID: UUID { identifier(0) }
    public var sourceStreamUUID: UUID { identifier(1) }
    public var sinkStreamUUID: UUID { identifier(2) }

    private func identifier(_ kind: Int) -> UUID {
        UUID(uuidString: "6F70656E-6369-4E65-8000-0000000000\(number)\(kind)")!
    }
}
