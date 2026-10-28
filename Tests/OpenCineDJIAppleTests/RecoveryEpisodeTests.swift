import Foundation
import OpenCineDJI
import OpenCineDJIApple
import Testing

@Suite @MainActor
struct DJIAppleRecoveryEpisodeTests {
    /// SIMULATED saved identity is sampled once while matching discovery and again at
    /// connect admission. The second exact target must reach the actual native owner.
    @Test func secondSavedIdentitySampleReachesActualConnectionOwner() async {
        let spine = Spine(); defer { spine.finish() }
        var samples = 0
        let second = DJISighting(id: spine.peer.camera.id, name: "SIMULATED updated saved Nano",
            model: CameraModel.resolve(modelId: 0x0019, name: "OsmoNano", brand: .dji), modelId: 0x0019)
        spine.enrichTarget = { value in samples += 1; return samples == 1 ? value : second }
        #expect(spine.episode.begin(targetID: second.id, trigger: .bleDropped, reason: "SIMULATED samples"))
        #expect(await spine.clock.drive { !spine.peer.preparedTargets.isEmpty })
        #expect(samples == 2)
        #expect(spine.peer.preparedTargets.first?.name == second.name)
        #expect(spine.peer.preparedTargets.first?.modelId == 0x0019)
        #expect(spine.peer.preparedTargets.first?.model == second.model)
    }

    /// SIMULATED second enrichment replaces A with B on A's canceled task. No A
    /// preparation/native connect or presentation may follow that callback.
    @Test func replacementDuringSecondSampleCannotPrepareOrPublishOldAttempt() async {
        let spine = Spine(); defer { spine.finish() }
        var samples = 0
        var successor: UUID?
        var prepared: [UUID] = []
        spine.onPrepare = { prepared.append($0.id) }
        spine.enrichTarget = { value in
            samples += 1
            if samples == 2 {
                spine.episode.cancel(clearHold: false)
                spine.advertises = false
                #expect(spine.episode.begin(targetID: value.id, trigger: .operatorRetry,
                    reason: "SIMULATED B"))
                successor = spine.episode.currentEpisodeID
            }
            return value
        }
        #expect(spine.episode.begin(targetID: spine.peer.camera.id,
            trigger: .bleDropped, reason: "SIMULATED A"))
        #expect(await spine.clock.drive { successor != nil || !spine.peer.preparedTargets.isEmpty })
        await spine.clock.settle()
        #expect(successor != nil)
        #expect(spine.episode.currentEpisodeID == successor)
        #expect(spine.episode.snapshot.state == .retrying(attempt: 1, maxAttempts: 8))
        #expect(spine.episode.snapshot.holdsPicture)
        #expect(prepared.isEmpty)
        #expect(spine.peer.preparedTargets.isEmpty)
        #expect(!spine.peer.trace.contains("GATT"))
    }
    /// SIMULATED native peers cross the public episode and actual ConnectionRun/Exchange.
    /// Six original native handshake misses exhaust one attempt; cleanup precedes scan2,
    /// and only a later actual source/presentation report releases the held picture.
    @Test func failedEndpointCleanupPrecedesSecondScanAndFreshPictureFinishes() async {
        let spine = Spine()
        defer { spine.finish() }
        spine.handshakeMisses = 6
        #expect(spine.episode.begin(targetID: spine.peer.camera.id,
            trigger: .bleDropped, reason: "SIMULATED native drop"))
        let finished = await spine.clock.drive {
            spine.episode.snapshot.state == .idle && !spine.episode.snapshot.holdsPicture
        }
        #expect(finished)
        #expect(spine.trace.filter { $0 == "scan" }.count == 2)
        #expect(spine.peer.trace.filter { $0 == "GATT" }.count == 2)
        #expect(spine.peer.trace.filter { $0 == "open AP" }.count == 7)
        #expect(spine.peer.trace.filter { $0 == "enable" }.count == 1)
        #expect(spine.clock.backoffs == [0.5])
        let closed = spine.trace.firstIndex(of: "close failed endpoint")
        let scanned = spine.trace.lastIndex(of: "scan")
        #expect(closed != nil && scanned != nil)
        if let closed, let scanned { #expect(closed < scanned) }
        #expect(!spine.episode.snapshot.cardGraceElapsed)
    }

    /// SIMULATED original8 attempts and seven literal waits, not a schedule recomputation.
    /// The outcome must not depend on how many yields each manual-clock step gets: nightly run
    /// 40565915791 saw 7 scans, 6 GATT and 6 waits when a loaded suite gave an attempt too few.
    @Test(arguments: [1, 64])
    func eightNativeGattMissesHandBackToOperatorWithOriginalWaits(yieldsPerStep: Int) async {
        let spine = Spine(); defer { spine.finish() }
        spine.clock.yieldsPerStep = yieldsPerStep
        spine.gattMisses = 8
        #expect(spine.episode.begin(targetID: spine.peer.camera.id,
            trigger: .bleDropped, reason: "SIMULATED eight misses"))
        #expect(await spine.clock.drive {
            spine.episode.snapshot.state == .waitingForOperator(attemptsMade: 8)
        })
        #expect(spine.trace.filter { $0 == "scan" }.count == 8)
        #expect(spine.peer.trace.filter { $0 == "GATT" }.count == 8)
        #expect(spine.clock.backoffs == [0.5, 1, 2, 4, 8, 8, 8])
        #expect(!spine.peer.trace.contains("enable"))
        #expect(spine.episode.snapshot.holdsPicture)
        #expect(spine.episode.snapshot.cardGraceElapsed)
    }

    /// SIMULATED no advertisement consumes exactly the original total180s budget.
    @Test func totalBudgetIncludesDiscoveryAndRetainsHeldWarning() async {
        let spine = Spine(); defer { spine.finish() }
        spine.advertises = false
        #expect(spine.episode.begin(targetID: spine.peer.camera.id,
            trigger: .bleDropped, reason: "SIMULATED absent camera"))
        #expect(await spine.clock.drive(timeouts: true) {
            if case .waitingForOperator = spine.episode.snapshot.state { return true }; return false
        })
        #expect(spine.clock.time == 180)
        #expect(!spine.peer.trace.contains("GATT"))
        #expect(!spine.peer.trace.contains("enable"))
        #expect(spine.episode.snapshot.holdsPicture)
        #expect(spine.episode.snapshot.cardGraceElapsed)
        #expect(spine.trace.contains("stop scan"))
    }

    /// SIMULATED registered boundary alone, unknown source and cached repaint retain hold.
    @Test func registeredNeedsLaterSourceAndPresentationRatherThanRepaint() async {
        let spine = Spine(); defer { spine.finish() }
        spine.publishFresh = false; spine.picture = (-1, -1)
        #expect(spine.episode.begin(targetID: spine.peer.camera.id,
            trigger: .bleDropped, reason: "SIMULATED held frame"))
        #expect(await spine.clock.drive { spine.peer.trace.contains("enable") })
        #expect(spine.episode.snapshot.holdsPicture)
        spine.clock.advance(to: spine.clock.time + 0.2); await spine.clock.settle()
        #expect(spine.episode.snapshot.state.isRecovering)
        spine.picture = (nil, spine.clock.time)
        spine.clock.advance(to: spine.clock.time + 0.2); await spine.clock.settle()
        #expect(spine.episode.snapshot.holdsPicture)
        spine.picture = (-1, spine.clock.time)
        spine.clock.advance(to: spine.clock.time + 0.2); await spine.clock.settle()
        #expect(spine.episode.snapshot.holdsPicture)
        spine.picture = (spine.clock.time, spine.clock.time)
        #expect(await spine.clock.drive {
            spine.episode.snapshot.state == .idle && !spine.episode.snapshot.holdsPicture
        })
        #expect(spine.peer.trace.filter { $0 == "enable" }.count == 1)
    }

    /// SIMULATED success leaves the drop ledger intact; only the explicit operator clears it.
    @Test func thirdSuccessfulThenDroppedSessionPausesUntilOperatorRetry() async {
        let spine = Spine(); defer { spine.finish() }
        for _ in 1...2 {
            spine.picture = (nil, nil)
            #expect(spine.episode.begin(targetID: spine.peer.camera.id,
                trigger: .bleDropped, reason: "SIMULATED drop"))
            #expect(await spine.clock.drive {
                spine.episode.snapshot.state == .idle && !spine.episode.snapshot.holdsPicture
            })
            await spine.clock.settle()
        }
        #expect(spine.episode.begin(targetID: spine.peer.camera.id,
            trigger: .bleDropped, reason: "SIMULATED third drop"))
        #expect(spine.episode.snapshot.state == .pausedAfterRepeatedDrops(drops: 3))
        #expect(spine.episode.snapshot.holdsPicture)
        #expect(spine.episode.snapshot.cardGraceElapsed)
        #expect(spine.peer.trace.filter { $0 == "GATT" }.count == 2)
        spine.picture = (nil, nil)
        #expect(spine.episode.retry())
        #expect(await spine.clock.drive {
            spine.episode.snapshot.state == .idle && !spine.episode.snapshot.holdsPicture
        })
        #expect(spine.peer.trace.filter { $0 == "GATT" }.count == 3)
    }

    /// SIMULATED cancellation runs synchronously at the retry publication, before a task
    /// gets actor time. Retired A must not revive state, discover or run the native spine.
    @Test func cancelInsideRetryPublicationDoesNotInstallOrRunAnotherTask() async {
        let spine = Spine(); defer { spine.finish() }
        var canceled = false
        spine.onChanged = { value, _ in
            if case .retrying = value.state, !canceled {
                canceled = true; spine.episode.cancel()
            }
        }
        #expect(!spine.episode.begin(targetID: spine.peer.camera.id,
            trigger: .bleDropped, reason: "SIMULATED synchronous cancel"))
        await spine.clock.settle()
        #expect(canceled)
        #expect(spine.episode.snapshot == .init())
        #expect(spine.episode.currentEpisodeID == nil)
        #expect(!spine.episode.isRunning)
        #expect(!spine.trace.contains("power"))
        #expect(!spine.trace.contains("scan"))
        #expect(!spine.peer.trace.contains("GATT"))
    }

    /// SIMULATED same-camera B begins from A's retry event. The authoritative snapshot
    /// precedes callbacks; A's canceled begin cannot overwrite B or retire B's tasks.
    @Test func sameCameraSuccessorInsideRetryEventKeepsItsStateAndNativeRun() async {
        let spine = Spine(); defer { spine.finish() }
        var replaced = false
        var successorID: UUID?
        spine.onChanged = { value, _ in
            if case .retrying = value.state, !replaced {
                replaced = true; spine.episode.cancel(clearHold: false)
                #expect(spine.episode.begin(targetID: spine.peer.camera.id,
                    trigger: .operatorRetry, reason: "SIMULATED successor B"))
                successorID = spine.episode.currentEpisodeID
            }
        }
        #expect(!spine.episode.begin(targetID: spine.peer.camera.id,
            trigger: .bleDropped, reason: "SIMULATED A"))
        #expect(replaced && successorID != nil)
        #expect(spine.episode.currentEpisodeID == successorID)
        #expect(spine.episode.snapshot.state == .retrying(attempt: 1, maxAttempts: 8))
        #expect(spine.episode.isRunning)
        #expect(await spine.clock.drive {
            spine.episode.snapshot.state == .idle && !spine.episode.snapshot.holdsPicture
        })
        #expect(spine.peer.trace.filter { $0 == "GATT" }.count == 1)
        #expect(spine.peer.trace.filter { $0 == "enable" }.count == 1)
        #expect(spine.peer.currentEndpoint?.isClosed == false)
    }

    /// SIMULATED deliberately cancellation-ignoring native awaits. Resuming A later may
    /// return from the OS operation, but cannot scan/write/publish/close B's actual run.
    @Test(arguments: ["power", "GATT", "open"])
    func lateNativeAwaitCannotMutateSameCameraSuccessor(boundary: String) async {
        let spine = Spine(); defer { spine.finish() }
        let gate = Gate()
        switch boundary {
        case "power": spine.onPower = { await gate.wait(); return true }
        case "GATT": spine.peer.onConnect = { await gate.wait() }
        case "open": spine.peer.onOpen = { await gate.wait() }
        default: break
        }
        #expect(spine.episode.begin(targetID: spine.peer.camera.id,
            trigger: .bleDropped, reason: "SIMULATED A"))
        await spine.clock.settle()
        #expect(gate.isWaiting)
        spine.episode.cancel(clearHold: false)
        spine.onPower = nil; spine.peer.onConnect = nil; spine.peer.onOpen = nil
        #expect(spine.episode.begin(targetID: spine.peer.camera.id,
            trigger: .operatorRetry, reason: "SIMULATED B"))
        #expect(await spine.clock.drive {
            spine.episode.snapshot.state == .idle && !spine.episode.snapshot.holdsPicture
        })
        let runID = spine.peer.owner.currentRunID
        let driver = spine.peer.currentEndpoint
        let state = spine.episode.snapshot
        let trace = spine.trace
        let native = spine.peer.trace.filter { $0 != "open returned" }
        gate.resume(); await spine.clock.settle()
        #expect(spine.episode.snapshot == state)
        #expect(spine.peer.owner.currentRunID == runID)
        #expect(spine.peer.currentEndpoint === driver)
        #expect(driver?.isClosed == false)
        #expect(spine.trace == trace)
        #expect(spine.peer.trace.filter { $0 != "open returned" } == native)
        #expect(spine.peer.trace.filter { $0 == "enable" }.count == 1)
    }

    /// SIMULATED teardown and preparation can synchronously adopt B. The captured
    /// token must be rechecked before retiring the run, closing the driver or replacing B.
    @Test(arguments: ["cleanup", "prepare", "enrich"])
    func synchronousNativeActionReplacementCannotRetireSuccessor(boundary: String) async {
        let spine = Spine(); defer { spine.finish() }
        var replaced = false
        func replace() {
            guard !replaced else { return }
            replaced = true; spine.episode.cancel(clearHold: false)
            #expect(spine.episode.begin(targetID: spine.peer.camera.id,
                trigger: .operatorRetry, reason: "SIMULATED B"))
        }
        switch boundary {
        case "cleanup": spine.onCleanup = { _, _ in replace() }
        case "prepare": spine.onPrepare = { _ in replace() }
        case "enrich": spine.onEnrich = { replace() }
        default: break
        }
        _ = spine.episode.begin(targetID: spine.peer.camera.id,
            trigger: .bleDropped, reason: "SIMULATED A")
        #expect(await spine.clock.drive {
            replaced && spine.episode.snapshot.state == .idle && !spine.episode.snapshot.holdsPicture
        })
        #expect(spine.peer.trace.filter { $0 == "GATT" }.count == 1)
        #expect(spine.peer.trace.filter { $0 == "enable" }.count == 1)
        #expect(spine.peer.currentEndpoint?.isClosed == false)
    }

    /// SIMULATED sleep deliberately ignores cancellation. A's grace deadline is older
    /// than B's: waking A at2.5 must not expose B's card before B reaches its own2.7.
    @Test func oldGraceWakeCannotPublishBeforeSuccessorsOwnDeadline() async {
        let spine = Spine(); let gate = Gate()
        defer { gate.resume(); spine.finish() }
        spine.clock.ignoresCancellation = { duration, connection in !connection && duration == .seconds(2.5) }
        spine.onPower = { await gate.wait(); return true }
        #expect(spine.episode.begin(targetID: spine.peer.camera.id,
            trigger: .bleDropped, reason: "SIMULATED A"))
        await spine.clock.settle(); #expect(gate.isWaiting)
        spine.clock.advance(to: 0.2); await spine.clock.settle()
        spine.episode.cancel(clearHold: false); spine.onPower = nil; spine.publishFresh = false
        #expect(spine.episode.begin(targetID: spine.peer.camera.id,
            trigger: .operatorRetry, reason: "SIMULATED B"))
        #expect(await spine.clock.drive { spine.peer.trace.contains("enable") })
        let id = spine.episode.currentEpisodeID
        spine.clock.advance(to: 2.5); await spine.clock.settle()
        #expect(spine.episode.currentEpisodeID == id)
        #expect(!spine.episode.snapshot.cardGraceElapsed)
        #expect(spine.episode.snapshot.holdsPicture)
        spine.clock.advance(to: 2.7); await spine.clock.settle()
        #expect(spine.episode.snapshot.cardGraceElapsed)
        spine.picture = (spine.clock.time, spine.clock.time)
        #expect(await spine.clock.drive {
            spine.episode.snapshot.state == .idle && !spine.episode.snapshot.holdsPicture
        })
        let state = spine.episode.snapshot
        gate.resume(); await spine.clock.settle()
        #expect(spine.episode.snapshot == state)
        #expect(spine.peer.trace.filter { $0 == "enable" }.count == 1)
    }

    /// SIMULATED old .5-second backoff ignores cancellation. B finishes before its wake;
    /// A must not rescan, change state or close B after that retired wait finally resumes.
    @Test func oldBackoffWakeCannotRescanOrCloseCompletedSuccessor() async {
        let spine = Spine(); defer { spine.finish() }
        spine.clock.ignoresCancellation = { duration, connection in !connection && duration == .seconds(0.5) }
        spine.gattMisses = 1
        #expect(spine.episode.begin(targetID: spine.peer.camera.id,
            trigger: .bleDropped, reason: "SIMULATED A"))
        #expect(await spine.clock.drive { spine.clock.backoffs == [0.5] })
        let oldDeadline = spine.clock.time + 0.5
        spine.clock.advance(to: spine.clock.time + 0.1); await spine.clock.settle()
        spine.episode.cancel(clearHold: false)
        #expect(spine.episode.begin(targetID: spine.peer.camera.id,
            trigger: .operatorRetry, reason: "SIMULATED B"))
        #expect(await spine.clock.drive {
            spine.episode.snapshot.state == .idle && !spine.episode.snapshot.holdsPicture
        })
        #expect(spine.clock.time < oldDeadline)
        let runID = spine.peer.owner.currentRunID
        let driver = spine.peer.currentEndpoint
        let state = spine.episode.snapshot
        let trace = spine.trace
        let native = spine.peer.trace
        spine.clock.advance(to: oldDeadline); await spine.clock.settle()
        #expect(spine.episode.snapshot == state)
        #expect(spine.peer.owner.currentRunID == runID)
        #expect(spine.peer.currentEndpoint === driver)
        #expect(driver?.isClosed == false)
        #expect(spine.trace == trace)
        #expect(spine.peer.trace == native)
    }

    /// SIMULATED transport facts. The actual ConnectionRun is supplied, and its native
    /// and discovery actions must remain untouched before owned-connection admission.
    @Test(arguments: [true, false])
    func borrowedOrUnknownCannotBeginAnyNativeRecoveryEffect(unknown: Bool) {
        let peer = DJIAppleConnectionRunTests.Peer()
        let ownership: Bool? = unknown ? nil : false
        peer.ownsConnection = ownership
        var effects: [String] = []
        let episode = DjiAppleRecoveryEpisode(connectionRun: peer.owner,
            discovery: .init(waitUntilPoweredOn: { effects.append("power"); return true },
                scan: { effects.append("scan"); return AsyncStream { $0.finish() } },
                stopScan: { effects.append("stop scan") }, enrich: { $0 }),
            native: .init(observe: { .init(ownsConnection: ownership) },
                cleanup: { _, _ in effects.append("native close") },
                scanning: { _ in effects.append("scanning") }, prepare: { _, _ in
                    effects.append("prepare"); return .cameraAccessPoint
                }), changed: { _, _ in effects.append("publish") })
        let admitted = episode.begin(targetID: peer.camera.id, trigger: .bleDropped, reason: "SIMULATED")
        #expect(!admitted)
        #expect(effects.isEmpty)
        #expect(episode.snapshot == .init())
        #expect(episode.currentEpisodeID == nil)
        #expect(peer.owner.currentRunID == nil)
        #expect(peer.trace.isEmpty)
    }

    /// SIMULATED synchronous host observation creates a same-camera successor before
    /// A's observation returns. A cannot publish or clean up that successor.
    @Test func successorDuringAdmissionObservationKeepsItsIdentity() {
        let peer = DJIAppleConnectionRunTests.Peer()
        var episode: DjiAppleRecoveryEpisode!
        var replace = true
        var published: [UUID] = []
        var cleaned: [UUID] = []
        episode = DjiAppleRecoveryEpisode(connectionRun: peer.owner,
            discovery: .init(waitUntilPoweredOn: { true }, scan: { AsyncStream { $0.finish() } },
                stopScan: {}, enrich: { $0 }),
            native: .init(observe: {
                if replace {
                    replace = false
                    #expect(episode.begin(targetID: peer.camera.id, trigger: .operatorRetry,
                        reason: "SIMULATED successor"))
                }
                return .init(ownsConnection: true)
            }, cleanup: { _, attempt in cleaned.append(attempt.id) }, scanning: { _ in },
                prepare: { _, _ in .cameraAccessPoint }),
            changed: { _, id in if let id { published.append(id) } })
        defer { episode.cancel() }
        #expect(!episode.begin(targetID: peer.camera.id, trigger: .bleDropped, reason: "SIMULATED A"))
        #expect(Set(published).count == 1)
        #expect(cleaned == Array(published.prefix(1)))
        #expect(episode.currentEpisodeID == published.first)
        #expect(episode.snapshot.targetID == peer.camera.id)
    }

    /// SIMULATED synchronous publication creates B for the same camera. The identity is
    /// installed before publication, and A must not run its native cleanup afterward.
    @Test func successorDuringInitialPublicationFencesOldCleanup() {
        let peer = DJIAppleConnectionRunTests.Peer()
        var episode: DjiAppleRecoveryEpisode!
        var replace = true
        var published: [UUID] = []
        var cleaned: [UUID] = []
        episode = DjiAppleRecoveryEpisode(connectionRun: peer.owner,
            discovery: .init(waitUntilPoweredOn: { true }, scan: { AsyncStream { $0.finish() } },
                stopScan: {}, enrich: { $0 }),
            native: .init(observe: { .init(ownsConnection: true) },
                cleanup: { _, attempt in cleaned.append(attempt.id) }, scanning: { _ in },
                prepare: { _, _ in .cameraAccessPoint }), changed: { _, id in
                    if let id { published.append(id) }
                    if replace {
                        replace = false
                        #expect(episode.currentEpisodeID == id)
                        episode.cancel(clearHold: false)
                        #expect(episode.begin(targetID: peer.camera.id, trigger: .operatorRetry,
                            reason: "SIMULATED B"))
                    }
                })
        defer { episode.cancel() }
        #expect(!episode.begin(targetID: peer.camera.id, trigger: .bleDropped, reason: "SIMULATED A"))
        #expect(Set(published).count == 2)
        #expect(published.first != published.last)
        #expect(cleaned == Array(published.suffix(1)))
        #expect(episode.currentEpisodeID == published.last)
        #expect(episode.snapshot.targetID == peer.camera.id)
    }

    @MainActor private final class Spine {
        enum NativeMiss: Error { case handshake, gatt }
        let peer = DJIAppleConnectionRunTests.Peer()
        let clock = Clock()
        var trace: [String] = []
        var stage: DjiAppleRecoveryEpisode.Stage = .other
        var picture: (source: TimeInterval?, presented: TimeInterval?) = (nil, nil)
        var handshakeMisses = 0
        var gattMisses = 0
        var advertises = true
        var publishFresh = true
        var onPower: (@MainActor () async -> Bool)?
        var onChanged: ((DjiAppleRecoveryEpisode.Snapshot, UUID?) -> Void)?
        var onCleanup: ((DjiAppleRecoveryEpisode.Cleanup, DjiAppleRecoveryEpisode.Attempt) -> Void)?
        var onPrepare: ((DjiAppleRecoveryEpisode.Attempt) -> Void)?
        var onEnrich: (() -> Void)?
        var enrichTarget: ((DJISighting) -> DJISighting)?
        private var advertisements: AsyncStream<DJISighting>.Continuation?
        lazy var episode = DjiAppleRecoveryEpisode(connectionRun: peer.owner,
            discovery: .init(waitUntilPoweredOn: { @MainActor [unowned self] in
                trace.append("power"); return await onPower?() ?? true
            },
                scan: { [unowned self] in
                    trace.append("scan")
                    let stream = AsyncStream.makeStream(of: DJISighting.self)
                    advertisements = stream.continuation
                    if advertises { stream.continuation.yield(peer.camera) }
                    return stream.stream
                }, stopScan: { [unowned self] in
                    trace.append("stop scan"); advertisements?.finish()
                }, enrich: { [unowned self] value in onEnrich?(); return enrichTarget?(value) ?? value }),
            native: .init(observe: { [unowned self] in
                .init(ownsConnection: peer.ownsConnection, stage: stage,
                    sourceAt: picture.source, presentedAt: picture.presented)
            }, cleanup: { [unowned self] kind, attempt in
                onCleanup?(kind, attempt)
                guard attempt.retireCapturedConnectionRun() else { return }
                if let endpoint = peer.currentEndpoint {
                    endpoint.close(); peer.currentEndpoint = nil
                    if case .failedAttempt = kind { trace.append("close failed endpoint") }
                }
            }, scanning: { [unowned self] _ in stage = .other }, prepare: { [unowned self] _, attempt in
                onPrepare?(attempt)
                guard attempt.isCurrent else { return nil }
                peer.result = nil; return .cameraAccessPoint
            }), timing: clock.timing, changed: { [unowned self] value, id in onChanged?(value, id) })

        init() {
            peer.cached = true
            clock.advanced = { [unowned self] in peer.advance($0 - peer.time) }
            peer.timingSleep = { [unowned self] in try await clock.pause($0, connection: true) }
            peer.onStage = { [unowned self] stage in
                self.stage = switch stage {
                case .joiningWiFi, .findingCamera: .joiningWiFi
                case .openingDatalink: .openingDatalink
                default: .other
                }
            }
            peer.onOpen = { [unowned self] in
                if handshakeMisses > 0 { handshakeMisses -= 1; throw NativeMiss.handshake }
            }
            peer.onConnect = { [unowned self] in
                if gattMisses > 0 { gattMisses -= 1; throw NativeMiss.gatt }
            }
            peer.onRegistered = { [unowned self] _ in
                stage = .live
                if publishFresh {
                    clock.schedule(.milliseconds(1)) { [unowned self] in picture = (clock.time, clock.time) }
                }
            }
        }
        func finish() {
            episode.cancel(); peer.owner.retire(); peer.exchange.stopBLEDrain(); peer.heartbeat.stop()
            clock.cancelAll(); advertisements?.finish()
        }
    }

    @MainActor private final class Gate {
        private var continuation: CheckedContinuation<Void, Never>?
        var isWaiting: Bool { continuation != nil }
        func wait() async { await withCheckedContinuation { continuation = $0 } }
        func resume() { let old = continuation; continuation = nil; old?.resume() }
    }

    @MainActor private final class Clock {
        private struct Sleeper {
            let id: UUID
            let at: Double
            let timeout: Bool
            let continuation: CheckedContinuation<Void, Error>
        }
        private let origin = ContinuousClock().now
        var time = 0.0
        var advanced: ((Double) -> Void)?
        var pauses: [(seconds: Double, connection: Bool)] = []
        var ignoresCancellation: (Duration, Bool) -> Bool = { _, _ in false }
        private var sleepers: [Sleeper] = []
        private var wakes: [(Double, () -> Void)] = []
        var backoffs: [Double] {
            pauses.filter { !$0.connection && [0.5, 1, 2, 4, 8].contains($0.seconds) }.map(\.seconds)
        }
        var timing: DjiAppleRecoveryTiming {
            .init(monotonicNow: { [unowned self] in origin.advanced(by: .seconds(time)) },
                uptime: { [unowned self] in time }, wallNow: { [unowned self] in time },
                sleep: { [unowned self] in try await pause($0) }, jitter: { 0.5 })
        }
        func schedule(_ duration: Duration, _ action: @escaping () -> Void) {
            wakes.append((time + seconds(duration), action))
        }
        func pause(_ duration: Duration, connection: Bool = false) async throws {
            try Task.checkCancellation()
            let id = UUID()
            let ignore = ignoresCancellation(duration, connection)
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    pauses.append((seconds(duration), connection))
                    sleepers.append(.init(id: id, at: time + seconds(duration),
                        timeout: !connection && seconds(duration) >= Self.timeoutSeconds,
                        continuation: continuation))
                }
            } onCancel: {
                if ignore { return }
                Task { @MainActor in
                    guard let index = self.sleepers.firstIndex(where: { $0.id == id }) else { return }
                    self.sleepers.remove(at: index).continuation.resume(throwing: CancellationError())
                }
            }
        }
        func cancelAll() {
            let pending = sleepers; sleepers.removeAll(); wakes.removeAll()
            pending.forEach { $0.continuation.resume(throwing: CancellationError()) }
        }
        func advance(to end: Double) {
            time = end; advanced?(end)
            let ready = sleepers.filter { $0.at <= end + 1e-12 }
            sleepers.removeAll { $0.at <= end + 1e-12 }
            let due = wakes.filter { $0.0 <= end + 1e-12 }; wakes.removeAll { $0.0 <= end + 1e-12 }
            ready.forEach { $0.continuation.resume() }; due.forEach { $0.1() }
        }
        /// Yields per `drive` step. A loaded suite can leave an attempt short of its next sleep
        /// after any fixed number of them.
        var yieldsPerStep = 64
        /// The episode's watchdogs: the 30 s discovery window and the 180 s total budget.
        static let timeoutSeconds = 30.0
        func settle() async { for _ in 0..<64 { await Task.yield() } }
        /// Advances to the earliest sleeper the scenario may elapse. A quiet step is not idle time:
        /// an attempt that has not yet reached its next sleep would otherwise lose the race to a
        /// watchdog. Only a scenario that expects one to fire passes `timeouts: true`.
        func drive(timeouts: Bool = false, until done: () -> Bool) async -> Bool {
            for _ in 0..<5000 {
                for _ in 0..<yieldsPerStep { await Task.yield() }
                if done() { return true }
                let due = sleepers.filter { timeouts || !$0.timeout }.map(\.at) + wakes.map(\.0)
                if let next = due.min() { advance(to: next) }
            }
            return done()
        }
        private func seconds(_ duration: Duration) -> Double {
            let value = duration.components
            return Double(value.seconds) + Double(value.attoseconds) / 1e18
        }
    }
}
