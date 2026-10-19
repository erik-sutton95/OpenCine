import Foundation
import OpenCineCore

/// The wake step before a saved Wi-Fi connect dials a body that discovery does not currently see.
///
/// A router or hotspot setup that the cameras list cannot see is dialled at its stored address
/// blind. When the body is asleep or off that network, every PTP/IP attempt only learns so the
/// slow way: a 10 s command-connection timeout, or "Host is down", once per attempt, and the
/// operator reads "command connection timed out" without being told the camera was simply not
/// answering (physical run 2026-10-18: the first two saved connects after about 30 minutes of ZR
/// idle). This step asks the network first, with the same liveness dial the cameras list uses
/// (the presence port, never a PTP byte, so it cannot disturb a body on its pairing wizard or held
/// by another device). The dials double as the wake: an idle body's radio answers one in about
/// 1.0-1.2 s once it is up. A body that answers goes on to the normal handshake; a silent one
/// ends the attempt with copy that says what is actually wrong.
///
/// Bounded by dial count, not wall clock: each dial carries its own deadline (1.5 s in
/// `PosixNikonDialer.isAlive`), so the worst case is `dials` times that plus the pauses, about
/// 20 s with the defaults. The Kotlin twin is `NikonBodyWake` in `Android/nikon`.
public enum NikonBodyWake {
    /// Liveness dials before the body counts as silent.
    public static let dials = 10
    /// Pause between two unanswered dials.
    public static let interval: Duration = .milliseconds(500)

    public enum Outcome: Equatable, Sendable {
        /// The body answered on dial `dials` (1-based).
        case answered(dials: Int)
        /// No dial reached the body.
        case silent(dials: Int)

        public var answered: Bool {
            if case .answered = self { return true }
            return false
        }
    }

    /// Dials `host` until it answers or `dials` dials went unanswered. Cancellation ends the wait
    /// as `.silent` with the dials made so far; the caller's own cancellation check decides what
    /// happens next.
    public static func awaitAnswer(
        host: String,
        dials: Int = dials,
        interval: Duration = interval,
        isAlive: @Sendable (String) async -> Bool,
        sleep: @Sendable (Duration) async throws -> Void = hostSleep(for:)
    ) async -> Outcome {
        var made = 0
        while made < max(dials, 1) {
            if Task.isCancelled { return .silent(dials: made) }
            made += 1
            if await isAlive(host) { return .answered(dials: made) }
            if made < dials {
                do { try await sleep(interval) } catch { return .silent(dials: made) }
            }
        }
        return .silent(dials: made)
    }

    /// Progress copy while the dials run.
    public static func wakingMessage(deviceName: String) -> String {
        "Waiting for \(camera(deviceName)) to answer on the network…"
    }

    /// Failure copy for a body that stayed silent: it names the two real causes (asleep, or not on
    /// this network) instead of a socket timeout.
    public static func silentMessage(deviceName: String) -> String {
        "\(camera(deviceName).capitalizedFirst) didn't answer on this network. If it is asleep, "
            + "wake it (half-press the shutter), check it is on the same Wi‑Fi as this device, "
            + "then try again."
    }

    private static func camera(_ deviceName: String) -> String {
        let name = deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "the camera" : name
    }
}

extension String {
    fileprivate var capitalizedFirst: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}
