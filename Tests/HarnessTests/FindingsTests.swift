import Foundation
import HarnessEngine
import OpenCineCore
import OpenCineMulticam
import Testing

/// SIMULATED. Regression tests for the seam defects the harness found (README.md, Seam findings).
/// They ran inside `withKnownIssue` until the owning packages were fixed.
@MainActor
@Suite struct FindingsTests {
    /// F1 (fixed): one `MulticamSnapshot.now` on the shared host clock is the reference every
    /// session checks a deadline against. A group deadline 4 s in the future is in the future for
    /// Luna and Nikon alike (Luna used `systemUptime`, Nikon a per-session reference).
    @Test func oneGroupDeadlineMeansTheSameInstantToEverySession() async throws {
        let rig = Rig()
        let entries = [rig.entry("Z", rig.nikon), rig.entry("Luna", rig.luna)]
        let g = try group(entries)
        var state = await rig.state(entries)
        state.now = MonotonicInstant.now()  // the app's clock is the shared host clock
        let plan = RecordPlan.make(.start, policy: .strict, entries: entries.map(\.id), in: g, at: state)
        let submission = try await plan.submit(
            in: g, at: state, sessions: rig.map, deadline: .seconds(4))
        #expect(submission.receipts[rig.nikon.id]?.stage != .rejected(.deadlinePassed))
        #expect(submission.receipts[rig.luna.id]?.stage != .rejected(.deadlinePassed))
    }

    /// F1 (fixed), telemetry side: Nikon and Luna reports made a moment ago are fresh on the shared
    /// clock. The DJI adapter stamps no observation time (CameraStatus carries no arrival time), so
    /// its freshness stays unknown rather than guessed.
    @Test func telemetryFreshnessUsesOneClock() async throws {
        let reportedAt = MonotonicInstant.zero + .seconds(100)
        let rig = Rig(now: { reportedAt })
        let entries = [rig.entry("Pocket", rig.dji), rig.entry("Z", rig.nikon), rig.entry("Luna", rig.luna)]
        let g = try group(entries)
        var state = await rig.state(entries)
        #expect(state.cameras[rig.nikon.id]?.power.battery.observedAt == reportedAt)
        #expect(state.cameras[rig.luna.id]?.mode.observedAt == reportedAt)
        state.now = reportedAt + .seconds(3)
        let fresh = g.summary(at: state, telemetryMaxAge: .seconds(3))
        #expect(fresh.entries[0].telemetry == .unknown, "DJI observations carry no timestamp")
        #expect(fresh.entries[1].telemetry == .fresh)
        #expect(fresh.entries[2].telemetry == .fresh)
        state.now = reportedAt + .seconds(4)
        let stale = g.summary(at: state, telemetryMaxAge: .seconds(3))
        #expect(stale.entries[0].telemetry == .unknown)
        #expect(stale.entries[1].telemetry == .stale)
        #expect(stale.entries[2].telemetry == .stale)
    }
}
