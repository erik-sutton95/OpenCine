import CoreMediaIO
import Foundation
import OpenCineDesktopKit
import os

private let log = Logger(subsystem: "com.opencapture.opencine", category: "driver-table")

/// Hands the driver what it needs from the dock, through custom properties on its inputs: the slot
/// table on the first slot's input, and the selected tab's slot on the "OpenCine" input. Both are
/// handed again every few seconds, because the driver can appear long after the dock starts (on
/// first approval or after an update) and keeps neither selection across a restart. One serial
/// queue does every delivery, so the driver receives selections in the order the owner made them.
enum DriverChannel {
    private static let queue = DispatchQueue(
        label: "com.opencapture.opencine.driver-channel", qos: .userInitiated)
    /// Queue only.
    private nonisolated(unsafe) static var table: String?
    private nonisolated(unsafe) static var selection: String?
    private nonisolated(unsafe) static var keeper: DispatchSourceTimer?

    /// The table to hand over, now and from then on.
    static func keepDelivered(_ table: VirtualCameraSlotTable) {
        guard let text = try? VirtualCameraSlotTableWire.encode(table) else { return }
        queue.async {
            Self.table = text
            deliverTable()
            startKeeper()
        }
    }

    /// The selected tab's slot, handed over at once so "OpenCine" switches on its next frame.
    static func follow(_ selection: VirtualCameraSelection) {
        let text = VirtualCameraSelectionWire.encode(selection)
        queue.async {
            Self.selection = text
            deliverSelection()
            startKeeper()
        }
    }

    private static func startKeeper() {
        guard keeper == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 3, repeating: 3, leeway: .milliseconds(500))
        timer.setEventHandler {
            deliverTable()
            deliverSelection()
        }
        keeper = timer
        timer.resume()
    }

    /// The driver ignores a table it already holds; reading it back is no check, since Core Media
    /// IO can answer from this process's cache.
    private static func deliverTable() {
        guard let table, let slot = VirtualCameraSlot(number: 1) else { return }
        set(
            table, selector: VirtualCameraSlotTableWire.selector,
            onDevice: [slot.legacyDeviceID, slot.deviceUUID.uuidString], named: "first input")
    }

    private static func deliverSelection() {
        guard let selection else { return }
        set(
            selection, selector: VirtualCameraSelectionWire.selector,
            onDevice: [
                SelectedVirtualCamera.legacyDeviceID, SelectedVirtualCamera.deviceUUID.uuidString,
            ], named: "OpenCine input")
    }

    private static func set(
        _ text: String, selector: String, onDevice uids: [String], named name: String
    ) {
        guard let device = device(withUID: uids) else {
            log.debug("The driver's \(name, privacy: .public) is not present yet")
            return
        }
        var address = CMIOObjectPropertyAddress(
            mSelector: fourCharacterCode(selector),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        guard CMIOObjectHasProperty(device, &address) else {
            log.error("The driver's \(name, privacy: .public) has no \(selector, privacy: .public) property")
            return
        }
        var value = text as CFString
        let size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            CMIOObjectSetPropertyData(device, &address, 0, nil, size, $0)
        }
        if status != 0 {
            log.error("Could not hand \(selector, privacy: .public) to the driver: \(status)")
        }
    }

    private static func fourCharacterCode(_ text: String) -> CMIOObjectPropertySelector {
        text.utf8.reduce(0) { $0 << 8 | CMIOObjectPropertySelector($1) }
    }

    /// The driver's input with one of these stable IDs.
    private static func device(withUID wanted: [String]) -> CMIOObjectID? {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var size: UInt32 = 0
        let system = CMIOObjectID(kCMIOObjectSystemObject)
        guard CMIOObjectGetPropertyDataSize(system, &address, 0, nil, &size) == 0, size > 0 else {
            return nil
        }
        var devices = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(system, &address, 0, nil, size, &used, &devices) == 0 else {
            return nil
        }
        return devices.first { uid(of: $0).map(wanted.contains) ?? false }
    }

    private static func uid(of device: CMIOObjectID) -> String? {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceUID),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var value: Unmanaged<CFString>?
        var used: UInt32 = 0
        let status = withUnsafeMutablePointer(to: &value) {
            CMIOObjectGetPropertyData(
                device, &address, 0, nil, UInt32(MemoryLayout<CFString?>.size), &used, $0)
        }
        guard status == 0 else { return nil }
        return value?.takeRetainedValue() as String?
    }
}
