import CoreMediaIO
import Foundation
import OpenCineDesktopKit
import os

private let log = Logger(subsystem: "com.opencapture.opencine", category: "driver-table")

/// Hands the slot table to the driver through a property on its first input, and keeps handing it,
/// because the driver can appear long after the dock starts: on first approval or after an update.
enum DriverSlotTableChannel {
    private nonisolated(unsafe) static var keeper: Task<Void, Never>?

    @MainActor
    static func keepDelivered(_ table: VirtualCameraSlotTable) {
        guard let text = try? VirtualCameraSlotTableWire.encode(table) else { return }
        keeper?.cancel()
        keeper = Task.detached(priority: .utility) {
            while !Task.isCancelled {
                deliver(text)
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    /// Writes the table. The driver ignores a table it already holds; reading it back is no check,
    /// since Core Media IO can answer from this process's cache.
    private static func deliver(_ text: String) {
        guard let device = firstInput() else {
            log.debug("The driver's first input is not present yet")
            return
        }
        var address = CMIOObjectPropertyAddress(
            mSelector: selector,
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        guard CMIOObjectHasProperty(device, &address) else {
            log.error("The driver's first input has no slot table property")
            return
        }
        var value = text as CFString
        let size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            CMIOObjectSetPropertyData(device, &address, 0, nil, size, $0)
        }
        if status != 0 { log.error("Could not hand over the slot table: \(status)") }
    }

    private static var selector: CMIOObjectPropertySelector {
        VirtualCameraSlotTableWire.selector.utf8.reduce(0) { $0 << 8 | CMIOObjectPropertySelector($1) }
    }

    /// The driver's first input, found by its stable ID.
    private static func firstInput() -> CMIOObjectID? {
        guard let slot = VirtualCameraSlot(number: 1) else { return nil }
        let wanted = [slot.legacyDeviceID, slot.deviceUUID.uuidString]
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
