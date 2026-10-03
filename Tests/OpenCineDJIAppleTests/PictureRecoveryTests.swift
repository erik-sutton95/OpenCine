import Foundation
import OpenCineDJIApple
import Testing

@Suite @MainActor
struct DJIApplePictureRecoveryTests {
    /// SIMULATED transport and native picture facts, with manually resumed waits.
    @MainActor private final class Peer {
        let identity = NSObject()
        var time: TimeInterval = 100
        var transport = DjiApplePictureRecoveryTransport()
        var policy = DjiApplePictureRecoveryContext(pictureIntent: 7)
        var endpointPresent = true
        var fresh = false
        var presented: TimeInterval?
        var trace: [String] = []
        var events: [DjiApplePictureRecovery.Event] = []
        var result: DjiApplePictureRecovery.Result?
        var waits: [(TimeInterval, CheckedContinuation<Void, Never>)] = []
        var negotiation: ((String) async throws -> Void)?
        var probeEffect: (() -> Void)?
        var wallEffect: (() -> Void)?
        var transportEffect: (() -> Void)?
        var eventEffect: ((DjiApplePictureRecovery.Event) -> Void)?
        lazy var owner = DjiApplePictureRecovery(context: { [unowned self] in
            var current = policy
            current.endpointIdentity = endpointPresent
                ? policy.endpointIdentity ?? ObjectIdentifier(identity) : nil
            return current
        }, native: .init(prepare: { [unowned self] in
            trace += ["gimbal", "prepare"]
            return time
        }, enable: { [unowned self] in trace.append("enable") },
            probe: { [unowned self] in
                trace.append("probe")
                probeEffect?()
            },
            picture: { [unowned self] _, _ in .init(fresh: fresh, lastPresentedAt: presented) }),
            timing: .init(wallNow: { [unowned self] in
                wallEffect?()
                return time
            },
                monotonicNow: { [unowned self] in time }, wait: { [unowned self] duration in
                    let c = duration.components
                    await withCheckedContinuation {
                        waits.append((time + Double(c.seconds) + Double(c.attoseconds) / 1e18, $0))
                    }
                }), event: { [unowned self] in
                    events.append($0)
                    eventEffect?($0)
                })
        var endpoint: DjiApplePictureRecoveryEndpoint {
            .init(identity: ObjectIdentifier(identity),
                negotiate: { [unowned self] reason in
                    trace.append("negotiate")
                    try await negotiation?(reason)
                },
                transport: { [unowned self] in
                    transportEffect?()
                    return transport
                })
        }
        func start(timeout: Duration = .seconds(16)) {
            let admitted = owner.start { [self] attempt in
                result = await attempt.repairEndpoint(endpoint, reason: "SIMULATED",
                    pictureIntent: 7, timeout: timeout)
            }
            #expect(admitted)
        }
        func settle() async { for _ in 0..<100 { await Task.yield() } }
        func advance(to deadline: TimeInterval) async {
            time = deadline
            let due = waits.filter { $0.0 <= deadline + 1e-9 }
            waits.removeAll { $0.0 <= deadline + 1e-9 }
            due.forEach { $0.1.resume() }
            await settle()
        }
    }

    @Test func simulatedMediaRetiresOnlyPictureIntentWhileRealNegotiationFailureStillEscalates() async {
        enum Failure: Error { case handshake }
        for fails in [false, true] {
            let peer = Peer()
            var negotiation: CheckedContinuation<Void, Error>?
            peer.negotiation = { _ in try await withCheckedThrowingContinuation { negotiation = $0 } }
            peer.start()
            await peer.settle()
            #expect(negotiation != nil)
            peer.policy.browsingMedia = true
            peer.policy.pictureIntent = 8
            peer.policy.browsingMedia = false
            peer.policy.pictureIntent = 9
            if fails { negotiation?.resume(throwing: Failure.handshake) }
            else { negotiation?.resume() }
            await peer.settle()
            #expect(peer.trace == ["gimbal", "prepare", "negotiate"])
            #expect(peer.result == (fails ? .exhausted : .superseded))
            #expect(peer.events == (fails ? [.admitted, .negotiationFailed(reason: "SIMULATED"), .released]
                : [.admitted, .released]))
            #expect(!peer.transport.closed, "Changing picture intent does not close transport")
        }
    }

    @Test func simulatedCanceledPictureWakeCannotReleaseOrPublishItsYoungerSuccessor() async {
        let peer = Peer()
        var a: DjiApplePictureRecovery.Result?
        var b: DjiApplePictureRecovery.Result?
        let first = peer.owner.start { attempt in
            a = await attempt.repairEndpoint(peer.endpoint, reason: "SIMULATED A",
                pictureIntent: 7, timeout: .seconds(16))
        }
        #expect(first)
        await peer.settle()
        peer.owner.cancel()
        await peer.advance(to: 100.05)
        let second = peer.owner.start { attempt in
            b = await attempt.repairEndpoint(peer.endpoint, reason: "SIMULATED B",
                pictureIntent: 7, timeout: .seconds(16))
        }
        #expect(second)
        await peer.settle()
        await peer.advance(to: 100.1) // A's canceled manual wait deliberately resumes.
        #expect(a == .superseded)
        #expect(b == nil)
        #expect(peer.owner.isBusy)
        #expect(peer.events == [.admitted, .admitted])
        peer.fresh = true
        await peer.advance(to: 100.15)
        #expect(b == .restored)
        #expect(peer.events == [.admitted, .admitted, .restored, .released])
    }

    @Test func simulatedHeldCycleHistorySurvivesLocalCancelAndThirdDeadlineEscalates() async {
        let peer = Peer()
        let expected: [DjiApplePictureRecovery.Event] = [
            .holdForWatchdog(cycles: 1), .holdForWatchdog(cycles: 2), .escalateSession]
        for disposition in expected {
            peer.transport.lastVideoPacketAt = peer.time
            peer.start(timeout: .zero)
            await peer.settle()
            #expect(peer.result == .exhausted)
            #expect(peer.events.suffix(2) == [disposition, .released])
            peer.owner.cancel()
            await peer.advance(to: peer.time + 1)
        }
    }

    @Test func simulatedActualPresentationSincePreviousHoldStartsANewHeldEpisode() async {
        let peer = Peer()
        for _ in 0..<3 {
            peer.transport.lastVideoPacketAt = peer.time
            peer.presented = peer.time - 0.5
            peer.start(timeout: .zero)
            await peer.settle()
            #expect(peer.events.suffix(2) == [.holdForWatchdog(cycles: 1), .released])
            await peer.advance(to: peer.time + 1)
        }
    }

    @Test func simulatedReplacementDuringNegotiationSuppressesBothLateSuccessAndFailure() async {
        enum Failure: Error { case oldEndpoint }
        for fails in [false, true] {
            let peer = Peer()
            let replacement = NSObject()
            var negotiated: CheckedContinuation<Void, Error>?
            peer.negotiation = { _ in try await withCheckedThrowingContinuation { negotiated = $0 } }
            peer.start()
            await peer.settle()
            peer.policy.endpointIdentity = ObjectIdentifier(replacement)
            if fails { negotiated?.resume(throwing: Failure.oldEndpoint) }
            else { negotiated?.resume() }
            await peer.settle()
            #expect(peer.result == .superseded)
            #expect(peer.events == [.admitted, .released])
            #expect(peer.trace == ["gimbal", "prepare", "negotiate"])
        }
    }

    @Test func simulatedNativeProbeRetirementCannotWaitOrEscalateTheRetiredAttempt() async {
        let peer = Peer()
        var successor: CheckedContinuation<Void, Never>?
        peer.probeEffect = {
            peer.owner.cancel()
            let admitted = peer.owner.start { _ in
                await withCheckedContinuation { successor = $0 }
            }
            #expect(admitted)
        }
        peer.start()
        await peer.settle()
        #expect(peer.result == .superseded)
        #expect(peer.waits.isEmpty, "A native callback retired the owner before a wait was scheduled")
        #expect(peer.owner.isBusy)
        #expect(peer.events == [.admitted, .admitted])
        successor?.resume()
        await peer.settle()
        #expect(peer.events == [.admitted, .admitted, .released])
    }

    @Test func simulatedUnknownEndpointAuthorityDoesNotPrepareNegotiateOrEnable() async {
        let peer = Peer()
        peer.endpointPresent = false
        peer.start(timeout: .zero)
        await peer.settle()
        #expect(peer.result == .superseded)
        #expect(peer.trace.isEmpty)
        #expect(peer.events == [.admitted, .released])
    }

    @Test func simulatedCurrentClosedDriverRetainsNativePreparationWithoutEnablingPicture() async {
        let peer = Peer()
        peer.transport.closed = true
        peer.start(timeout: .zero)
        await peer.settle()
        #expect(peer.trace == ["gimbal", "prepare", "negotiate"],
            "Donor cleanup precedes rebuildUDP, whose closed-driver path sends nothing")
        #expect(peer.result == .superseded)
        #expect(peer.events == [.admitted, .released])
    }

    @Test func simulatedDeadlineTransportReadCannotSpendItsSuccessorsHeldCycle() async {
        let peer = Peer()
        peer.transport.lastVideoPacketAt = peer.time
        var wallReads = 0
        var successorReady: CheckedContinuation<Void, Never>?
        var successorResult: DjiApplePictureRecovery.Result?
        peer.wallEffect = {
            wallReads += 1
            // After the picture sample, the deadline samples wall time for packet age.
            guard wallReads == 2 else { return }
            peer.transportEffect = {
                peer.transportEffect = nil
                peer.owner.cancel()
                let admitted = peer.owner.start { attempt in
                    await withCheckedContinuation { successorReady = $0 }
                    successorResult = await attempt.repairEndpoint(peer.endpoint,
                        reason: "SIMULATED B", pictureIntent: 7, timeout: .zero)
                }
                #expect(admitted)
            }
        }
        peer.start(timeout: .zero)
        await peer.settle()
        #expect(peer.result == .superseded)
        #expect(peer.owner.isBusy, "A's completion cannot release B's suspended attempt")
        #expect(peer.events == [.admitted, .admitted], "The stale snapshot authorizes no deadline event")
        successorReady?.resume()
        await peer.settle()
        #expect(successorResult == .exhausted)
        #expect(peer.events == [.admitted, .admitted, .holdForWatchdog(cycles: 1), .released],
            "Retired A must not spend B's first held cycle")
    }

    @Test func simulatedRecoveryEventRetirementReturnsSupersededWithoutReleasingSuccessor() async {
        let dispositions: [DjiApplePictureRecovery.Event] = [
            .restored, .holdForWatchdog(cycles: 1), .escalateSession]
        for disposition in dispositions {
            let peer = Peer()
            peer.fresh = disposition == .restored
            peer.transport.lastVideoPacketAt = disposition == .escalateSession ? nil : peer.time
            var successorReady: CheckedContinuation<Void, Never>?
            peer.eventEffect = { event in
                guard event == disposition else { return }
                peer.eventEffect = nil
                peer.owner.cancel()
                let admitted = peer.owner.start { _ in
                    await withCheckedContinuation { successorReady = $0 }
                }
                #expect(admitted)
            }
            peer.start(timeout: .zero)
            await peer.settle()
            #expect(peer.result == .superseded)
            #expect(peer.owner.isBusy)
            #expect(peer.events == [.admitted, disposition, .admitted])
            successorReady?.resume()
            await peer.settle()
            #expect(peer.events == [.admitted, disposition, .admitted, .released])
        }
    }

    @Test func simulatedTransportAuthorityReadCannotEnableRetiredOrReplacedEndpoint() async {
        for replacement in [false, true] {
            let peer = Peer()
            let nextIdentity = NSObject()
            var successorReady: CheckedContinuation<Void, Never>?
            peer.transportEffect = {
                peer.transportEffect = nil
                if replacement {
                    peer.policy.endpointIdentity = ObjectIdentifier(nextIdentity)
                } else {
                    peer.owner.cancel()
                    let admitted = peer.owner.start { _ in
                        await withCheckedContinuation { successorReady = $0 }
                    }
                    #expect(admitted)
                }
            }
            peer.start(timeout: .zero)
            await peer.settle()
            #expect(peer.result == .superseded)
            #expect(peer.trace == ["gimbal", "prepare", "negotiate"])
            #expect(peer.events == (replacement ? [.admitted, .released] : [.admitted, .admitted]))
            #expect(peer.owner.isBusy == !replacement)
            successorReady?.resume()
            await peer.settle()
            #expect(!peer.owner.isBusy)
        }
    }

    @Test func simulatedRetiredMediaReturnCannotClaimAfterItsCanceledWaitResumes() async {
        for retirement in ["newIntent", "browse", "hold", "session", "cancel"] {
            let peer = Peer()
            var negotiation: CheckedContinuation<Void, Never>?
            let admitted = peer.owner.start { _ in
                await withCheckedContinuation { negotiation = $0 }
            }
            #expect(admitted)
            await peer.settle()
            var claims = 0
            let returning = Task {
                await peer.owner.claim(pictureIntent: 7) { _ in claims += 1 }
            }
            await peer.settle()
            switch retirement {
            case "newIntent": peer.policy.pictureIntent = 8
            case "browse": peer.policy.browsingMedia = true
            case "hold": peer.policy.holdsMonitor = true
            case "session": peer.policy.sessionRecovering = true
            default: returning.cancel()
            }
            negotiation?.resume()
            await peer.advance(to: 100.1)
            #expect(await returning.value == false)
            #expect(claims == 0)
            #expect(peer.events == [.admitted, .released])
            #expect(!peer.owner.isBusy)
        }
    }

    @Test func simulatedMediaReturnQueuesBehindNilDriverNegotiationAndClaimsOnce() async {
        let peer = Peer()
        peer.endpointPresent = false
        var negotiation: CheckedContinuation<Void, Never>?
        let admitted = peer.owner.start { _ in
            await withCheckedContinuation { negotiation = $0 }
        }
        #expect(admitted)
        await peer.settle()
        var claims = 0
        var claimed: Bool?
        let returning = Task {
            claimed = await peer.owner.claim(pictureIntent: 7) { _ in claims += 1 }
        }
        await peer.settle()
        #expect(claimed == nil, "A missing driver must not erase the in-flight repair")
        #expect(claims == 0)
        negotiation?.resume()
        await peer.settle()
        #expect(claims == 0, "Preserve the donor's100ms serialized claim cadence")
        await peer.advance(to: 100.1)
        await returning.value
        #expect(claimed == true)
        #expect(claims == 1)
        #expect(peer.events == [.admitted, .released, .admitted, .released])
    }

    @Test func simulatedSocketAndHeldPictureCannotCompleteTheExactPictureDeadline() async {
        let peer = Peer()
        peer.presented = 99 // Retained picture, with no new source report.
        peer.start(timeout: .milliseconds(200))
        await peer.settle()
        #expect(peer.trace == ["gimbal", "prepare", "negotiate", "enable", "probe"])
        #expect(peer.result == nil)
        await peer.advance(to: 100.099)
        #expect(peer.trace.filter { $0 == "probe" }.count == 1)
        await peer.advance(to: 100.1)
        #expect(peer.trace.filter { $0 == "probe" }.count == 2)
        #expect(peer.result == nil)
        await peer.advance(to: 100.2)
        #expect(peer.result == .exhausted)
        #expect(peer.trace.filter { $0 == "enable" }.count == 1)
        #expect(peer.events == [.admitted, .escalateSession, .released])
    }

    @Test func simulatedNegotiatedRepairPreparesBeforeOneEnableAndRequiresActualPicture() async {
        let identity = NSObject()
        var trace: [String] = []
        let endpoint = DjiApplePictureRecoveryEndpoint(identity: ObjectIdentifier(identity),
            negotiate: { _ in trace.append("negotiate") }, transport: { .init() })
        let owner = DjiApplePictureRecovery(context: {
            .init(endpointIdentity: endpoint.identity, pictureIntent: 7)
        }, native: .init(prepare: {
            trace += ["gimbal", "prepare"]
            return 100
        }, enable: { trace.append("enable") }, probe: { trace.append("probe") },
            picture: { since, _ in
                #expect(since == 100)
                trace.append("picture")
                return .init(fresh: true, lastPresentedAt: 101)
            }), event: { trace.append(String(describing: $0)) })
        let admitted = owner.start { attempt in
            #expect(await attempt.repairEndpoint(endpoint, reason: "SIMULATED",
                pictureIntent: 7, timeout: .seconds(16)) == .restored)
        }
        #expect(admitted)
        for _ in 0..<100 where owner.isBusy { await Task.yield() }
        #expect(trace == ["admitted", "gimbal", "prepare", "negotiate", "enable",
            "picture", "restored", "released"])
    }

    @Test func simulatedCanceledRepairCannotReleaseItsSuccessorSlot() async {
        let owner = DjiApplePictureRecovery(context: { .init() })
        var first: CheckedContinuation<Void, Never>?
        var second: CheckedContinuation<Void, Never>?
        guard owner.start({ _ in await withCheckedContinuation { first = $0 } }) else {
            Issue.record("An empty repair slot must admit its first operation")
            return
        }
        for _ in 0..<100 where first == nil { await Task.yield() }
        #expect(first != nil)
        #expect(owner.isBusy)
        #expect(!owner.start { _ in Issue.record("Competing repair entered a busy slot") })
        owner.cancel()
        #expect(!owner.isBusy)
        #expect(owner.start { _ in await withCheckedContinuation { second = $0 } })
        for _ in 0..<100 where second == nil { await Task.yield() }
        #expect(second != nil)
        first?.resume()
        for _ in 0..<20 { await Task.yield() }
        #expect(owner.isBusy, "A's canceled completion cannot release B")
        #expect(!owner.start { _ in Issue.record("A admitted C while B remains suspended") })
        second?.resume()
        for _ in 0..<100 where owner.isBusy { await Task.yield() }
        #expect(!owner.isBusy)
    }
}
