import Foundation
import OpenCineAppKit
import Testing

/// A2-32: the volume-button remote shutter's rules, shared by every app that declares it.
@Suite struct MonitorRemoteShutterPolicyTests {
    typealias Policy = MonitorRemoteShutterPolicy

    /// The anchor is the operator's own level, not mid-scale: arming never moves an ordinary
    /// volume, and only the rails move by the one step a press needs to be visible.
    @Test func theAnchorLeavesAnOrdinaryLevelWhereItIs() {
        for volume in stride(from: Float(0.0625), through: Float(0.9375), by: 0.0625) {
            #expect(abs(Policy.anchor(forCurrentVolume: volume) - volume) < 0.0001)
        }
        #expect(abs(Policy.anchor(forCurrentVolume: 0) - 0.0625) < 0.0001)
        #expect(abs(Policy.anchor(forCurrentVolume: 1) - 0.9375) < 0.0001)
    }

    /// Remotes send volume up or down depending on the model, so a move either way off the anchor
    /// is a press; the anchor's own echo, a repeat inside the debounce window and the echo of a
    /// programmatic re-anchor are not, and each says why.
    @Test func everyMoveOffTheAnchorIsAPressOutsideBothWindows() {
        let t0: TimeInterval = 100
        func decide(_ volume: Float, at now: TimeInterval, triggered: TimeInterval = 0, anchored: TimeInterval = 0,
            anchor: Float = 0.5) -> Policy.Decision {
            Policy.decision(newVolume: volume, now: now, lastTriggerAt: triggered, lastAnchorAt: anchored, anchor: anchor)
        }
        #expect(decide(0.5625, at: t0) == .trigger)
        #expect(decide(0.4375, at: t0) == .trigger)
        #expect(decide(0.5, at: t0) == .atAnchor)
        #expect(decide(0.3125, at: t0, anchor: 0.25) == .trigger, "the decision follows the session's anchor")
        #expect(decide(0.5625, at: t0 + 0.3, triggered: t0, anchored: t0) == .debounced)
        #expect(decide(0.5625, at: t0 + Policy.debounceInterval + 0.01, triggered: t0, anchored: t0) == .trigger)
        #expect(decide(0.5625, at: t0 + 0.1, anchored: t0) == .selfInflicted)
    }

    /// Listening needs the operator's opt-in, the live monitor up and in front, an active app and
    /// a free audio session: Settings, Media or another full-screen page in front disarms it.
    @Test(arguments: 0..<32)
    func listensOnlyForAnEnabledActiveFrontLiveView(bits: Int) {
        let flags = (0..<5).map { bits & (1 << $0) != 0 }
        let run = Policy.shouldRun(enabled: flags[0], monitorPresented: flags[1], liveViewFront: flags[2],
            applicationIsActive: flags[3], audioSessionAvailable: flags[4])
        #expect(run == flags.allSatisfy { $0 })
    }

    /// The audit scenario: one press while the live monitor is in front is exactly one record
    /// toggle, the same press inside Settings is none, and KVO plus the rail notification for one
    /// press still toggle once.
    @Test func onePressIsOneToggleInFrontAndNoneInsideSettings() {
        var presses = MonitorRemoteShutterPresses(volume: 0.5)
        var toggles = 0
        func deliver(_ volume: Float, at now: TimeInterval, liveViewFront: Bool) {
            guard Policy.shouldRun(enabled: true, monitorPresented: true, liveViewFront: liveViewFront,
                applicationIsActive: true, audioSessionAvailable: true) else { return }
            if presses.observe(volume: volume, at: now) == .trigger {
                toggles += 1
                presses.pinned(at: now)
            }
        }
        deliver(0.5625, at: 10, liveViewFront: true)
        deliver(0.5625, at: 10.01, liveViewFront: true)
        #expect(toggles == 1)
        deliver(0.4375, at: 20, liveViewFront: false)
        #expect(toggles == 1)
        deliver(0.4375, at: 30, liveViewFront: true)
        #expect(toggles == 2)
    }

    /// A delayed report is a press only while its value still matches the live system volume.
    /// Otherwise one physical press can toggle again after its re-anchor and debounce have finished.
    @Test func delayedVolumeReportsMustMatchTheLiveVolume() {
        var presses = MonitorRemoteShutterPresses(volume: 0.5)
        var toggles = 0
        func deliver(_ capturedVolume: Float, currentVolume: Float, at now: TimeInterval) {
            if presses.observe(volume: capturedVolume, currentVolume: currentVolume, at: now) == .trigger {
                toggles += 1
                presses.pinned(at: now)
            }
        }
        deliver(0.5625, currentVolume: 0.5625, at: 10)
        #expect(toggles == 1)
        deliver(0.5625, currentVolume: 0.5, at: 11)
        #expect(toggles == 1, "the system already returned to the anchor, so this report is stale")
        #expect(presses.lastTriggerAt == 10, "a stale report does not update trigger bookkeeping")
        deliver(0.4375, currentVolume: 0.4375, at: 11.1)
        #expect(toggles == 2, "a fresh press still toggles")
    }

    /// A route change re-derives the anchor from that route's level but keeps the debounce, so a
    /// reconnecting remote cannot double-toggle.
    @Test func reanchoringKeepsTheDebounce() {
        var presses = MonitorRemoteShutterPresses(volume: 0)
        #expect(abs(presses.anchor - 0.0625) < 0.0001)
        #expect(presses.observe(volume: 0.125, at: 50) == .trigger)
        presses.reanchor(volume: 0.75)
        #expect(presses.anchor == 0.75)
        #expect(presses.observe(volume: 0.8125, at: 50.2) == .debounced)
        #expect(presses.repins(volume: 0.8125, at: 50.2), "a non-press move off the anchor is pinned back")
        presses.pinned(at: 50.2)
        #expect(!presses.repins(volume: 0.8125, at: 50.3), "not inside the re-anchor echo window")
        #expect(!presses.repins(volume: 0.75, at: 51), "nothing to pin at the anchor")
    }

    /// Arming at an ordinary level and stopping where the operator left it write nothing, so they
    /// lease no volume view; only a rail pin or a real restore does.
    @Test func onlyARealVolumeChangeIsAWrite() {
        #expect(!Policy.needsWrite(from: 0.5, to: Policy.anchor(forCurrentVolume: 0.5)))
        #expect(Policy.needsWrite(from: 1, to: Policy.anchor(forCurrentVolume: 1)), "the top rail is pinned")
        #expect(Policy.needsWrite(from: 0, to: Policy.anchor(forCurrentVolume: 0)), "the bottom rail is pinned")
        #expect(!Policy.needsWrite(from: 0.5, to: 0.5005), "a float echo is no write")
        #expect(Policy.needsWrite(from: 0.9375, to: 1), "stopping returns a pinned rail")
    }

    /// The idle regression (an armed shutter kept the app from ever idling): the volume view is
    /// needed only while a write waits and for a short hold after it, never at rest.
    @Test func theVolumeViewIsLeasedOnlyAroundAWrite() {
        var lease = MonitorRemoteShutterVolumeLease()
        #expect(!lease.needsView(at: 10), "an armed shutter at rest leases no view")
        lease.request(volume: 0.25)
        lease.request(volume: 0.5)
        #expect(lease.pendingVolume == 0.5, "the newest write wins")
        #expect(lease.needsView(at: 99), "a waiting write holds the view however long the slider takes")
        lease.wrote(at: 20)
        #expect(lease.pendingVolume == nil)
        #expect(lease.needsView(at: 20 + MonitorRemoteShutterVolumeLease.hold - 0.01), "held for the echo")
        #expect(!lease.needsView(at: 20 + MonitorRemoteShutterVolumeLease.hold), "released after the hold")
        lease.request(volume: 0.75)
        lease.end()
        #expect(lease == MonitorRemoteShutterVolumeLease(), "stop or a route change drops the lease")
        #expect(MonitorRemoteShutterVolumeLease.hold < Policy.debounceInterval * 2,
            "the view goes well before the next deliberate press")
    }
}
