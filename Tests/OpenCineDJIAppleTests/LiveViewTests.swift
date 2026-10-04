import Foundation
import OpenCineDJI
import OpenCineDJIApple
import Testing

extension DJIAppleConnectionRunTests.Endpoint: DjiAppleLiveViewEndpoint {
    func startLiveView(receiver: UInt8) { peer.trace.append("live enable \(receiver)") }
}

@Suite @MainActor
struct DJIAppleLiveViewTests {
    /// SIMULATED peers establish authority through the real public ConnectionRun.
    @MainActor private final class Peer {
        let connection = DJIAppleConnectionRunTests.Peer()
        var run: DjiAppleConnectionRun.Attempt?
        var scope: DjiAppleLiveViewScope?
        var policy = DjiApplePictureRecoveryContext(pictureIntent: 7, ownsConnection: true)
        var wall: TimeInterval = 100
        var output = DjiAppleNativeOutputObservation(pathReady: true, playbackBlocked: false,
            presentationReady: true, awaitingIDR: false, nativeOutputExpected: true)
        var effects: [DjiAppleLiveViewNativeEffect] = []
        var frames: [Duml.Frame] = []
        var onContext: (() -> Void)?
        var onClock: (() -> Void)?
        var onEffect: ((DjiAppleLiveViewNativeEffect, DjiAppleLiveViewScope) -> Void)?
        var onOutput: (() -> Void)?
        var onPrepare: ((DjiAppleLiveViewScope) -> Void)?
        var onRebuild: ((DjiAppleLiveViewScope) -> Void)?
        var spent = true
        var events: [DjiApplePictureRecovery.Event] = []
        var onEvent: ((DjiApplePictureRecovery.Event, DjiAppleLiveViewScope) -> Void)?
        var monotonic: TimeInterval = 200
        var waits: [(Duration, CheckedContinuation<Void, Never>)] = []
        lazy var owner = DjiApplePictureRecovery(connectionRun: connection.owner,
            context: { [unowned self] in
                var snapshot = policy
                snapshot.endpointIdentity = connection.currentEndpoint.map(ObjectIdentifier.init)
                onContext?(); return snapshot
            }, native: .init(prepare: { [unowned self] in wall },
                prepareScoped: { [unowned self] scope in onPrepare?(scope); return wall },
                enable: {}, probe: {}, picture: { [unowned self] _, _ in output.picture }),
            liveViewNative: .init(observeOutput: { [unowned self] _, _ in
                let snapshot = output; onOutput?(); return snapshot
            }, perform: { [unowned self] effect, scope in
                effects.append(effect); onEffect?(effect, scope)
            }, rebuildOutput: { [unowned self] _, scope in onRebuild?(scope); return spent }),
            timing: .init(wallNow: { [unowned self] in onClock?(); return wall },
                monotonicNow: { [unowned self] in monotonic }, wait: { [unowned self] duration in
                    await withCheckedContinuation { waits.append((duration, $0)) }
                }), event: { [unowned self] event, scope in
                    events.append(event); onEvent?(event, scope)
                })
        func connect(recipe: DjiAppleLiveViewRecipe = .prepared) async {
            connection.cached = true; connection.result = nil; connection.onSend = nil
            connection.onPrepare = { [unowned self] attempt in
                run = attempt; scope = owner.prepareLiveViewSource(run: attempt, recipe: recipe)
            }
            connection.onRegistered = { [unowned self] _ in
                guard let endpoint = connection.currentEndpoint as? DJIAppleConnectionRunTests.Endpoint,
                    let scope else { Issue.record("SIMULATED source did not capture real run"); return }
                #expect(owner.bindLiveView(endpoint: endpoint, recovery: recoveryEndpoint(endpoint), scope: scope))
            }
            connection.owner.replace(target: connection.camera, setup: .cameraWiFi)
            await connection.finished()
            connection.onSend = { [unowned self] frame in frames.append(frame); return true }
            connection.trace = []; frames = []; effects = []
        }
        func recoveryEndpoint(_ endpoint: DJIAppleConnectionRunTests.Endpoint,
            identity: ObjectIdentifier? = nil) -> DjiApplePictureRecoveryEndpoint {
            .init(identity: identity ?? ObjectIdentifier(endpoint), negotiate: { [unowned self] _ in
                connection.trace.append("live negotiate")
            }, transport: { .init(closed: endpoint.isClosed) })
        }
        func settle() async { for _ in 0..<100 { await Task.yield() } }
        func wake(_ index: Int = 0, after duration: TimeInterval) async {
            wall += duration; monotonic += duration
            let continuation = waits.remove(at: index).1
            continuation.resume(); await settle()
        }
        func retire() {
            owner.cancel(); waits.forEach { $0.1.resume() }; waits = []; connection.owner.retire()
            connection.exchange.stopBLEDrain(); connection.heartbeat.stop()
        }
        var enables: [String] { connection.trace.filter { $0.hasPrefix("live enable") } }
    }

    @Test(arguments: [DjiAppleLiveViewRecipe.prepared, .gated, .direct, .legacyUnresolved, .uncaptured])
    func capturedRecipesKeepCoherentWireOrderAndDoNotSpendHistory(recipe: DjiAppleLiveViewRecipe) async {
        let peer = Peer(); defer { peer.retire() }
        await peer.connect(recipe: recipe)
        let result = peer.owner.requestLiveView(.capturedRecipe, reason: "SIMULATED recipe")
        let commands = peer.frames.map { [$0.cmdSet, $0.cmdId] }
        switch recipe {
        case .prepared, .legacyUnresolved:
            #expect(commands == [[0x02, 0x68]])
            #expect(peer.enables == ["live enable 8"])
        case .gated:
            #expect(commands == [[0x02, 0x09]])
            #expect(peer.enables == ["live enable 65"])
        case .direct:
            #expect(commands.isEmpty); #expect(peer.enables == ["live enable 65"])
        case .uncaptured:
            #expect(result == .blocked(.uncaptured))
            #expect(commands.isEmpty); #expect(peer.enables.isEmpty)
        }
        #expect(peer.owner.liveViewHistory.locallyAcceptedEnables == 0)
        #expect(peer.owner.liveViewHistory.lastAcceptedEnableWallTime == .distantPast)
        #expect(!peer.owner.liveViewHistory.gateInFlight)
    }

    @Test(arguments: [true, false])
    func borrowedAndUnknownAuthorityRefuseBeforeEffectsOrSourceReset(unknown: Bool) async {
        let peer = Peer(); defer { peer.retire() }
        await peer.connect()
        _ = peer.owner.requestLiveView(.initial(pathProven: true, displayAttached: false), reason: "SIMULATED")
        let before = peer.owner.liveViewHistory
        peer.effects = []; peer.frames = []; peer.connection.trace = []
        peer.policy.ownsConnection = unknown ? nil : false
        #expect(peer.owner.requestLiveView(.recover(force: true), reason: "SIMULATED borrowed")
            == .blocked(.unavailableOwnership))
        #expect(peer.owner.prepareLiveViewSource(run: peer.run!, recipe: .direct) == nil)
        #expect(peer.owner.liveViewHistory == before)
        #expect(peer.effects.isEmpty && peer.frames.isEmpty && peer.enables.isEmpty)
    }

    @Test func mismatchedRecoveryDescriptorRefusesWithoutRetiringCurrentBinding() async {
        let peer = Peer(); defer { peer.retire() }
        await peer.connect()
        let endpoint = peer.connection.currentEndpoint as! DJIAppleConnectionRunTests.Endpoint
        let other = NSObject()
        #expect(!peer.owner.bindLiveView(endpoint: endpoint,
            recovery: peer.recoveryEndpoint(endpoint, identity: ObjectIdentifier(other)), scope: peer.scope!))
        _ = peer.owner.requestLiveView(.initial(pathProven: true, displayAttached: true), reason: "SIMULATED")
        #expect(peer.enables.count == 1)
        #expect(peer.owner.liveViewHistory.locallyAcceptedEnables == 1)
    }

    @Test func overlappingRecoverKeepsPolicyBeforeGateRefusalWithoutRetiringAcceptedOperation() async {
        let peer = Peer(); defer { peer.retire() }
        await peer.connect()
        var order: [String] = []
        var overlapped = false
        peer.onEffect = { effect, _ in
            switch effect {
            case .prepareRecover: order.append("B policy and native cleanup")
            case .requestFinished(_, let reason, let outcome) where reason == "SIMULATED overlapping B":
                #expect(outcome == .blocked(.overlap))
                order.append("B occupied gate refusal")
            case .holdPicture: order.append("A hold")
            default: break
            }
        }
        peer.connection.onSend = { frame in
            peer.frames.append(frame)
            guard !overlapped else { return true }
            overlapped = true
            let before = peer.owner.liveViewHistory
            #expect(before.gateInFlight)
            order.append("A preparation write")
            #expect(peer.owner.requestLiveView(.recover(force: true),
                reason: "SIMULATED overlapping B") == .blocked(.overlap))
            #expect(peer.owner.liveViewHistory == before,
                "B cannot clear A's gate or spend A's history")
            return true
        }
        let result = peer.owner.requestLiveView(.initial(pathProven: true, displayAttached: true),
            reason: "SIMULATED A")
        #expect(overlapped)
        #expect(order == ["A preparation write", "B policy and native cleanup", "B occupied gate refusal", "A hold"])
        #expect(peer.enables == ["live enable 8"])
        #expect(peer.frames.map { [$0.cmdSet, $0.cmdId] } == [[0x02, 0x68]])
        #expect(peer.owner.liveViewHistory.locallyAcceptedEnables == 1)
        #expect(peer.owner.liveViewHistory.idrHoldEnableCount == 1)
        #expect(!peer.owner.liveViewHistory.gateInFlight)
        #expect(result == .locallyAccepted(peer.owner.liveViewHistory))
    }

    @Test func endpointPreparationKeepsWallHistoryWhileNewSourceResetsIt() async {
        let peer = Peer(); defer { peer.retire() }
        await peer.connect()
        _ = peer.owner.requestLiveView(.initial(pathProven: true, displayAttached: true), reason: "SIMULATED")
        var prepared: TimeInterval?
        #expect(peer.owner.start { attempt in prepared = attempt.prepareReplacementEndpoint() })
        await peer.settle()
        #expect(prepared == 100)
        #expect(peer.owner.liveViewHistory.locallyAcceptedEnables == 0)
        #expect(!peer.owner.liveViewHistory.initialAccepted)
        #expect(peer.owner.liveViewHistory.lastAcceptedEnableWallTime == Date(timeIntervalSinceReferenceDate: 100))
        await peer.connect()
        #expect(peer.owner.liveViewHistory.lastAcceptedEnableWallTime == .distantPast)
    }

    @Test func uncapturedInitialPolicyCompletionIsNotWireReceiptOrAcceptedHistory() async {
        let peer = Peer(); defer { peer.retire() }
        await peer.connect(recipe: .uncaptured)
        peer.output.picture.fresh = true
        let endpoint = peer.connection.currentEndpoint as! DJIAppleConnectionRunTests.Endpoint
        var result: DjiApplePictureRecovery.Result?
        #expect(peer.owner.start { attempt in
            result = await attempt.repairEndpoint(peer.recoveryEndpoint(endpoint),
                reason: "SIMULATED uncaptured repair", pictureIntent: 7, timeout: .seconds(1))
        })
        await peer.settle()
        #expect(result == .restored, "Fresh picture is independently supplied by the native source observation")
        #expect(peer.events == [.admitted, .endpointInitialPolicyCompleted, .restored, .released])
        #expect(peer.frames.isEmpty && peer.enables.isEmpty)
        #expect(!peer.owner.liveViewHistory.initialAccepted)
        #expect(peer.owner.liveViewHistory.locallyAcceptedEnables == 0)
        #expect(peer.owner.liveViewHistory.lastAcceptedEnableWallTime == .distantPast)
    }

    @Test func nativeReadinessDeadlineUsesExactlySixtyFour250msWaitsAndNoEnable() async {
        let peer = Peer(); defer { peer.retire() }
        await peer.connect(); peer.output.presentationReady = false
        var result: DjiAppleNativeOutputResult?
        #expect(peer.owner.start { attempt in
            result = await attempt.repairNativeOutput(referenceLossOnly: true, pictureIntent: 7)
        })
        await peer.settle()
        for index in 0..<64 {
            #expect(result == nil)
            #expect(peer.waits.count == 1)
            guard peer.waits.count == 1 else { return }
            #expect(peer.waits[0].0 == .milliseconds(250))
            await peer.wake(after: 0.25)
            if index == 62 { #expect(peer.owner.isBusy) }
        }
        #expect(result == .blockedReadiness)
        #expect(peer.wall == 116)
        #expect(peer.enables.isEmpty)
        #expect(peer.events == [.admitted, .released])
    }

    @Test func twoUnansweredRequestsUseForty100msWaitsThenActualEndpointDescriptor() async {
        let peer = Peer(); defer { peer.retire() }
        peer.wall = 0
        await peer.connect(); peer.output.awaitingIDR = true
        var result: DjiAppleNativeOutputResult?
        #expect(peer.owner.start { attempt in
            result = await attempt.repairNativeOutput(referenceLossOnly: true, pictureIntent: 7)
        })
        await peer.settle()
        #expect(peer.enables.count == 1)
        for index in 0..<40 {
            guard peer.waits.count == 1 else { Issue.record("SIMULATED lost native wait"); return }
            #expect(peer.waits[0].0 == .milliseconds(100))
            await peer.wake(after: 0.1)
            if index == 18 { #expect(peer.enables.count == 1) }
            if index == 19 { #expect(peer.enables.count == 2) }
            if index == 38 { #expect(!peer.connection.trace.contains("live negotiate")) }
        }
        #expect(peer.connection.trace.filter { $0 == "live negotiate" }.count == 1)
        #expect(peer.enables.count == 3)
        #expect(peer.owner.liveViewHistory.locallyAcceptedEnables == 1)
        #expect(peer.owner.liveViewHistory.initialAccepted)
        #expect(result == nil, "Endpoint picture wait remains actual and separate")
    }

    @Test func canceled250msWakeCannotReleaseYoungerSameRunRepairOrHistory() async {
        let peer = Peer(); defer { peer.retire() }
        await peer.connect(); peer.output.presentationReady = false
        var a: DjiAppleNativeOutputResult?
        var b: DjiAppleNativeOutputResult?
        #expect(peer.owner.start { attempt in a = await attempt.repairNativeOutput(referenceLossOnly: true, pictureIntent: 7) })
        await peer.settle()
        peer.owner.cancel()
        #expect(peer.owner.start { attempt in b = await attempt.repairNativeOutput(referenceLossOnly: true, pictureIntent: 7) })
        await peer.settle()
        #expect(peer.waits.count == 2)
        await peer.wake(after: 0.25) // Deliberately resume A despite cancellation.
        #expect(a == .superseded && b == nil)
        #expect(peer.owner.isBusy)
        #expect(peer.events == [.admitted, .admitted])
        peer.output.presentationReady = true; peer.output.picture.fresh = true
        await peer.wake(after: 0.25)
        #expect(b == .restored)
        #expect(peer.enables.count == 1)
        #expect(peer.owner.liveViewHistory.locallyAcceptedEnables == 1)
        #expect(peer.events == [.admitted, .admitted, .released])
    }

    @Test func releasedEventCannotRetireOrReleaseItsSynchronousSuccessor() async {
        let peer = Peer(); defer { peer.retire() }
        await peer.connect(); peer.output.presentationReady = false
        var oldCompletion: DjiAppleLiveViewScope?
        peer.onEvent = { event, scope in
            guard event == .released else { return }
            peer.onEvent = nil; oldCompletion = scope
            #expect(scope.isCurrent)
            #expect(peer.owner.start { attempt in
                _ = await attempt.repairNativeOutput(referenceLossOnly: true, pictureIntent: 7)
            })
            #expect(!scope.isCurrent)
        }
        #expect(peer.owner.start { _ in })
        await peer.settle()
        #expect(oldCompletion != nil)
        #expect(peer.owner.isBusy)
        #expect(peer.events == [.admitted, .released, .admitted])
    }

    @Test func nilFactoryKeepsUnknownModelAndLegacyRecipeOnRealPublicRun() async {
        let peer = Peer(); defer { peer.retire() }
        let observedModel: CameraModel? = nil
        await peer.connect(recipe: .captured(from: observedModel))
        #expect(peer.run?.isCurrent == true)
        #expect(peer.scope?.isCurrent == true)
        #expect(observedModel == nil)
        #expect(peer.owner.requestLiveView(.capturedRecipe, reason: "SIMULATED nil observation")
            != .blocked(.uncaptured))
        #expect(peer.frames.map { [$0.cmdSet, $0.cmdId] } == [[2, 0x68]])
        #expect(peer.frames.map(\.payload) == [[8]])
        #expect(peer.enables == ["live enable 8"])
        #expect(observedModel == nil)
    }

    @Test func typedRawMediaExceptionDoesNotSpendFullMediaReturnHistory() async {
        let peer = Peer(); defer { peer.retire() }
        await peer.connect(); peer.policy.browsingMedia = true
        #expect(peer.owner.requestLiveView(.capturedRecipe, reason: "SIMULATED ordinary") == .blocked(.mediaBrowsing))
        _ = peer.owner.requestLiveView(.capturedMediaReturnRecipe, reason: "SIMULATED typed raw exception")
        #expect(peer.enables.count == 1)
        #expect(peer.owner.liveViewHistory.locallyAcceptedEnables == 0)
        #expect(peer.owner.liveViewHistory.lastAcceptedEnableWallTime == .distantPast)
        _ = peer.owner.requestLiveView(.mediaReturn, reason: "SIMULATED actual return")
        #expect(peer.enables.count == 2)
        #expect(peer.owner.liveViewHistory.initialAccepted)
        #expect(peer.owner.liveViewHistory.idrHoldEnableCount == 1)
        #expect(peer.owner.liveViewHistory.locallyAcceptedEnables == 1)
    }

    @Test func retiredRunLocalHistoryCanResetButOldSourceCannotClearReplacement() async {
        let peer = Peer(); defer { peer.retire() }
        await peer.connect()
        let a = peer.scope!
        _ = peer.owner.requestLiveView(.initial(pathProven: true, displayAttached: true), reason: "SIMULATED A")
        peer.connection.owner.retire()
        #expect(!a.isCurrent)
        peer.owner.retireLiveView(scope: a)
        #expect(peer.owner.liveViewHistory.locallyAcceptedEnables == 0)
        #expect(peer.owner.liveViewHistory.lastAcceptedEnableWallTime == Date(timeIntervalSinceReferenceDate: 100))
        await peer.connect()
        _ = peer.owner.requestLiveView(.initial(pathProven: true, displayAttached: true), reason: "SIMULATED B")
        peer.owner.retireLiveView(scope: a)
        #expect(peer.owner.liveViewHistory.locallyAcceptedEnables == 1)
        #expect(peer.scope?.isCurrent == true)
    }

    @Test func explicitReplacementBindingRetiresOldEffectScopeAndKeepsRealAttemptCurrent() async {
        let peer = Peer(); defer { peer.retire() }
        await peer.connect()
        let endpoint = peer.connection.currentEndpoint as! DJIAppleConnectionRunTests.Endpoint
        var before: DjiAppleLiveViewScope?
        peer.onEvent = { event, scope in
            if event == .admitted { before = scope }
        }
        var bound = false
        var currentAfter = false
        #expect(peer.owner.start { attempt in
            bound = attempt.bindReplacementLiveView(endpoint, recovery: peer.recoveryEndpoint(endpoint))
            currentAfter = attempt.isCurrent
        })
        await peer.settle()
        #expect(bound && currentAfter)
        #expect(before?.isCurrent == false)
        #expect(peer.events == [.admitted, .released])
    }

    @Test func late100msWakeCannotSpendOrReleaseYoungerSameRunRepair() async {
        let peer = Peer(); defer { peer.retire() }
        await peer.connect()
        var a: DjiAppleNativeOutputResult?
        var b: DjiAppleNativeOutputResult?
        #expect(peer.owner.start { attempt in a = await attempt.repairNativeOutput(referenceLossOnly: true, pictureIntent: 7) })
        await peer.settle()
        #expect(peer.waits.first?.0 == .milliseconds(100))
        peer.owner.cancel()
        #expect(peer.owner.start { attempt in b = await attempt.repairNativeOutput(referenceLossOnly: true, pictureIntent: 7) })
        await peer.settle()
        #expect(peer.owner.liveViewHistory.locallyAcceptedEnables == 2)
        await peer.wake(after: 0.1)
        #expect(a == .superseded && b == nil)
        #expect(peer.owner.isBusy)
        #expect(peer.owner.liveViewHistory.locallyAcceptedEnables == 2)
        #expect(peer.events == [.admitted, .admitted])
        peer.output.picture.fresh = true
        await peer.wake(after: 0.1)
        #expect(b == .restored)
        #expect(peer.events == [.admitted, .admitted, .released])
    }

    @Test func initialDisplayFallbackAndWallCooldownPreserveLocalAcceptance() async {
        let peer = Peer(); defer { peer.retire() }
        await peer.connect()
        _ = peer.owner.requestLiveView(.initial(pathProven: false, displayAttached: false), reason: "SIMULATED")
        #expect(peer.owner.liveViewHistory.initialAccepted)
        #expect(peer.owner.liveViewHistory.locallyAcceptedEnables == 1)
        #expect(peer.owner.liveViewHistory.idrHoldEnableCount == 1)
        #expect(peer.owner.requestLiveView(.initial(pathProven: true, displayAttached: true), reason: "SIMULATED")
            == .blocked(.alreadyAccepted))
        peer.wall = 104.999
        #expect(peer.owner.requestLiveView(.recover(force: false), reason: "SIMULATED") == .blocked(.cooldown))
        peer.wall = 105
        _ = peer.owner.requestLiveView(.recover(force: false), reason: "SIMULATED")
        #expect(peer.owner.liveViewHistory.locallyAcceptedEnables == 2)
        peer.wall = 105.1
        _ = peer.owner.requestLiveView(.recover(force: true), reason: "SIMULATED")
        #expect(peer.owner.liveViewHistory.locallyAcceptedEnables == 3)
        #expect(peer.enables.count == 3)
        #expect(!peer.owner.liveViewHistory.gateInFlight)
    }

    @Test func replacementInsidePrepareSendCannotEnableOrSpendSuccessorsHistory() async {
        let peer = Peer(); defer { peer.retire() }
        await peer.connect()
        let a = peer.scope!
        peer.connection.onSend = { frame in
            peer.frames.append(frame)
            peer.connection.onSend = nil
            peer.connection.owner.replace(target: peer.connection.camera, setup: .cameraWiFi)
            return true
        }
        #expect(peer.owner.requestLiveView(.initial(pathProven: true, displayAttached: true), reason: "SIMULATED A")
            == .superseded)
        #expect(!a.isCurrent)
        #expect(peer.enables.isEmpty)
        peer.connection.result = nil
        await peer.connection.finished()
        #expect(peer.scope?.isCurrent == true)
        #expect(peer.owner.liveViewHistory.lastAcceptedEnableWallTime == .distantPast)
        #expect(peer.owner.liveViewHistory.locallyAcceptedEnables == 0)
        #expect(!peer.owner.liveViewHistory.gateInFlight)
    }

    @Test func canceledGateCannotFinishOrClearNestedSuccessorOnSameRealRun() async {
        let peer = Peer(); defer { peer.retire() }
        await peer.connect()
        var oldEffect: DjiAppleLiveViewScope?
        peer.onEffect = { effect, scope in
            guard case .prepareRecover = effect else { return }
            peer.onEffect = nil; oldEffect = scope
            peer.owner.cancel()
            _ = peer.owner.requestLiveView(.initial(pathProven: true, displayAttached: true), reason: "SIMULATED B")
        }
        #expect(peer.owner.requestLiveView(.recover(force: true), reason: "SIMULATED A") == .superseded)
        #expect(oldEffect?.isCurrent == false)
        #expect(peer.scope?.isCurrent == true)
        #expect(peer.owner.liveViewHistory.locallyAcceptedEnables == 1)
        #expect(peer.enables.count == 1)
        #expect(!peer.owner.liveViewHistory.gateInFlight)
    }

    @Test func clockOrObservationReentryCannotCommitOldHistory() async {
        for boundary in ["clock", "output", "context"] {
            let peer = Peer(); defer { peer.retire() }
            await peer.connect()
            let retire = {
                peer.onClock = nil; peer.onOutput = nil; peer.onContext = nil
                peer.connection.owner.replace(target: peer.connection.camera, setup: .cameraWiFi)
            }
            switch boundary {
            case "clock": peer.onClock = retire
            case "output": peer.onOutput = retire
            default: peer.onContext = retire
            }
            #expect(peer.owner.requestLiveView(.recover(force: false), reason: "SIMULATED A") == .superseded)
            #expect(peer.enables.isEmpty)
            #expect(peer.owner.liveViewHistory.locallyAcceptedEnables == 0)
        }
    }
}
