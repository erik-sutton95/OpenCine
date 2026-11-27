import Foundation

/// The driver's one input that is not a slot: "OpenCine", which shows whichever camera tab is
/// selected in the dock. Its identifiers never change, so a receiving app's saved scenes keep it.
/// It has no sink: it only shows the selected slot's picture.
public enum SelectedVirtualCamera {
    public static let displayName = "OpenCine"
    public static let legacyDeviceID = "OpenCine.Camera.Selected"
    public static let deviceUUID = UUID(uuidString: "6F70656E-6369-4E65-8000-0000000000A0")!
    public static let sourceStreamUUID = UUID(uuidString: "6F70656E-6369-4E65-8000-0000000000A1")!
}

/// Which slot the "OpenCine" input shows: the selected tab's slot, or none.
public struct VirtualCameraSelection: Hashable, Sendable {
    public var slot: VirtualCameraSlot?

    public init(slot: VirtualCameraSlot?) {
        self.slot = slot
    }

    /// The selected tab's slot in the table. No selection, or a module without a slot, is none.
    public init(selectedModuleID: String?, table: VirtualCameraSlotTable) {
        slot = selectedModuleID.flatMap { table.slot(forModule: $0) }
    }
}

/// How the dock tells the driver the selection: a custom Core Media IO property on the "OpenCine"
/// input, as the slot table travels on the first slot's input.
public enum VirtualCameraSelectionWire {
    /// The property's Core Media IO selector, and its name on the driver's side.
    public static let selector = "ocsl"
    public static let propertyName = "4cc_ocsl_glob_0000"

    /// The slot number, or "0" for none.
    public static func encode(_ selection: VirtualCameraSelection) -> String {
        String(selection.slot?.number ?? 0)
    }

    /// Any local process can write this property, so anything but "0" or a slot number is
    /// refused with `nil`, which leaves the selection as it is.
    public static func decode(_ text: String) -> VirtualCameraSelection? {
        guard text.count <= 2, text.allSatisfy(\.isASCII), let number = Int(text) else {
            return nil
        }
        if number == 0 { return VirtualCameraSelection(slot: nil) }
        return VirtualCameraSlot(number: number).map { VirtualCameraSelection(slot: $0) }
    }
}
