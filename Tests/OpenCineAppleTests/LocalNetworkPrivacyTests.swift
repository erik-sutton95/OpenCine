import Foundation
import OpenCineCore
import Testing
@testable import OpenCineApple

@Suite @MainActor struct LocalNetworkPrivacyTests {
    @Test func replacementStopsAAndRetiredEvidenceCannotChangeB() {
        let native = ControlledPrivacyNative()
        let privacy = LocalNetworkPrivacy(native: native.native, onChange: { _, _ in })
        let probe = LocalNetworkPrivacy.Probe(browseType: "_beacon._tcp", resultsGrant: true)
        privacy.start(probe)
        privacy.start(probe)
        #expect(native.starts == 2)
        #expect(native.stops == 1, "A is explicitly stopped before B starts")
        native.signal(0, .policyDenied)
        native.signal(0, .results)
        #expect(privacy.state == .requested, "retired A cannot deny or approve B")
        #expect(privacy.isProbing)
        native.signal(1, .results)
        #expect(privacy.state == .allowed)
        #expect(native.stops == 2, "approval ends B's browse and beacon")
        #expect(!privacy.isProbing)
    }

    @Test func onlyExplicitPolicySignalIsDenialAndDenialKeepsObserving() {
        let native = ControlledPrivacyNative()
        let changes = PrivacyChanges()
        let privacy = LocalNetworkPrivacy(native: native.native, onChange: { state, _ in changes.values.append(state) })
        privacy.start(.init(browseType: "_relay._tcp"))
        native.signal(0, .results)
        #expect(privacy.state == .requested, "results of a shared type are not approval")
        privacy.note(.waiting, source: "transport")
        #expect(privacy.state == .requested)
        native.signal(0, .policyDenied)
        #expect(privacy.state == .denied)
        #expect(privacy.isProbing, "a Settings change can still be observed")
        privacy.note(.operationSucceeded, source: "handshake")
        #expect(changes.values == [.requested, .denied, .allowed])
    }

    @Test func boundedLifetimeStopsOnlyItsOwnProbeAndApprovalIsNotReprobed() async {
        let native = ControlledPrivacyNative()
        let privacy = LocalNetworkPrivacy(native: native.native, onChange: { _, _ in })
        privacy.start(.init(browseType: "_relay._tcp", lifetime: .seconds(30)))
        privacy.start(.init(browseType: "_relay._tcp", lifetime: .seconds(30)))
        await native.waitForSleepers(2)
        native.wake(0)
        await Task.yield(); await Task.yield()
        #expect(privacy.isProbing, "A's lifetime cannot stop B")
        native.wake(1)
        while privacy.isProbing { await Task.yield() }
        #expect(native.stops == 2)
        privacy.note(.operationSucceeded, source: "handshake")
        privacy.start(.init(browseType: "_relay._tcp"))
        #expect(native.starts == 2, "known approval is not probed again")
    }

    /// Hardware pass 5.1 (Pocket iOS) and 8.0 (Insta iOS): the Local Network prompt came only
    /// after the camera Wi-Fi join, when the camera link was already timing out. The shared
    /// pre-join request browses the app's own relay type through the legacy browser, which raises
    /// the prompt on device (an NWBrowser alone did not), and never restarts a running probe.
    @Test func beforeCameraJoinRaisesThePromptOnceAndKeepsAnApproval() async {
        let native = ControlledPrivacyNative()
        let privacy = LocalNetworkPrivacy(native: native.native, onChange: { _, _ in })
        privacy.requestBeforeCameraJoin(serviceType: "_opc-mon._tcp")
        #expect(native.probes.count == 1)
        let probe = native.probes.first
        #expect(probe?.promptTrigger == "_opc-mon._tcp.", "the legacy browse raises the prompt")
        #expect(probe?.browseType == "_opc-mon._tcp" && probe?.includePeerToPeer == false)
        #expect(probe?.resultsGrant == false, "results of a shared type are not approval")
        #expect(probe?.lifetime == .seconds(30))
        await native.waitForSleepers(1)
        privacy.requestBeforeCameraJoin(serviceType: "_opc-mon._tcp")
        #expect(native.starts == 1, "a running probe is not restarted")
        privacy.note(.operationSucceeded, source: "handshake")
        privacy.stop()
        privacy.requestBeforeCameraJoin(serviceType: "_opc-mon._tcp")
        #expect(native.starts == 1, "a known approval is not probed again")
        native.wake(0)
    }
}

@MainActor private final class PrivacyChanges { var values: [CameraNetworkPermissionState] = [] }

/// SIMULATED probe callbacks. No Bonjour, multicast or permission prompt.
@MainActor private final class ControlledPrivacyNative {
    var starts = 0
    var stops = 0
    var probes: [LocalNetworkPrivacy.Probe] = []
    private var handlers: [@MainActor (LocalNetworkPrivacy.Signal) -> Void] = []
    private var sleepers: [CheckedContinuation<Void, Error>] = []
    private var sleeperWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    var native: LocalNetworkPrivacy.Native {
        .init(start: { [unowned self] probe, signal in
            starts += 1
            probes.append(probe)
            handlers.append(signal)
            return { [unowned self] in stops += 1 }
        }, sleep: { [unowned self] _ in
            try await withCheckedThrowingContinuation { continuation in
                sleepers.append(continuation)
                let ready = sleeperWaiters.filter { $0.0 <= sleepers.count }
                sleeperWaiters.removeAll { $0.0 <= sleepers.count }
                ready.forEach { $0.1.resume() }
            }
        })
    }
    func signal(_ index: Int, _ value: LocalNetworkPrivacy.Signal) { handlers[index](value) }
    func waitForSleepers(_ count: Int) async {
        if sleepers.count >= count { return }
        await withCheckedContinuation { sleeperWaiters.append((count, $0)) }
    }
    func wake(_ index: Int) { sleepers[index].resume() }
}
