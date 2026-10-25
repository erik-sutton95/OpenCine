import Foundation

/// Bounded time budget for each machine-driven connection phase.
///
/// Every phase the app can advance on its own gets a truthful ceiling, so a first connection that
/// stops making progress fails with an actionable error and a Retry instead of spinning forever
/// (the "cancel and try again" workaround). Phases that wait on a human — the Wi-Fi join prompt,
/// a pairing confirmation on the camera body — return `nil`: hurrying an operator is not a timeout.
public enum CameraConnectionTimeout {
    /// Seconds this phase may run before the attempt is failed, or `nil` when it waits on a person.
    ///
    /// The USB budget is the larger one: ImageCaptureCore's card enumeration gates the session-open
    /// ack, and on a full CFexpress card that legitimately takes over a minute.
    public static func budgetSeconds(for phase: CameraConnectionPhase, isUSB: Bool) -> Double? {
        switch phase {
        case .idle, .readyToJoin, .pairing, .confirmOnCamera, .connected, .failed:
            return nil
        case .joiningWiFi:
            return 45
        case .discovering:
            return 40
        case .handshaking:
            return isUSB ? 120 : 60
        case .preparingLiveView:
            return 40
        }
    }

    /// Operator-facing failure copy for a phase that ran out its budget.
    public static func timeoutMessage(phase: CameraConnectionPhase, deviceName: String) -> String {
        let name = deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        let camera = name.isEmpty ? "the camera" : name
        switch phase {
        case .joiningWiFi:
            return
                "Couldn't join \(camera)'s Wi‑Fi network in time. Check the camera is still broadcasting, then try again."
        case .discovering:
            return
                "Couldn't find \(camera) on the network in time. Check Connect to PC is on, then try again."
        case .handshaking:
            return
                "\(camera) stopped responding while connecting. Try again. If it keeps happening, power-cycle the camera."
        case .preparingLiveView:
            return "\(camera) connected but never started live view. Try again."
        case .idle, .readyToJoin, .pairing, .confirmOnCamera, .connected, .failed:
            return "The connection attempt timed out. Try again."
        }
    }
}
