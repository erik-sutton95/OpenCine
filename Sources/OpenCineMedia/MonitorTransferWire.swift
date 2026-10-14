import Foundation

/// Stable named-curve input across a native boundary. Camera bytes stay with their integration.
public enum MonitorTransferWire {
    public static func tag(_ transfer: MonitorTransfer) -> String { transfer.rawValue }

    /// An absent or unsupported name stays unknown, including a camera's unclassified HDR mode.
    public static func transfer(_ tag: String?) -> MonitorTransfer? {
        tag.flatMap(MonitorTransfer.init(rawValue:))
    }
}
