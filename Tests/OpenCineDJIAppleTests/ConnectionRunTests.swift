import Foundation
import OpenCineDJI
import OpenCineDJIApple
import Testing

@Suite @MainActor
struct DJIAppleConnectionRunTests {
    /// SIMULATED OS peers replay independently captured CameraSession donor commands.
    @Test func coldAPRetainsDonorCommandAndRegistrationBoundary() async {
        let peer = Peer()
        defer { peer.owner.retire(); peer.exchange.stopBLEDrain(); peer.heartbeat.stop() }
        peer.owner.replace(target: peer.camera, setup: .cameraWiFi)
        await peer.finished()
        #expect(peer.trace == ["prepare", "GATT", "BLE wake", "BLE pair", "sleep 0.2",
            "BLE AP-wake", "sleep 0.6", "BLE SSID", "BLE password", "join AP", "persist",
            "make AP", "attach", "open AP", "registered", "enable", "open returned"])
        #expect(peer.connected?.joinedSSID == peer.network)
        #expect(peer.trace.filter { $0 == "enable" }.count == 1)
    }

    @Test func warmAPSkipsOnlySettlesAndCredentialReads() async {
        let peer = Peer(); peer.cached = true
        defer { peer.owner.retire(); peer.exchange.stopBLEDrain(); peer.heartbeat.stop() }
        peer.owner.replace(target: peer.camera, setup: .cameraWiFi)
        await peer.finished()
        #expect(peer.trace == ["prepare", "GATT", "BLE wake", "BLE pair", "BLE AP-wake",
            "join AP", "persist", "make AP", "attach", "open AP", "registered", "enable", "open returned"])
        #expect(peer.connected?.joinedSSID == peer.network)
    }

    @Test func deferredPairRetainsThreeSecondDisconnectRetry() async {
        let peer = Peer(); peer.cached = true; peer.deferred = true
        defer { peer.owner.retire(); peer.exchange.stopBLEDrain(); peer.heartbeat.stop() }
        peer.owner.replace(target: peer.camera, setup: .cameraWiFi)
        await peer.finished()
        #expect(peer.trace == ["prepare", "GATT", "BLE wake", "BLE pair", "disconnect BLE", "sleep 3.0",
            "GATT", "BLE wake", "BLE pair", "BLE AP-wake", "join AP", "persist", "make AP", "attach",
            "open AP", "registered", "enable", "open returned"])
    }

    @Test func wifiStationRetainsDonorIdentityRegistrationOrder() async {
        await station(hotspot: false)
    }
    @Test func phoneHotspotStationDoesNotJoinPhone() async {
        await station(hotspot: true)
    }
    private func station(hotspot: Bool) async {
        let peer = Peer(); peer.station = true
        defer { peer.owner.retire(); peer.exchange.stopBLEDrain(); peer.heartbeat.stop() }
        let setup: DJISetup = hotspot ? .phoneHotspot(network: peer.network, password: nil)
            : .wifi(network: peer.network, password: nil)
        peer.owner.replace(target: peer.camera, setup: setup)
        await peer.finished()
        var expected = ["prepare", "GATT", "BLE wake", "BLE pair"]
        if !hotspot { expected.append("join host") }
        expected += ["BLE SSID", "BLE 02/e1", "sleep 2.0", "BLE 07/39", "BLE 07/48", "BLE 07/39",
            "sleep 10.0", "BLE 07/47", "discover", "dispose", "make station", "attach",
            "open identity", "open returned", "UDP identity", "complete registration", "registered", "enable"]
        #expect(peer.trace == expected)
        #expect(peer.connected?.stationHost == "198.51.100.7")
    }

    @Test func restoringAPRetainsRoleResetBeforeSettles() async {
        let peer = Peer(); peer.restoring = true; peer.cached = true; peer.stationSwitched = true
        defer { peer.owner.retire(); peer.exchange.stopBLEDrain(); peer.heartbeat.stop() }
        peer.owner.replace(target: peer.camera, setup: .cameraWiFi)
        await peer.finished()
        #expect(peer.trace == ["prepare", "GATT", "BLE wake", "BLE pair", "BLE 07/48", "BLE 07/39",
            "sleep 0.2", "BLE AP-wake", "sleep 0.6", "join AP", "persist", "make AP", "attach",
            "open AP", "registered", "enable", "open returned"])
    }

    @Test func cleanupObservationCannotCloseSynchronouslyAdoptedSuccessorEndpoint() async {
        let peer = Peer(); peer.cached = true
        defer { peer.owner.retire(); peer.exchange.stopBLEDrain(); peer.heartbeat.stop() }
        peer.onAttach = { endpoint, _ in
            guard let endpoint else { return }
            peer.onAttach = nil; peer.currentEndpoint = nil; peer.owner.retire()
            // The cleanup observation returns its old nil snapshot after transferring this
            // endpoint to B. A may no longer treat that return value as close authority.
            peer.onObserve = {
                peer.onObserve = nil; peer.currentEndpoint = endpoint
                peer.owner.replace(target: peer.camera, setup: .cameraWiFi)
            }
        }
        peer.owner.replace(target: peer.camera, setup: .cameraWiFi)
        await peer.finished()
        #expect(peer.made.count == 1)
        #expect(peer.made.first?.isClosed == false)
        #expect(!peer.trace.contains("close endpoint"))
        #expect(peer.connected?.joinedSSID == peer.network)
    }

    @Test(arguments: ["prepare", "stage", "credentials", "attach", "registered"])
    func synchronousRetirementStopsRemainingRunEffects(boundary: String) async {
        let peer = Peer(); peer.cached = true
        defer { peer.owner.retire(); peer.exchange.stopBLEDrain(); peer.heartbeat.stop() }
        var retiredTrace: [String]?
        func retire() { peer.owner.retire(); retiredTrace = peer.trace }
        switch boundary {
        case "prepare": peer.onPrepare = { _ in retire() }
        case "stage": peer.onStage = { if $0 == .pairing { retire() } }
        case "credentials": peer.onResolve = { retire() }
        case "attach": peer.onAttach = { _, _ in retire() }
        case "registered": peer.onRegistered = { _ in retire() }
        default: break
        }
        peer.owner.replace(target: peer.camera, setup: .cameraWiFi)
        for _ in 0..<1000 { if retiredTrace != nil { break }; await Task.yield() }
        for _ in 0..<10 { await Task.yield() }
        #expect(retiredTrace != nil)
        // A suspended native open may return after its callback. Returning is not a new
        // wire/source action; the owner must refuse all subsequent registration/enable.
        #expect(peer.trace.filter { $0 != "open returned" } == retiredTrace)
        #expect(peer.result == nil)
        #expect(!peer.owner.isRunning)
        #expect(!peer.trace.contains("enable"))
        #expect(!peer.trace.contains("close endpoint"))
    }

    @Test(arguments: [true, false])
    func borrowedOrUnknownConnectionCannotPrepareOrConnect(unknown: Bool) async {
        let peer = Peer(); peer.ownsConnection = unknown ? nil : false
        defer { peer.owner.retire(); peer.exchange.stopBLEDrain(); peer.heartbeat.stop() }
        peer.owner.replace(target: peer.camera, setup: .cameraWiFi)
        await peer.finished()
        #expect(peer.trace.isEmpty)
        if case .failure(let error) = peer.result {
            #expect(error as? DjiAppleConnectionRun.Failure == .connectionNotOwned)
        } else { Issue.record("SIMULATED borrowed or unknown owner admitted") }
    }

    @Test(arguments: ["GATT", "join", "open", "discovery"])
    func lateNativeAwaitCannotMutateOrReleaseSuccessor(boundary: String) async {
        let peer = Peer(); peer.cached = true
        if boundary == "discovery" { peer.station = true }
        let gate = Gate()
        defer { peer.owner.retire(); peer.exchange.stopBLEDrain(); peer.heartbeat.stop() }
        switch boundary {
        case "GATT": peer.onConnect = { await gate.wait() }
        case "join": peer.onJoin = { await gate.wait() }
        case "open": peer.onOpen = { await gate.wait() }
        case "discovery": peer.onDiscover = { await gate.wait(); return ["198.51.100.99"] }
        default: break
        }
        let setup: DJISetup = peer.station ? .wifi(network: peer.network, password: nil) : .cameraWiFi
        peer.owner.replace(target: peer.camera, setup: setup)
        await peer.until { gate.isWaiting }
        peer.onConnect = nil; peer.onJoin = nil; peer.onOpen = nil; peer.onDiscover = nil
        peer.owner.replace(target: peer.camera, setup: setup)
        await peer.finished()
        let successorID = peer.owner.currentRunID
        let endpoint = peer.currentEndpoint
        let before = peer.trace
        gate.resume()
        for _ in 0..<20 { await Task.yield() }
        #expect(peer.owner.currentRunID == successorID)
        #expect(peer.currentEndpoint === endpoint)
        #expect(peer.connected != nil)
        #expect(peer.trace.filter { $0 != "open returned" } == before.filter { $0 != "open returned" })
        #expect(peer.trace.filter { $0 == "enable" }.count == 1)
        #expect(!peer.trace.contains("close endpoint"))
    }

    @Test func apJoinRequestCarriesItsAttemptValidityForQueuedHotspotWork() async {
        let peer = Peer(); peer.cached = true
        let gate = Gate()
        defer { peer.owner.retire(); peer.exchange.stopBLEDrain(); peer.heartbeat.stop() }
        peer.onJoin = { await gate.wait() }
        peer.owner.replace(target: peer.camera, setup: .cameraWiFi)
        await peer.until { gate.isWaiting }
        let first = peer.joinRequests.first
        #expect(first?.isCurrent() == true)
        peer.onJoin = nil
        peer.owner.replace(target: peer.camera, setup: .cameraWiFi)
        await peer.finished()
        #expect(first?.isCurrent() == false, "the replaced run's queued hotspot work is no longer admitted")
        #expect(peer.joinRequests.count == 2)
        gate.resume()
    }

    @Test func defaultLeaveIfCurrentKeepsTheOriginalLeaveForACurrentRequest() {
        let left = LeftSSIDs()
        let network = DjiAppleConnectionTransport.Network(cameraPathReady: { true },
            stationPathReady: { _ in true }, joinAccessPoint: { _ in }, rejectsCredentials: { _ in false },
            joinHost: { _, _ in nil }, leave: { left.values.append($0) }, currentSSID: { nil },
            candidates: { _ in [] }, subnetSize: { _ in nil })
        network.leaveIfCurrent("A", { true })
        network.leaveIfCurrent("B", { false })
        #expect(left.values == ["A"])
    }

    @Test func retiredCredentialRequestCannotCancelSuccessorRequestWithSameOpcode() async {
        let peer = Peer()
        defer { peer.owner.retire(); peer.exchange.stopBLEDrain(); peer.heartbeat.stop() }
        peer.onSend = { $0.cmdSet == 7 && $0.cmdId == 0x0e }
        peer.owner.replace(target: peer.camera, setup: .cameraWiFi)
        await peer.until { peer.trace.filter { $0 == "BLE password" }.count == 1 }
        peer.owner.replace(target: peer.camera, setup: .cameraWiFi)
        await peer.until { peer.trace.filter { $0 == "BLE password" }.count == 2 }
        #expect(peer.owner.isRunning)
        #expect(peer.result == nil)
        peer.exchange.receive(.init(sender: 0, receiver: 0, seq: 10, flags: Duml.flagResponse,
            cmdSet: 7, cmdId: 0x0e, payload: [0] + Duml.packString("SIMULATED-PASSWORD")))
        await peer.finished()
        #expect(peer.connected?.joinedSSID == peer.network)
        #expect(peer.trace.filter { $0 == "persist" }.count == 1)
        #expect(peer.trace.filter { $0 == "enable" }.count == 1)
    }

    @Test func cachedCredentialEvictionRequiresRejectionAndNoSuccessfulJoin() async {
        for rejected in [true, false] {
            let peer = Peer(); peer.cached = true; peer.rejectJoin = rejected
            defer { peer.owner.retire(); peer.exchange.stopBLEDrain(); peer.heartbeat.stop() }
            peer.onJoin = { throw SimulatedFailure.handshake }
            peer.owner.replace(target: peer.camera, setup: .cameraWiFi)
            await peer.finished()
            #expect(peer.evictions == (rejected ? 1 : 0))
            #expect(peer.connected == nil)
            #expect(!peer.trace.contains("persist"))
            #expect(!peer.trace.contains("enable"))
        }
    }

    @Test func staleHeldSSIDIsNotCredentialWriteEvidence() async {
        let peer = Peer(); var validated: [String] = []
        defer { peer.owner.retire(); peer.exchange.stopBLEDrain(); peer.heartbeat.stop() }
        peer.onValidate = { ssid, _ in validated.append(ssid) }
        peer.onSend = { frame in
            if frame.cmdSet == 0x53 {
                peer.continuation?.yield(.init(sender: 0, receiver: 0, seq: 1, flags: Duml.flagResponse,
                    cmdSet: 7, cmdId: 7, payload: [0] + Duml.packString("OtherBody-SIMULATED")))
            }
            return false
        }
        peer.owner.replace(target: peer.camera, setup: .cameraWiFi)
        await peer.finished()
        #expect(validated == [peer.network])
        #expect(peer.connected?.joinedSSID == peer.network)
        #expect(peer.trace.contains("BLE SSID"))
    }

    @Test func SSIDRefusalExcludesAnotherSavedBodyBeforePasswordRead() async {
        let peer = Peer()
        defer { peer.owner.retire(); peer.exchange.stopBLEDrain(); peer.heartbeat.stop() }
        peer.onSend = { frame in
            guard frame.cmdSet == 7, frame.cmdId == 7 else { return false }
            peer.continuation?.yield(.init(sender: 0, receiver: 0, seq: frame.seq, flags: Duml.flagResponse,
                cmdSet: 7, cmdId: 7, payload: [0xe0]))
            return true
        }
        peer.onValidate = { _, _ in throw DjiAppleConnectionRun.Failure.wrongCamera }
        peer.owner.replace(target: peer.camera, setup: .cameraWiFi)
        await peer.finished()
        #expect(!peer.trace.contains("BLE password"))
        #expect(!peer.trace.contains("join AP"))
        if case .failure(let error) = peer.result {
            #expect(error as? DjiAppleConnectionRun.Failure == .wrongCamera)
        } else { Issue.record("SIMULATED another body was accepted") }
    }

    @Test func sixHandshakeMissesRetainFiveHalfSecondRetries() async {
        let peer = Peer(); peer.cached = true
        defer { peer.owner.retire(); peer.exchange.stopBLEDrain(); peer.heartbeat.stop() }
        peer.onOpen = { throw SimulatedFailure.handshake }
        peer.owner.replace(target: peer.camera, setup: .cameraWiFi)
        await peer.finished()
        #expect(peer.trace.filter { $0 == "open AP" }.count == 6)
        #expect(peer.trace.filter { $0 == "sleep 0.5" }.count == 5)
        #expect(peer.made.count == 1)
        #expect(!peer.trace.contains("enable"))
        #expect(peer.connected == nil)
    }

    @Test func factoryRetirementClosesOnlyItsOwnUnadoptedEndpointOnce() async {
        let peer = Peer(); peer.cached = true
        defer { peer.owner.retire(); peer.exchange.stopBLEDrain(); peer.heartbeat.stop() }
        peer.onMake = { _ in peer.owner.retire() }
        peer.owner.replace(target: peer.camera, setup: .cameraWiFi)
        await peer.until { !peer.made.isEmpty }
        for _ in 0..<10 { await Task.yield() }
        #expect(peer.made.first?.isClosed == true)
        #expect(peer.currentEndpoint == nil)
        #expect(peer.trace.filter { $0 == "close endpoint" }.count == 1)
        #expect(!peer.trace.contains("open AP"))
        #expect(peer.result == nil)
    }

    @Test(arguments: [true, false])
    func handshakePathLossOrPermissionDenialDoesNotRetry(denied: Bool) async {
        let peer = Peer(); peer.cached = true; peer.denied = denied
        defer { peer.owner.retire(); peer.exchange.stopBLEDrain(); peer.heartbeat.stop() }
        peer.onOpen = { peer.apReady = false; throw SimulatedFailure.handshake }
        peer.owner.replace(target: peer.camera, setup: .cameraWiFi)
        await peer.finished()
        #expect(peer.trace.filter { $0 == "open AP" }.count == 1)
        #expect(!peer.trace.contains("sleep 0.5"))
        #expect(!peer.trace.contains("enable"))
    }

    @Test func absentStationNetworkFailsAtPostPairingSamplingBoundary() async {
        let peer = Peer()
        defer { peer.owner.retire(); peer.exchange.stopBLEDrain(); peer.heartbeat.stop() }
        peer.owner.replace(target: peer.camera, route: .infrastructureNetwork)
        await peer.finished()
        #expect(peer.trace == ["prepare", "GATT", "BLE wake", "BLE pair"])
        if case .failure(let error) = peer.result {
            #expect(error as? DjiAppleConnectionRun.Failure == .setupNotSaved)
        } else { Issue.record("SIMULATED missing network was accepted") }
    }

    @Test func emptyPasswordRepliesKeepTwelveSecondDeadlineAndFourHundredMillisecondRetry() async {
        let peer = Peer()
        defer { peer.owner.retire(); peer.exchange.stopBLEDrain(); peer.heartbeat.stop() }
        peer.onSend = { frame in
            guard frame.cmdSet == 7, frame.cmdId == 0x0e else { return false }
            peer.continuation?.yield(.init(sender: 0, receiver: 0, seq: frame.seq, flags: Duml.flagResponse,
                cmdSet: 7, cmdId: 0x0e, payload: [0, 0]))
            return true
        }
        peer.owner.replace(target: peer.camera, setup: .cameraWiFi)
        await peer.finished()
        #expect(peer.time >= 12.8 && peer.time <= 13.2)
        let reads = peer.trace.filter { $0 == "BLE password" }.count
        #expect(reads >= 30 && reads <= 31)
        #expect(peer.trace.filter { $0 == "sleep 0.4" }.count == reads)
        #expect(!peer.trace.contains("join AP"))
        if case .failure(let error) = peer.result {
            #expect(error as? DjiAppleConnectionRun.Failure == .heldSession)
        } else { Issue.record("SIMULATED empty credentials were accepted") }
    }

    @Test func approvalHeldReplyDoesNotRequireAnotherPINWrite() async {
        let peer = Peer(); peer.cached = true
        defer { peer.owner.retire(); peer.exchange.stopBLEDrain(); peer.heartbeat.stop() }
        peer.onSend = { frame in
            guard frame.cmdSet == 7, frame.cmdId == 0x45 else { return false }
            peer.continuation?.yield(.init(sender: 0, receiver: 0, seq: frame.seq, flags: Duml.flagResponse,
                cmdSet: 7, cmdId: 0x46, payload: [0]))
            return true
        }
        peer.owner.replace(target: peer.camera, setup: .cameraWiFi)
        await peer.finished()
        #expect(peer.trace.filter { $0 == "BLE pair" }.count == 1)
        #expect(peer.connected?.joinedSSID == peer.network)
    }

    @Test func anotherStationIdentityNeverRegistersOrEnables() async {
        let peer = Peer(); peer.station = true
        defer { peer.owner.retire(); peer.exchange.stopBLEDrain(); peer.heartbeat.stop() }
        // Every UDP answer differs from the actual BLE identity.
        peer.onSend = { frame in
            guard frame.cmdSet == 7, frame.cmdId == 7, frame.seq == 0 else { return false }
            peer.continuation?.yield(.init(sender: 0, receiver: 0, seq: 0, flags: Duml.flagResponse,
                cmdSet: 7, cmdId: 7, payload: [0] + Duml.packString("OtherBody-SIMULATED")))
            return true
        }
        peer.owner.replace(target: peer.camera, setup: .wifi(network: peer.network, password: nil))
        await peer.finished()
        #expect(!peer.trace.contains("complete registration"))
        #expect(!peer.trace.contains("registered"))
        #expect(!peer.trace.contains("enable"))
        #expect(peer.currentEndpoint == nil)
        #expect(peer.time == 72)
        #expect(peer.trace.filter { $0 == "sleep 2.0" }.count == 31)
        if case .failure(let error) = peer.result {
            #expect(error as? DjiAppleConnectionRun.Failure == .stationCameraMissing(peer.network))
        } else { Issue.record("SIMULATED another station body was accepted") }
    }

    @Test func nativeOpenCancellationNeverBecomesHandshakeRetry() async {
        let peer = Peer(); peer.cached = true
        defer { peer.owner.retire(); peer.exchange.stopBLEDrain(); peer.heartbeat.stop() }
        peer.onOpen = { throw CancellationError() }
        peer.owner.replace(target: peer.camera, setup: .cameraWiFi)
        await peer.finished()
        #expect(peer.trace.filter { $0 == "open AP" }.count == 1)
        #expect(!peer.trace.contains("sleep 0.5"))
        if case .failure(let error) = peer.result { #expect(error is CancellationError) }
        else { Issue.record("SIMULATED canceled native open was accepted") }
    }

    @Test func approvalWaitRetainsNinetySecondDeadline() async {
        let peer = Peer(); peer.cached = true
        defer { peer.owner.retire(); peer.exchange.stopBLEDrain(); peer.heartbeat.stop() }
        peer.onSend = { $0.cmdSet == 7 && $0.cmdId == 0x45 }
        peer.owner.replace(target: peer.camera, setup: .cameraWiFi)
        await peer.until { peer.wakes.contains { $0.0 == 90 } }
        peer.advance(89)
        for _ in 0..<10 { await Task.yield() }
        #expect(peer.result == nil)
        #expect(peer.owner.isRunning)
        #expect(!peer.trace.contains("BLE AP-wake"))
        peer.advance(1)
        await peer.finished()
        if case .failure(let error) = peer.result {
            #expect(error as? DjiAppleConnectionRun.Failure == .pairingTimeout)
        } else { Issue.record("SIMULATED approval timeout was accepted") }
    }

    @Test func replacementCannotUseOldHeldApprovalAsItsOwnPairingEvidence() async {
        let peer = Peer(); peer.cached = true
        defer { peer.owner.retire(); peer.exchange.stopBLEDrain(); peer.heartbeat.stop() }
        peer.exchange.receive(.init(sender: 0, receiver: 0, seq: 41, flags: Duml.flagResponse,
            cmdSet: 7, cmdId: 0x45, payload: [0, 1]))
        peer.onSend = { $0.cmdSet == 7 && $0.cmdId == 0x45 }
        peer.owner.replace(target: peer.camera, setup: .cameraWiFi)
        await peer.until { peer.result != nil || peer.wakes.contains { $0.0 == 90 } }
        #expect(peer.result == nil)
        #expect(peer.owner.isRunning)
        #expect(!peer.trace.contains("BLE AP-wake"))
        peer.exchange.receive(.init(sender: 0, receiver: 0, seq: 42, flags: Duml.flagResponse,
            cmdSet: 7, cmdId: 0x45, payload: [0, 1]))
        await peer.finished()
        #expect(peer.connected?.joinedSSID == peer.network)
        #expect(peer.trace.filter { $0 == "enable" }.count == 1)
    }

    @Test func retiredPreparationCannotRetireSuccessorReplyRequestOrHeldApproval() async throws {
        let peer = Peer()
        defer { peer.owner.retire(); peer.exchange.stopBLEDrain(); peer.heartbeat.stop() }
        var successor: DjiAppleControlExchange.Request?
        peer.onPrepare = { _ in
            peer.owner.retire()
            successor = peer.exchange.request(matching: [(7, 7)], timeout: .seconds(4), consumeHold: false)
            peer.exchange.receive(.init(sender: 0, receiver: 0, seq: 52, flags: Duml.flagResponse,
                cmdSet: 7, cmdId: 0x45, payload: [0, 1]))
        }
        peer.owner.replace(target: peer.camera, setup: .cameraWiFi)
        await peer.until { successor != nil }
        for _ in 0..<10 { await Task.yield() }
        #expect(peer.trace == ["prepare"])
        #expect(peer.result == nil)
        peer.exchange.receive(.init(sender: 0, receiver: 0, seq: 53, flags: Duml.flagResponse,
            cmdSet: 7, cmdId: 7, payload: [0] + Duml.packString(peer.network)))
        let reply = try await successor?.value()
        #expect(reply?.seq == 53)
        let held = peer.exchange.request(matching: [(7, 0x45)])
        let approval = try await held.value()
        #expect(approval.seq == 52)
    }

    @Test func oldBLEDrainCannotReseedApprovalDuringSuccessorGattAwait() async {
        let peer = Peer(); peer.cached = true
        let gate = Gate()
        let old = AsyncStream.makeStream(of: Duml.Frame.self)
        defer { gate.resume(); old.continuation.finish()
            peer.owner.retire(); peer.exchange.stopBLEDrain(); peer.heartbeat.stop() }
        peer.exchange.startBLEDrain(old.stream)
        peer.onConnect = { await gate.wait() }
        peer.onSend = { $0.cmdSet == 7 && $0.cmdId == 0x45 }
        peer.owner.replace(target: peer.camera, setup: .cameraWiFi)
        await peer.until { gate.isWaiting }
        old.continuation.yield(.init(sender: 0, receiver: 0, seq: 61, flags: Duml.flagResponse,
            cmdSet: 7, cmdId: 0x45, payload: [0, 1]))
        for _ in 0..<10 { await Task.yield() }
        gate.resume()
        await peer.until { peer.result != nil || peer.wakes.contains { $0.0 == 90 } }
        #expect(peer.result == nil)
        #expect(!peer.trace.contains("BLE AP-wake"))
        peer.exchange.receive(.init(sender: 0, receiver: 0, seq: 62, flags: Duml.flagResponse,
            cmdSet: 7, cmdId: 0x45, payload: [0, 1]))
        await peer.finished()
        #expect(peer.connected?.joinedSSID == peer.network)
    }

    @Test(arguments: [DJIConnectionRoute.usb, DJIConnectionRoute.captureDevice])
    func unsupportedRouteNeverPreparesNativeSourceOrSendsBluetooth(route: DJIConnectionRoute) async {
        let peer = Peer()
        defer { peer.owner.retire(); peer.exchange.stopBLEDrain(); peer.heartbeat.stop() }
        peer.owner.replace(target: peer.camera, route: route)
        await peer.finished()
        #expect(peer.trace.isEmpty)
        if case .failure(let error) = peer.result {
            #expect(error as? DjiAppleConnectionRun.Failure == .setupNotSaved)
        } else { Issue.record("SIMULATED unsupported route was accepted") }
    }

    @MainActor private final class Gate {
        var continuation: CheckedContinuation<Void, Never>?
        var isWaiting: Bool { continuation != nil }
        func wait() async { await withCheckedContinuation { continuation = $0 } }
        func resume() { let old = continuation; continuation = nil; old?.resume() }
    }
    private enum SimulatedFailure: Error { case handshake }

    @MainActor final class Peer {
        let network = "OsmoPocket4-SIMULATED"
        let camera = DJISighting(id: "FC064E5E-2B01-4F6B-94D2-663C03C8F001", name: "OsmoPocket4-SIMULATED",
            model: CameraModel.resolve(modelId: 0x0021, name: "OsmoPocket4-SIMULATED", brand: .dji), modelId: 0x0021)
        var time: TimeInterval = 0
        var cached = false
        var deferred = false
        var station = false
        var stationSwitched = false
        var restoring = false
        var ownsConnection: Bool? = true
        var onObserve: (() -> Void)?
        var onPrepare: ((DjiAppleConnectionRun.Attempt) -> Void)?
        var preparedTargets: [DJISighting] = []
        var onAttach: (((any DjiAppleConnectionEndpoint)?, DjiAppleConnectionRun.Attempt) -> Void)?
        var onRegistered: ((DjiAppleConnectionRun.Attempt) -> Void)?
        var onStage: ((DJIConnectionStage) -> Void)?
        var onResolve: (() -> Void)?
        var onConnect: (() async throws -> Void)?
        var onJoin: (() async throws -> Void)?
        var joinRequests: [DjiAppleConnectionTransport.AccessPointJoin] = []
        var onDiscover: (() async throws -> [String])?
        var onOpen: (() async throws -> Void)?
        var onSend: ((Duml.Frame) -> Bool)?
        var onClosedRead: (() -> Void)?
        var onMake: ((Endpoint) -> Void)?
        /// SIMULATED recovery uses one manual clock across native and episode owners.
        var timingSleep: (@MainActor @Sendable (Duration) async throws -> Void)?
        var apReady = true
        var denied = false
        var made: [Endpoint] = []
        var known: DjiAppleConnectionRun.KnownWiFi?
        var rejectJoin = false
        var evictions = 0
        var onValidate: ((String, DjiAppleConnectionRun.SSIDUse) throws -> Void)?
        var trace: [String] = []
        var currentEndpoint: (any DjiAppleConnectionEndpoint)?
        var currentPath = DjiAppleConnectionRun.Path()
        var continuation: AsyncStream<Duml.Frame>.Continuation?
        var wakes: [(TimeInterval, @MainActor @Sendable () -> Void)] = []
        var result: Result<DjiAppleConnectionRun.Path, Error>?
        var connected: DjiAppleConnectionRun.Path? {
            if case .success(let path) = result { return path }; return nil
        }
        lazy var exchange = DjiAppleControlExchange(endpoint: .init(writeBLE: { [unowned self] in send($0) }),
            timing: .init(now: { [unowned self] in time }, schedule: { [unowned self] delay, wake in
                let c = delay.components
                wakes.append((time + Double(c.seconds) + Double(c.attoseconds) / 1e18, wake))
            }), context: { .init() })
        lazy var heartbeat = DjiAppleSessionHeartbeat(endpoint: .init(writeBLE: { _ in },
            registerDatalink: {}, transport: { .init() }), timing: .init(wallNow: { [unowned self] in time },
                uptime: { [unowned self] in time }, schedule: { _, _ in }), context: { .init() }, event: { _ in })
        lazy var owner = DjiAppleConnectionRun(transport: transport, exchange: exchange, heartbeat: heartbeat,
            credentials: .init(savedPath: { [unowned self] _, _ in
                .init(mayBeInStationRole: restoring,
                    station: station ? .init(ssid: network, password: "SIMULATED-PASSWORD") : nil)
            }, resolveWiFi: { [unowned self] _ in
                onResolve?()
                if let known { return known }
                return .init(ssid: cached ? network : nil, password: cached ? "SIMULATED-PASSWORD" : nil,
                    source: cached ? "SIMULATED" : "none", skipBLE: cached)
            },
                joinPolicy: { _, _, _ in .init() }, validateSSID: { [unowned self] _, ssid, use in
                    try onValidate?(ssid, use)
                }, persist: { [unowned self] _, _, _ in trace.append("persist") },
                rejectCached: { [unowned self] _, _ in evictions += 1 }),
            native: .init(observe: { [unowned self] in
                let snapshot = DjiAppleConnectionRun.NativeContext(ownsConnection: ownsConnection,
                    endpoint: currentEndpoint, path: currentPath)
                onObserve?(); return snapshot
            }, prepare: { [unowned self] target, _, attempt in
                preparedTargets.append(target); trace.append("prepare"); onPrepare?(attempt)
            },
                attach: { [unowned self] endpoint, path, attempt in
                    trace.append(endpoint == nil ? "dispose" : "attach")
                    if endpoint == nil { currentEndpoint?.close() }
                    currentEndpoint = endpoint; currentPath = path
                    onAttach?(endpoint, attempt)
                }, registered: { [unowned self] _, _, attempt in
                    trace.append("registered"); onRegistered?(attempt)
                    if attempt.isCurrent { trace.append("enable") }
                }), timing: .init(wallNow: { [unowned self] in time }, uptime: { [unowned self] in time },
                    sleep: { @MainActor [unowned self] duration in
                        if let timingSleep { try await timingSleep(duration); return }
                        let c = duration.components
                        let seconds = Double(c.seconds) + Double(c.attoseconds) / 1e18
                        trace.append(String(format: "sleep %.1f", seconds)); time += seconds
                    }), event: { [unowned self] event in
                        switch event {
                        case .finished(let value, _): result = value
                        case .path(let path): currentPath = path
                        case .stage(let stage, _): onStage?(stage)
                        case .progress: break
                        }
                    })
        var transport: DjiAppleConnectionTransport {
            .init(bluetooth: .init(connect: { [unowned self] _ in
                trace.append("GATT"); try await onConnect?()
            },
                frames: { [unowned self] in
                    let pair = AsyncStream.makeStream(of: Duml.Frame.self)
                    continuation = pair.continuation; return pair.stream
                }, send: { [unowned self] in send($0) }, disconnectAndWait: { [unowned self] in
                    trace.append("disconnect BLE"); continuation?.finish()
                }, retryableDrop: { _ in false }),
                network: .init(cameraPathReady: { [unowned self] in apReady }, stationPathReady: { _ in true },
                    joinAccessPoint: { [unowned self] request in
                        trace.append("join AP"); joinRequests.append(request); try await onJoin?()
                    },
                    rejectsCredentials: { [unowned self] _ in rejectJoin }, joinHost: { [unowned self] _, _ in
                        trace.append("join host"); return "192.0.2.2"
                    }, leave: { _ in }, currentSSID: { nil }, candidates: { [unowned self] _ in
                        trace.append("discover")
                        if let onDiscover { return try await onDiscover() }
                        return station ? ["198.51.100.7"] : []
                    }, subnetSize: { _ in nil }),
                makeEndpoint: { [unowned self] _, address, _ in
                    trace.append(address == nil ? "make AP" : "make station")
                    let endpoint = Endpoint(peer: self); made.append(endpoint); onMake?(endpoint); return endpoint
                }, localNetworkDenied: { [unowned self] _ in denied })
        }
        func send(_ frame: Duml.Frame, viaUDP: Bool = false) {
            let label: String
            switch (frame.cmdSet, frame.cmdId) {
            case (0, 0x2b): label = "wake"
            case (7, 0x45): label = "pair"
            case (0x53, 0x10): label = "AP-wake"
            case (7, 7): label = "SSID"
            case (7, 0x0e): label = "password"
            default: label = String(format: "%02x/%02x", frame.cmdSet, frame.cmdId)
            }
            trace.append(viaUDP ? "UDP identity" : "BLE \(label)")
            if onSend?(frame) == true { return }
            let payload: [UInt8]
            switch (frame.cmdSet, frame.cmdId) {
            case (7, 0x45): payload = deferred ? [0, 6] : [0, 1]; deferred = false
            case (0x53, 0x10): payload = [1, 0, 0, 0]
            case (7, 7): payload = [0] + Duml.packString(network)
            case (7, 0x0e): payload = [0] + Duml.packString("SIMULATED-PASSWORD")
            case (7, 0x39): payload = [0, stationSwitched ? 1 : 0]
            case (7, 0x48): stationSwitched = frame.payload == [1]; payload = [0, 0]
            case (7, 0x47): payload = [0, 0]
            default: return
            }
            continuation?.yield(.init(sender: frame.receiver, receiver: frame.sender, seq: frame.seq,
                flags: Duml.flagResponse, cmdSet: frame.cmdSet, cmdId: frame.cmdId, payload: payload))
        }
        func finished() async {
            for _ in 0..<1000 { if result != nil { return }; await Task.yield() }
            Issue.record("SIMULATED connection did not finish through its public result")
        }
        func until(_ condition: () -> Bool) async {
            for _ in 0..<1000 { if condition() { return }; await Task.yield() }
            Issue.record("SIMULATED operation did not reach held native boundary")
        }
        func advance(_ seconds: TimeInterval) {
            time += seconds
            let due = wakes.filter { $0.0 <= time }; wakes.removeAll { $0.0 <= time }
            due.forEach { $0.1() }
        }
    }

    @MainActor final class Endpoint: DjiAppleConnectionEndpoint {
        unowned let peer: Peer
        private var closed = false
        var isClosed: Bool { let value = closed; peer.onClosedRead?(); return value }
        init(peer: Peer) { self.peer = peer }
        func open(identityOnly: Bool, afterHandshake: (@MainActor () async -> Void)?) async throws {
            peer.trace.append(identityOnly ? "open identity" : "open AP")
            try await peer.onOpen?()
            await afterHandshake?()
            peer.trace.append("open returned")
        }
        func send(_ frame: Duml.Frame) -> UInt16 { peer.send(frame, viaUDP: true); return frame.seq }
        func completeRegistration() { peer.trace.append("complete registration") }
        func close() { closed = true; peer.trace.append("close endpoint") }
    }
}

@MainActor private final class LeftSSIDs { var values: [String] = [] }
