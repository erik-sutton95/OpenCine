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

    /// One TCP dial that failed before the PTP-IP handshake began. The socket layer sets
    /// `wakeWorthy` only when the body did not answer at the link layer (no route, or the connect
    /// deadline); a refused dial proves the host is up, so waking it cannot help.
    // SAFETY: the failure is thrown and caught in the same task between the socket layer and
    // `dial`; it never crosses an isolation boundary, and `underlying` is only read there.
    public struct DialFailure: Error, @unchecked Sendable {
        public let underlying: any Error
        public let wakeWorthy: Bool

        public init(underlying: any Error, wakeWorthy: Bool) {
            self.underlying = underlying
            self.wakeWorthy = wakeWorthy
        }
    }

    /// The wake dials all went unanswered: the body is asleep or not on this network. The
    /// description is `silentMessage`, the copy written for exactly that cause.
    public struct SilentError: Error, LocalizedError, Sendable {
        public let deviceName: String

        public init(deviceName: String = "") {
            self.deviceName = deviceName
        }

        public var errorDescription: String? {
            NikonBodyWake.silentMessage(deviceName: deviceName)
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

    /// Runs `dial` once. When it fails with a wake-worthy `DialFailure`, asks the network with
    /// `awaitAnswer` and then dials exactly once more: a silent body, or a retry that is still
    /// unreachable, ends with `SilentError`; a different second failure surfaces its own error.
    /// There is no loop beyond that one retry, so a camera that is truly gone costs one wake and
    /// one extra dial, never an open-ended retry storm.
    public static func dial<Value>(
        host: String,
        deviceName: String = "",
        isAlive: @Sendable (String) async -> Bool,
        onWake: (@Sendable () async -> Void)? = nil,
        sleep: @Sendable (Duration) async throws -> Void = hostSleep(for:),
        dial: @Sendable () async throws -> Value
    ) async throws -> Value {
        do {
            return try await dial()
        } catch let failure as DialFailure {
            guard failure.wakeWorthy, !Task.isCancelled else { throw failure.underlying }
            await onWake?()
            let outcome = await awaitAnswer(host: host, isAlive: isAlive, sleep: sleep)
            guard outcome.answered else { throw SilentError(deviceName: deviceName) }
            do {
                return try await dial()
            } catch let retry as DialFailure {
                // The single retry was unreachable too: the body is not answering, so surface the
                // honest cause instead of a raw socket sentence or a second wake.
                if retry.wakeWorthy { throw SilentError(deviceName: deviceName) }
                throw retry.underlying
            }
        }
    }

    /// Blocking twin of `dial` for the Android session layer, which calls Swift on a JVM thread:
    /// the same one wake and one retry, measured with `Thread.sleep` instead of a suspending
    /// clock. `interval` defaults to `0.5` seconds, the synchronous face of `interval` above.
    public static func dialBlocking<Value>(
        host: String,
        deviceName: String = "",
        dials: Int = dials,
        interval: TimeInterval = 0.5,
        isAlive: (String) -> Bool,
        onWake: () -> Void = {},
        dial: () throws -> Value
    ) throws -> Value {
        do {
            return try dial()
        } catch let failure as DialFailure {
            guard failure.wakeWorthy else { throw failure.underlying }
            onWake()
            var made = 0
            var answered = false
            while made < max(dials, 1) {
                if Task.isCancelled { break }
                made += 1
                if isAlive(host) {
                    answered = true
                    break
                }
                if made < dials, interval > 0 { Thread.sleep(forTimeInterval: interval) }
            }
            guard answered else { throw SilentError(deviceName: deviceName) }
            do {
                return try dial()
            } catch let retry as DialFailure {
                // Same one-retry rule as the async twin: a second unreachable dial ends with the
                // honest sleep-or-off-network cause, never another wake.
                if retry.wakeWorthy { throw SilentError(deviceName: deviceName) }
                throw retry.underlying
            }
        }
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
