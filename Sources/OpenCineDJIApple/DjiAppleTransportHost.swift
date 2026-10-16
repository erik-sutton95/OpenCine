import Foundation
import OpenCineCore

/// Caller-owned diagnostics and permission presentation for one native transport.
/// The journal may receive camera addresses or names; the caller owns privacy redaction/storage.
public struct DjiAppleTransportHost: Sendable {
    public var logSubsystem: String
    public var journal: @Sendable (String) -> Void
    /// Optional raw GATT diagnostic sink; the caller chooses privacy/storage policy.
    public var bluetoothGattJournal: @Sendable (String) -> Void
    public var localNetworkEvidence: @MainActor @Sendable (DjiAppleLocalNetworkEvidence, String) -> Void
    public var bluetoothDenied: String
    public var bluetoothOff: String
    public var bluetoothNotReady: String
    /// The host's one retained camera hotspot owner. Nil keeps the legacy native calls for
    /// existing clients that do not supply one.
    public var hotspot: CameraHotspotHost?
    #if DEBUG
        /// Explicit test-only source counters/fault injection. Absent in production transports.
        public var debugVideo: DjiAppleVideoTestHooks?
    #endif

    public init(
        logSubsystem: String = "com.opencapture.opencine.dji",
        journal: @escaping @Sendable (String) -> Void = { _ in },
        bluetoothGattJournal: @escaping @Sendable (String) -> Void = { _ in },
        localNetworkEvidence: @escaping @MainActor @Sendable
            (DjiAppleLocalNetworkEvidence, String) -> Void = { _, _ in },
        bluetoothDenied: String = "Bluetooth access is denied. Enable Bluetooth access in Settings, then try again.",
        bluetoothOff: String = "Bluetooth is off. Turn it on in Control Center or Settings, then try again.",
        bluetoothNotReady: String = "Bluetooth is not ready yet. Try again in a moment.",
        hotspot: CameraHotspotHost? = nil
    ) {
        self.logSubsystem = logSubsystem
        self.journal = journal
        self.bluetoothGattJournal = bluetoothGattJournal
        self.localNetworkEvidence = localNetworkEvidence
        self.bluetoothDenied = bluetoothDenied
        self.bluetoothOff = bluetoothOff
        self.bluetoothNotReady = bluetoothNotReady
        self.hotspot = hotspot
    }
}

/// Evidence emitted only by actual Network.framework traffic, never inferred from phase/live UI.
public enum DjiAppleLocalNetworkEvidence: Sendable { case allowed, denied }

/// Native receive-queue observation. Apps map it into their own incident schema/storage.
public struct DjiAppleQueueObservation: Equatable, Sendable {
    public let bytes: Int
    public let count: Int
    public let ageMilliseconds: Double?
    public let incompleteAccessUnits: Int
    public let drops: Int

    public init(bytes: Int = 0, count: Int = 0, ageMilliseconds: Double? = nil,
        incompleteAccessUnits: Int = 0, drops: Int = 0) {
        self.bytes = bytes
        self.count = count
        self.ageMilliseconds = ageMilliseconds
        self.incompleteAccessUnits = incompleteAccessUnits
        self.drops = drops
    }
}

#if DEBUG
/// Debug composition uses actual receive/delivery paths; no harness product is linked.
public struct DjiAppleVideoTestHooks: Sendable {
    public var sourceObserved: @Sendable (Int, Int) -> Void
    public var sourceDelivered: @Sendable (Int, Int) -> Void
    public var shouldDropPacket: @Sendable (UInt64) -> Bool

    public init(sourceObserved: @escaping @Sendable (Int, Int) -> Void = { _, _ in },
        sourceDelivered: @escaping @Sendable (Int, Int) -> Void = { _, _ in },
        shouldDropPacket: @escaping @Sendable (UInt64) -> Bool = { _ in false }) {
        self.sourceObserved = sourceObserved
        self.sourceDelivered = sourceDelivered
        self.shouldDropPacket = shouldDropPacket
    }
}
#endif
