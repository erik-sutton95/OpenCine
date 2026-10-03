import Foundation

/// One DJI GATT at a time. Events from a leftover Pocket must not drive a Nano session.
public enum BlePeerPolicy {
    public static func acceptsGATT(from peripheral: UUID, selected: UUID?) -> Bool {
        guard let selected else { return false }
        return peripheral == selected
    }
}
