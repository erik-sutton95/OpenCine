import Foundation

/// Finds cameras near the phone (over Bluetooth) for a Multiview stage's Add list and network
/// scan. The coordinator decides when a scan is needed and stops it when nothing consumes it. An
/// integration or the app supplies it. Kotlin twin: `NearbyCameraScanner`.
@MainActor
public protocol NearbyCameraScanner<Camera>: AnyObject {
    /// A nearby camera as the integration's discovery reports it.
    associatedtype Camera

    /// Waits until the radio can scan; false when it never will (Bluetooth off or refused).
    func waitUntilReady() async -> Bool
    /// Reports cameras as they are seen, repeats included, until `stop()` or cancellation.
    func scan(_ found: @escaping @MainActor (Camera) -> Void) async
    /// Stops the radio scan.
    func stop()
}
