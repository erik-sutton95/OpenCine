import Foundation
import OpenCineDJI
import OpenCineDJIApple
import Testing

@Suite @MainActor
struct DJIAppleSessionHeartbeatTests {
    /// SIMULATED external transport and clock cross the native owner's public interface.
    @MainActor private final class Peer {
        var time: TimeInterval = 0
        var wakes: [(TimeInterval, @MainActor @Sendable () -> Void)] = []
        var trace: [String] = []
        var policy = DjiAppleHeartbeatContext()
        var observed = DjiAppleHeartbeatTransport()
        var effects: [DjiAppleSessionHeartbeat.Event] = []
        var maintenance: ((DjiAppleSessionHeartbeat.Event) -> Void)?
        lazy var heartbeat = DjiAppleSessionHeartbeat(endpoint: endpoint(),
            timing: .init(wallNow: { [unowned self] in time }, uptime: { [unowned self] in time },
                schedule: { [unowned self] delay, wake in
                    let c = delay.components
                    wakes.append((time + Double(c.seconds) + Double(c.attoseconds) / 1e18, wake))
                }), context: { [unowned self] in policy }, event: { [unowned self] in
                    effects.append($0); maintenance?($0)
                }, journal: { [unowned self] in trace.append($0) })

        func endpoint(_ label: String = "A") -> DjiAppleHeartbeatEndpoint {
            .init(writeBLE: { [unowned self] frame in
                trace.append("\(label):ble:\(frame.cmdSet):\(frame.cmdId):\(frame.payload)")
            }, registerDatalink: { [unowned self] in trace.append("\(label):udp:presence+ack") },
                transport: { [unowned self] in observed })
        }

        func advance(to deadline: TimeInterval) {
            while let next = wakes.enumerated().filter({ $0.element.0 <= deadline + 1e-12 })
                .min(by: { $0.element.0 < $1.element.0 }) {
                time = next.element.0; wakes.remove(at: next.offset); next.element.1()
            }
            time = max(time, deadline)
        }
    }

    @Test func simulatedRegistrationIsAsyncBLEThenUDPAndWaitsOneSecondAfterTick() {
        let peer = Peer()
        peer.heartbeat.start(monitorMaintenanceEnabled: false)
        #expect(peer.trace.isEmpty)
        peer.advance(to: 0)
        #expect(peer.trace == ["A:ble:0:43:[1, 1]", "A:udp:presence+ack"])
        peer.advance(to: 0.999)
        #expect(peer.trace.count == 2)
        peer.advance(to: 1)
        #expect(peer.trace == ["A:ble:0:43:[1, 1]", "A:udp:presence+ack",
            "A:ble:0:43:[1, 1]", "A:udp:presence+ack"])
        peer.heartbeat.stop()
    }
    @Test func simulatedPathLossWaitsEightSecondsAndRetiresBeforeBothWrites() {
        let peer = Peer()
        peer.policy = .init(live: true, ownedConnection: true, sceneActive: true)
        peer.heartbeat.start(monitorMaintenanceEnabled: false)
        peer.advance(to: 7.999)
        #expect(peer.effects.isEmpty)
        #expect(peer.trace.count == 16)
        peer.advance(to: 8)
        #expect(peer.effects == [.cameraPathLost])
        #expect(peer.trace.filter { $0.hasPrefix("A:") }.count == 16, "Path loss transfers ownership before BLE or UDP registration")
        peer.advance(to: 30)
        #expect(peer.trace.filter { $0.hasPrefix("A:") }.count == 16)
    }

    @Test func simulatedMaintenanceThenSelfieFlipFallbackUsesTwoSecondUDPReplyRule() {
        let peer = Peer()
        peer.policy = .init(sceneActive: true)
        peer.maintenance = { event in peer.trace.append("host:\(event)") }
        peer.heartbeat.start(monitorMaintenanceEnabled: true)
        peer.advance(to: 0)
        #expect(peer.trace == ["A:ble:0:43:[1, 1]", "A:udp:presence+ack",
            "host:liveMonitorMaintenance", "flip: beat tx=\u{2014}s rx=\u{2014}s ble-fallback=1",
            "A:ble:2:142:[0, 1, 56, 0]"])
        peer.trace = []
        peer.observed.lastSelfieFlipReplyAt = 0
        peer.advance(to: 1)
        #expect(peer.trace.last == "flip: beat tx=\u{2014}s rx=1.0s ble-fallback=0")
        peer.trace = []
        peer.advance(to: 2)
        #expect(peer.trace.suffix(2) == ["flip: beat tx=\u{2014}s rx=2.0s ble-fallback=1",
            "A:ble:2:142:[0, 1, 56, 0]"])
        peer.heartbeat.stop()
    }

    @Test func simulatedInactiveCoveredAndHeldMonitorAlwaysRegisterWithoutRecoveryCommands() {
        let peer = Peer()
        peer.policy = .init(live: true, ownedConnection: true, sceneActive: false,
            holdsMonitor: true, browsingMedia: true, sessionRecovering: true, foregroundChecking: true)
        peer.heartbeat.start(monitorMaintenanceEnabled: true)
        peer.advance(to: 10)
        #expect(peer.trace.filter { $0.contains(":ble:") }.count == 11)
        #expect(peer.trace.filter { $0.contains(":udp:") }.count == 11)
        #expect(peer.trace.allSatisfy { $0 == "A:ble:0:43:[1, 1]" || $0 == "A:udp:presence+ack" })
        #expect(peer.effects == Array(repeating: .heldMonitorMaintenance, count: 11))
        peer.heartbeat.stop()
        peer.trace = []; peer.effects = []
        peer.policy.holdsMonitor = false
        peer.heartbeat.start(monitorMaintenanceEnabled: true)
        peer.advance(to: 12)
        #expect(peer.effects.isEmpty)
        #expect(peer.trace.count == 6, "Inactive scene suppresses maintenance, never registration")
        peer.heartbeat.stop()
    }

    @Test func simulatedFreshVideoAndActiveRepairPreserveReassociationGrace() {
        let peer = Peer()
        peer.policy = .init(live: true, ownedConnection: true, sceneActive: true)
        peer.heartbeat.start(monitorMaintenanceEnabled: false)
        peer.advance(to: 6)
        peer.observed.lastVideoAt = 7
        peer.advance(to: 7)
        peer.observed.lastVideoAt = nil
        peer.advance(to: 15.999)
        #expect(peer.effects.isEmpty, "Fresh packet resets the original absence episode")
        peer.policy.feedRepairing = true
        peer.advance(to: 16)
        #expect(peer.effects.isEmpty, "Current repair retains ownership at the grace deadline")
        peer.policy.feedRepairing = false
        peer.advance(to: 17)
        #expect(peer.effects == [.cameraPathLost])
        #expect(peer.trace.last == "session: camera network absent after reassociation grace; video stale")
    }

    @Test func simulatedSceneResetRenewsPathGraceWithoutStoppingRegistration() {
        let peer = Peer()
        peer.policy = .init(live: true, ownedConnection: true, sceneActive: true)
        peer.heartbeat.start(monitorMaintenanceEnabled: false)
        peer.advance(to: 7)
        peer.heartbeat.resetPathGrace()
        peer.advance(to: 15.999)
        #expect(peer.effects.isEmpty)
        #expect(peer.trace.count == 32)
        peer.advance(to: 16)
        #expect(peer.effects == [.cameraPathLost])
    }

    @Test func simulatedMaintenanceResamplesBrowseAndActualReplyBeforeFallback() {
        let peer = Peer()
        peer.policy.sceneActive = true
        peer.maintenance = { _ in peer.policy.browsingMedia = true }
        peer.heartbeat.start(monitorMaintenanceEnabled: true)
        peer.advance(to: 0)
        #expect(peer.trace.last == "flip: beat tx=\u{2014}s rx=\u{2014}s ble-fallback=0")
        #expect(peer.trace.filter { $0.contains(":ble:") }.count == 1)
        peer.policy.browsingMedia = false
        peer.maintenance = { _ in peer.observed.lastSelfieFlipReplyAt = peer.time }
        peer.advance(to: 1)
        #expect(peer.trace.last == "flip: beat tx=\u{2014}s rx=0.0s ble-fallback=0")
        #expect(peer.trace.filter { $0.contains(":ble:") }.count == 2)
        peer.heartbeat.stop()
    }

    @Test func simulatedStoppedOldWakeCannotRegisterOnSuccessorOrWakeItEarly() {
        let peer = Peer()
        peer.heartbeat.start(monitorMaintenanceEnabled: false)
        peer.advance(to: 0)
        let canceledWake = peer.wakes[0].1
        peer.advance(to: 0.5)
        peer.heartbeat.stop()
        peer.heartbeat.endpoint = peer.endpoint("B")
        peer.heartbeat.start(monitorMaintenanceEnabled: false)
        peer.advance(to: 0.5)
        let expected = ["A:ble:0:43:[1, 1]", "A:udp:presence+ack",
            "B:ble:0:43:[1, 1]", "B:udp:presence+ack"]
        canceledWake()
        peer.advance(to: 1.499)
        #expect(peer.trace == expected, "A's canceled scheduler intentionally still fires")
        peer.advance(to: 1.5)
        #expect(peer.trace == expected + ["B:ble:0:43:[1, 1]", "B:udp:presence+ack"])
        peer.heartbeat.stop()
        peer.advance(to: 20)
        #expect(peer.trace.count == 6)
    }

    @Test func simulatedEndpointReplacementRetiresCurrentTickButPreservesNextRegistration() {
        let peer = Peer()
        peer.policy.sceneActive = true
        peer.maintenance = { _ in
            peer.heartbeat.endpoint = peer.endpoint("B")
            peer.maintenance = nil
        }
        peer.heartbeat.start(monitorMaintenanceEnabled: true)
        peer.advance(to: 0)
        #expect(peer.trace == ["A:ble:0:43:[1, 1]", "A:udp:presence+ack"],
            "A cannot poll after its endpoint is retired by synchronous host maintenance")
        peer.advance(to: 1)
        #expect(peer.trace.suffix(4) == ["B:ble:0:43:[1, 1]", "B:udp:presence+ack",
            "flip: beat tx=\u{2014}s rx=\u{2014}s ble-fallback=1", "B:ble:2:142:[0, 1, 56, 0]"])
        peer.heartbeat.stop()
    }

    @Test func simulatedReentrantRestartDuringBLECannotWriteOrSchedulePredecessorUDP() {
        let peer = Peer()
        peer.heartbeat.endpoint = .init(writeBLE: { _ in
            peer.trace.append("A:ble")
            peer.heartbeat.endpoint = peer.endpoint("B")
            peer.heartbeat.start(monitorMaintenanceEnabled: false)
        }, registerDatalink: { Issue.record("A's retired UDP registration") }, transport: { .init() })
        peer.heartbeat.start(monitorMaintenanceEnabled: false)
        peer.advance(to: 0)
        #expect(peer.trace == ["A:ble", "B:ble:0:43:[1, 1]", "B:udp:presence+ack"])
        peer.advance(to: 1)
        #expect(peer.trace.count == 5, "Only successor B owns the following deadline")
        peer.heartbeat.stop()
    }

    @Test func simulatedWaitStartsAfterHostMaintenanceAndDuplicateWakeCannotSend() {
        let peer = Peer()
        peer.policy.sceneActive = true
        peer.maintenance = { _ in peer.time += 0.25 }
        peer.heartbeat.start(monitorMaintenanceEnabled: true)
        let originalWake = peer.wakes[0].1
        peer.advance(to: 0)
        #expect(peer.time == 0.25)
        originalWake()
        #expect(peer.trace.filter { $0.contains(":udp:") }.count == 1)
        peer.advance(to: 1.249)
        #expect(peer.trace.filter { $0.contains(":udp:") }.count == 1)
        peer.advance(to: 1.25)
        #expect(peer.trace.filter { $0.contains(":udp:") }.count == 2)
        peer.heartbeat.stop()
    }

    @Test func simulatedPathLossCallbackCanStartSuccessorWithoutPredecessorStoppingIt() {
        let peer = Peer()
        peer.policy = .init(live: true, ownedConnection: true, sceneActive: true)
        peer.maintenance = { event in
            guard event == .cameraPathLost else { return }
            peer.policy.pathReady = true
            peer.heartbeat.endpoint = peer.endpoint("B")
            peer.heartbeat.start(monitorMaintenanceEnabled: false)
        }
        peer.heartbeat.start(monitorMaintenanceEnabled: false)
        peer.advance(to: 8)
        #expect(peer.effects == [.cameraPathLost])
        #expect(peer.trace.suffix(2) == ["B:ble:0:43:[1, 1]", "B:udp:presence+ack"])
        peer.advance(to: 9)
        #expect(peer.trace.suffix(2) == ["B:ble:0:43:[1, 1]", "B:udp:presence+ack"])
        #expect(peer.trace.filter { $0.hasPrefix("B:") }.count == 4)
        peer.heartbeat.stop()
    }

    @Test func simulatedReleasedHeldMonitorResamplesNormalMaintenanceInTheSameTick() {
        let peer = Peer()
        peer.policy = .init(sceneActive: true, holdsMonitor: true)
        peer.maintenance = { event in
            if event == .heldMonitorMaintenance { peer.policy.holdsMonitor = false }
        }
        peer.heartbeat.start(monitorMaintenanceEnabled: true)
        peer.advance(to: 0)
        #expect(peer.effects == [.heldMonitorMaintenance, .liveMonitorMaintenance],
            "Donor uses separate if branches and rechecks held state after its synchronous action")
        #expect(peer.trace.last == "A:ble:2:142:[0, 1, 56, 0]")
        peer.heartbeat.stop()
    }

}
