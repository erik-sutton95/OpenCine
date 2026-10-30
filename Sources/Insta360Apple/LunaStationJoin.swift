import Insta360Protocol
import OpenCineCore

/// A station notification from the camera's Bluetooth link.
enum LunaStationEvent: Equatable, Sendable {
    /// 8215: the camera's Wi-Fi (re)started, as after a role switch.
    case wiFiStarted
    /// 8232: the camera's answer to a join.
    case result(LunaStationJoinResult)
}

/// Station notifications in arrival order. The Bluetooth receiver posts; one join waits.
@MainActor
final class LunaStationEvents {
    private var queued: [LunaStationEvent] = []
    private var waiter: (id: Int, continuation: CheckedContinuation<LunaStationEvent?, Never>)?
    private var nextWaiter = 0

    func post(_ event: LunaStationEvent) {
        if let waiter {
            self.waiter = nil
            waiter.continuation.resume(returning: event)
            return
        }
        queued.append(event)
        if queued.count > 16 { queued.removeFirst() }
    }

    func clear() { queued.removeAll() }

    /// The next event, or nil once `limit` passes on `clock` or the waiting task is cancelled.
    func next(within limit: Duration, on clock: HostClock) async -> LunaStationEvent? {
        if !queued.isEmpty { return queued.removeFirst() }
        nextWaiter += 1
        let id = nextWaiter
        let timer = Task { @MainActor [weak self] in
            do { try await clock.sleep(limit) } catch { return }
            self?.release(id)
        }
        defer { timer.cancel() }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: nil)
                } else {
                    waiter = (id, continuation)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.release(id) }
        }
    }

    /// Ends wait `id` without an event, if it is still the one waiting.
    private func release(_ id: Int) {
        guard let waiting = waiter, waiting.id == id else { return }
        waiter = nil
        waiting.continuation.resume(returning: nil)
    }
}

/// The camera's side of a Wi-Fi or hotspot setup, after it was asked into station role: the join
/// request and its result, as the official app runs it.
///
/// Right after a role switch the camera can refuse the join with reply 505 (Wi-Fi busy
/// switching); the join is sent again once notification 8215 says its Wi-Fi started. Only the
/// result for this join's network and password counts, so a late result from an earlier attempt
/// is ignored. A missing or transient result (timeout, connect failed, no address) gets one more
/// try. Every wait runs on `clock`.
@MainActor
struct LunaStationJoin {
    /// Sends one request over the encrypted Bluetooth session; throws
    /// `LunaProtocolError.cameraBusySwitchingWiFi` for reply 505.
    var send: @MainActor (LunaRequest) async throws -> Void
    var events: LunaStationEvents
    var clock: HostClock
    /// Throws when the connection this join belongs to is gone.
    var checkCurrent: @MainActor () throws -> Void

    /// The join's waits, all on `clock`.
    struct Timing: Sendable {
        /// How long the camera gets to answer a join (8232).
        var result = Duration.seconds(45)
        /// How long a busy camera gets to start its Wi-Fi (8215); the official app waits 38 s.
        var wiFiStart = Duration.seconds(38)
        /// After 8215, before the join is sent again (the official app's delay for some cameras).
        var settle = Duration.seconds(2)
    }
    var timing = Timing()

    /// Busy replies accepted before the join gives up.
    static let busyLimit = 2

    /// Joins `network` and returns the camera's result. Throws a failure with the setup's copy
    /// when the camera did not join.
    func run(_ network: LunaStationNetwork) async throws -> LunaStationJoinResult {
        var busy = 0
        var retried = false
        while true {
            try checkCurrent()
            // Only what the camera says after this request counts: 8215 also follows the
            // credential read, when its access point wakes.
            events.clear()
            do {
                try await send(
                    LunaProtocol.stationJoinRequest(ssid: network.ssid, password: network.password))
            } catch LunaProtocolError.cameraBusySwitchingWiFi {
                guard busy < Self.busyLimit else { throw Self.busyFailure(network) }
                busy += 1
                try await waitForWiFiStart()
                try await clock.sleep(timing.settle)
                continue
            }
            guard let result = try await result(for: network) else {
                if !retried {
                    retried = true
                    continue
                }
                throw Self.failure(nil, network)
            }
            if result.outcome == .joined { return result }
            if result.outcome.isTransient, !retried {
                retried = true
                continue
            }
            throw Self.failure(result.outcome, network)
        }
    }

    /// Waits for 8215, or for `timing.wiFiStart`; results seen meanwhile belong to no join.
    private func waitForWiFiStart() async throws {
        let deadline = clock.now() + timing.wiFiStart
        while clock.now() < deadline {
            guard let event = try await next(within: deadline - clock.now()) else { return }
            if event == .wiFiStarted { return }
        }
    }

    /// This join's result, skipping 8215 and results for another network or password; nil when
    /// none arrives within `timing.result`.
    private func result(for network: LunaStationNetwork) async throws -> LunaStationJoinResult? {
        let deadline = clock.now() + timing.result
        while clock.now() < deadline {
            guard let event = try await next(within: deadline - clock.now()) else { return nil }
            if case .result(let result) = event,
                result.answers(ssid: network.ssid, password: network.password)
            {
                return result
            }
        }
        return nil
    }

    /// The next event, or nil after `limit` on `clock`.
    private func next(within limit: Duration) async throws -> LunaStationEvent? {
        let event = await events.next(within: limit, on: clock)
        try Task.checkCancellation()
        try checkCurrent()
        return event
    }

    /// Throws for a network the camera cannot be asked to join. Checked before the camera leaves
    /// its own Wi-Fi, so a setup it cannot use never strands it in station mode.
    static func check(_ network: LunaStationNetwork) throws {
        guard LunaProtocol.acceptsStationNetwork(ssid: network.ssid, password: network.password) else {
            throw ConnectionFailure.luna(
                .joinFailed, "station.invalid-network",
                "The camera cannot use this network name or password. Edit the setup and enter them again.",
                phase: .joiningNetwork)
        }
    }

    static func busyFailure(_ network: LunaStationNetwork) -> ConnectionFailure {
        .luna(
            .joinFailed, "station.camera-busy",
            "The camera is still switching its Wi-Fi. Wait a moment, then connect again.",
            phase: .joiningNetwork)
    }

    /// The setup's copy for a join that did not succeed (`outcome` nil: no answer in time). A
    /// setup without a password may be missing one, so that failure says to check it.
    static func failure(_ outcome: LunaStationJoinResult.Outcome?, _ network: LunaStationNetwork)
        -> ConnectionFailure
    {
        let ssid = network.ssid
        if network.password.isEmpty, outcome != .networkNotFound {
            return .luna(
                .joinFailed, "station.check-password",
                StationRoutes.checkPasswordMessage(network: ssid), phase: .joiningNetwork)
        }
        switch outcome {
        case nil:
            return .luna(
                .timedOut, "station.join-timeout",
                "The camera did not join “\(ssid)” in time. Check that the network is in range, then connect again.",
                phase: .joiningNetwork)
        case .wrongPassword:
            return .luna(
                .joinFailed, "station.wrong-password",
                "The camera could not join “\(ssid)”: the password is wrong. Edit the setup and enter it again.",
                phase: .joiningNetwork)
        case .networkNotFound:
            return .luna(
                .joinFailed, "station.network-not-found",
                "The camera cannot see “\(ssid)”. Check the network name and bring the camera closer.",
                phase: .joiningNetwork)
        case .failed(let code):
            return .luna(
                .joinFailed, "station.join-failed.\(code)",
                "The camera could not join “\(ssid)”. Check the network, then connect again.",
                phase: .joiningNetwork)
        case .joined:
            preconditionFailure("a joined result is not a failure")
        }
    }
}
