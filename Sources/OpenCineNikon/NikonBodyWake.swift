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
/// Paced by wall clock, one `slot` per dial: each dial carries its own deadline (1.5 s in
/// `PosixNikonDialer.isAlive`) and a dial that ends early waits out the rest of its slot. The
/// slot is what keeps the wait honest when the phone's kernel refuses dials instantly: after a
/// failed address resolution Darwin marks the host down for 20 s
/// (`net.link.ether.inet.host_down_time`) and every dial in that window returns EHOSTDOWN without
/// sending a frame (hardware pass 2026-10-25, 1.11: ten such dials collapsed the wait to about
/// 5 s, so a body woken by hand during it was never heard). With the defaults the wait is about
/// 20 s whatever the dials do, and an operator who half-presses the shutter during it is picked
/// up. The Kotlin twin is `NikonBodyWake` in `Android/nikon`.
public enum NikonBodyWake {
    /// Liveness dials before the body counts as silent.
    public static let dials = 10
    /// Shortest pause between two unanswered dials.
    public static let interval: Duration = .milliseconds(500)
    /// Wall-clock share of one dial: its 1.5 s deadline plus `interval`. A dial that fails sooner
    /// waits out the rest, so `dials` slots always span the same wait.
    public static let slot: Duration = .milliseconds(2_000)

    /// The monotonic clock the slots are measured on, as time since an arbitrary origin.
    public static func monotonicNow() -> Duration {
        let nanoseconds = DispatchTime.now().uptimeNanoseconds
        return .nanoseconds(Int64(clamping: nanoseconds))
    }

    /// The wake dials left after a failed connect that already took `spent`: the connect's own
    /// wait counts against the same budget, so the operator sees one wait of about `dials`
    /// slots, never a 10 s connect timeout plus a full wake. At least one dial always runs.
    static func dialsLeft(after spent: Duration, dials: Int, slot: Duration) -> Int {
        guard slot > .zero, spent > .zero else { return max(dials, 1) }
        let used = Int(spent / slot)
        return max(dials - used, 1)
    }

    /// The pause after an unanswered dial that took `spent`: the rest of its slot, never less
    /// than `interval`.
    static func pause(after spent: Duration, interval: Duration, slot: Duration) -> Duration {
        max(interval, slot - spent)
    }

    /// What a dial's wake tells the progress surface: the wait began, or the body answered and
    /// the handshake goes on. A silent body ends with `SilentError` instead.
    public enum Progress: Equatable, Sendable {
        case waiting
        case answered

        /// The connection phase the progress surface shows for this step.
        public var phase: CameraConnectionPhase {
            switch self {
            case .waiting: .discovering
            case .answered: .handshaking
            }
        }
    }

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
        slot: Duration = slot,
        isAlive: @Sendable (String) async -> Bool,
        now: @Sendable () -> Duration = monotonicNow,
        sleep: @Sendable (Duration) async throws -> Void = hostSleep(for:)
    ) async -> Outcome {
        var made = 0
        while made < max(dials, 1) {
            if Task.isCancelled { return .silent(dials: made) }
            made += 1
            let started = now()
            if await isAlive(host) { return .answered(dials: made) }
            if made < dials {
                let rest = pause(after: now() - started, interval: interval, slot: slot)
                do { try await sleep(rest) } catch { return .silent(dials: made) }
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
        now: @Sendable () -> Duration = monotonicNow,
        sleep: @Sendable (Duration) async throws -> Void = hostSleep(for:),
        dial: @Sendable () async throws -> Value
    ) async throws -> Value {
        let started = now()
        do {
            return try await dial()
        } catch let failure as DialFailure {
            guard failure.wakeWorthy, !Task.isCancelled else { throw failure.underlying }
            await onWake?()
            let left = dialsLeft(after: now() - started, dials: dials, slot: slot)
            let outcome = await awaitAnswer(
                host: host, dials: left, isAlive: isAlive, now: now, sleep: sleep)
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
    /// clock. `interval` and `slot` default to `0.5` and `2` seconds, the synchronous faces of
    /// `interval` and `slot` above; `now` and `sleep` are injectable for tests.
    public static func dialBlocking<Value>(
        host: String,
        deviceName: String = "",
        dials: Int = dials,
        interval: TimeInterval = 0.5,
        slot: TimeInterval = 2,
        isAlive: (String) -> Bool,
        onWake: () -> Void = {},
        now: () -> TimeInterval = blockingNow,
        sleep: (TimeInterval) -> Void = blockingSleep,
        dial: () throws -> Value
    ) throws -> Value {
        let started = now()
        do {
            return try dial()
        } catch let failure as DialFailure {
            guard failure.wakeWorthy else { throw failure.underlying }
            onWake()
            let left = dialsLeft(
                after: .milliseconds(Int64((now() - started) * 1_000)), dials: dials,
                slot: .milliseconds(Int64(slot * 1_000)))
            var made = 0
            var answered = false
            while made < left {
                if Task.isCancelled { break }
                made += 1
                let dialStarted = now()
                if isAlive(host) {
                    answered = true
                    break
                }
                if made < left {
                    let rest = Swift.max(interval, slot - (now() - dialStarted))
                    if rest > 0 { sleep(rest) }
                }
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

    /// Monotonic seconds for `dialBlocking`'s slots.
    public static func blockingNow() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    /// The thread sleep behind `dialBlocking`'s pauses.
    public static func blockingSleep(_ seconds: TimeInterval) {
        Thread.sleep(forTimeInterval: seconds)
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
