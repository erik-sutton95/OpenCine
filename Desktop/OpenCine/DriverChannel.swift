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
///
/// When this process cannot see the driver (its device list can stay stale after a driver
/// update), the dock's own executable runs briefly with `helperFlag` and hands over instead.
enum DriverChannel {
    static let helperFlag = "--driver-handoff"
    private static let queue = DispatchQueue(
        label: "com.opencapture.opencine.driver-channel", qos: .userInitiated)
    /// Queue only.
    private nonisolated(unsafe) static var table: String?
    private nonisolated(unsafe) static var selection: String?
    private nonisolated(unsafe) static var driverEnabled = false
    private nonisolated(unsafe) static var lastRoute: DriverHandoff.Route?
    private nonisolated(unsafe) static var keeper: DispatchSourceTimer?

    /// The table to hand over, now and from then on.
    static func keepDelivered(_ table: VirtualCameraSlotTable) {
        guard let text = try? VirtualCameraSlotTableWire.encode(table) else { return }
        queue.async {
            Self.table = text
            deliver()
            startKeeper()
        }
    }

    /// The selected tab's slot, handed over at once so "OpenCine" switches on its next frame.
    static func follow(_ selection: VirtualCameraSelection) {
        let text = VirtualCameraSelectionWire.encode(selection)
        queue.async {
            Self.selection = text
            deliver()
            startKeeper()
        }
    }

    /// Whether the driver is installed and enabled, so a fresh process is worth starting.
    static func setDriverEnabled(_ enabled: Bool) {
        queue.async {
            let arrived = enabled && !driverEnabled
            driverEnabled = enabled
            if arrived { deliver() }
        }
    }

    /// Whether the driver's inputs exist, as a process started now sees them.
    static func driverIsPresent() async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: runHelper(table: nil, selection: nil)) }
        }
    }

    private static func startKeeper() {
        guard keeper == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 3, repeating: 3, leeway: .milliseconds(500))
        timer.setEventHandler { deliver() }
        keeper = timer
        timer.resume()
    }

    private static func deliver() {
        guard table != nil || selection != nil else { return }
        let (table, selection) = (Self.table, Self.selection)
        let route = DriverHandoff.deliver(
            driverEnabled: driverEnabled,
            thisProcess: { handOver(table: table, selection: selection) },
            freshProcess: { runHelper(table: table, selection: selection) })
        if route != lastRoute, let route {
            log.notice("The driver is reached from \(route == .thisProcess ? "the dock" : "a fresh process", privacy: .public)")
        }
        if let route { lastRoute = route }
    }

    /// The helper's work, in the process started with `helperFlag`. Exit status 0 when it saw the
    /// driver (and handed over what it was given), 3 when the driver's inputs are not there.
    static func runAsHelper(_ arguments: [String]) -> Int32 {
        func value(_ name: String) -> String? {
            arguments.firstIndex(of: name).flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
        }
        return handOver(table: value("--table"), selection: value("--selection")) ? 0 : 3
    }

    /// Runs the dock's executable as a helper and waits for it, at most 5 seconds.
    private static func runHelper(table: String?, selection: String?) -> Bool {
        guard let executable = Bundle.main.executableURL else { return false }
        let process = Process()
        process.executableURL = executable
        var arguments = [helperFlag]
        if let selection { arguments += ["--selection", selection] }
        if let table { arguments += ["--table", table] }
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do { try process.run() } catch {
            log.error("Could not start the driver helper: \(error, privacy: .public)")
            return false
        }
        if finished.wait(timeout: .now() + 5) == .timedOut {
            process.terminate()
            return false
        }
        return process.terminationStatus == 0
    }

    /// Hands over from this process. True when it saw the driver's first input, which every driver
    /// version has, and nothing it set failed. A driver too old for the selection still counts.
    private static func handOver(table: String?, selection: String?) -> Bool {
        guard let slot = VirtualCameraSlot(number: 1),
            let first = device(withUID: [slot.legacyDeviceID, slot.deviceUUID.uuidString])
        else {
            log.debug("The driver's first input is not present")
            return false
        }
        if let selection,
            let selected = device(withUID: [
                SelectedVirtualCamera.legacyDeviceID, SelectedVirtualCamera.deviceUUID.uuidString,
            ]),
            !set(selection, selector: VirtualCameraSelectionWire.selector, on: selected)
        {
            return false
        }
        // The driver ignores a table it already holds; reading it back is no check, since Core
        // Media IO can answer from this process's cache.
        if let table, !set(table, selector: VirtualCameraSlotTableWire.selector, on: first) {
            return false
        }
        return true
    }

    /// False only when the driver refused the write; a missing property (an older driver) is not
    /// a failure.
    private static func set(_ text: String, selector: String, on device: CMIOObjectID) -> Bool {
        var address = CMIOObjectPropertyAddress(
            mSelector: fourCharacterCode(selector),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        guard CMIOObjectHasProperty(device, &address) else {
            log.error("The driver's input has no \(selector, privacy: .public) property")
            return true
        }
        var value = text as CFString
        let size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            CMIOObjectSetPropertyData(device, &address, 0, nil, size, $0)
        }
        if status != 0 {
            log.error("Could not hand \(selector, privacy: .public) to the driver: \(status)")
        }
        return status == 0
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
