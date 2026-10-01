import Foundation
import HarnessEngine
import OpenCineCore
import OpenCineMulticam
import Testing

/// SIMULATED. Seam defects the harness found (README.md, Seam findings). Each test asserts the correct
/// cross-brand behavior inside `withKnownIssue`, so it passes today, documents the defect, and
/// fails as soon as the defect is fixed (then drop the wrapper).
@MainActor
@Suite struct FindingsTests {
    /// F1: one `MulticamSnapshot.now` is compared with three session clocks on three references
    /// (DJI: process-relative ContinuousClock; Nikon: per-session ContinuousClock; Luna:
    /// `systemUptime`). A group deadline that is 4 s in the future on the app's clock is already
    /// past for Luna.
    @Test func oneGroupDeadlineMeansDifferentInstantsToEachSession() async throws {
        let rig = Rig()
        let start = ContinuousClock.now
        let entries = [rig.entry("Z", rig.nikon), rig.entry("Luna", rig.luna)]
        let g = try group(entries)
        var state = await rig.state(entries)
        state.now = MonotonicInstant(start.duration(to: .now))  // the app's own monotonic clock
        let plan = RecordPlan.make(.start, policy: .strict, entries: entries.map(\.id), in: g, at: state)
        let submission = try await plan.submit(
            in: g, at: state, sessions: rig.map, deadline: .seconds(4))
        #expect(submission.receipts[rig.nikon.id]?.stage != .rejected(.deadlinePassed))
        withKnownIssue("F1: Luna compares the deadline with systemUptime") {
            #expect(submission.receipts[rig.luna.id]?.stage != .rejected(.deadlinePassed))
        }
    }

    /// F1, telemetry side: on Luna's reference, a Nikon report made a moment ago looks hours old;
    /// the DJI adapter stamps no observation time, so its freshness is always unknown.
    @Test func telemetryFreshnessNeedsOneClock() async throws {
        let rig = Rig()
        let entries = [rig.entry("Pocket", rig.dji), rig.entry("Z", rig.nikon), rig.entry("Luna", rig.luna)]
        let g = try group(entries)
        var state = await rig.state(entries)
        state.now = MonotonicInstant(.seconds(ProcessInfo.processInfo.systemUptime))
        let summary = g.summary(at: state, telemetryMaxAge: .seconds(3))
        #expect(summary.entries[2].telemetry == .fresh)
        #expect(summary.entries[0].telemetry == .unknown, "DJI observations carry no timestamp")
        withKnownIssue("F1: Nikon stamps observations on a per-session reference") {
            #expect(summary.entries[1].telemetry == .fresh)
        }
    }
}
