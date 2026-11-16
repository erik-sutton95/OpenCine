import OpenCineCore

/// Record all and a tile's own record press, the same in every app: one policy, one plan rule, one
/// submission and the operator's words for what came back. A group press is coordinated dispatch
/// with per-camera confirmation, never "sync" or "genlock".
public enum RecordAll {
    /// Strict: when any requested camera cannot record (no live view, busy, lent to Live View, a
    /// mode that cannot record), nothing is commanded, so one press never leaves some cameras
    /// rolling and others not by surprise.
    public static let policy: TargetPolicy = .strict

    /// Stop when any requested camera reports recording, else start.
    public static func plan(
        _ requested: [MonitorEntryID], recording: (MonitorEntryID) -> Bool,
        in group: MulticamGroup, at state: MulticamSnapshot
    ) -> RecordPlan {
        RecordPlan.make(
            requested.contains(where: recording) ? .stop : .start, policy: policy,
            entries: requested, in: group, at: state)
    }

    /// Revalidates and sends an approved plan, then waits for every camera's outcome. `nil`: the
    /// plan is stale or refused and nothing was sent (`changed`). A partial result is never
    /// compensated; stopping a camera that started is a separate operator action.
    public static func run(
        _ plan: RecordPlan, in group: MulticamGroup, at state: MulticamSnapshot,
        sessions: [CameraSessionID: any CameraSession]
    ) async -> RecordResult? {
        do {
            let submission = try await plan.submit(in: group, at: state, sessions: sessions)
            return await submission.finished(sessions: sessions)
        } catch {
            return nil
        }
    }

    /// While a group press runs.
    public static func progress(_ direction: RecordDirection) -> String {
        direction == .start ? "Starting cameras…" : "Stopping cameras…"
    }

    /// On each commanded camera until its outcome arrives.
    public static let waiting = "Waiting for camera confirmation"

    /// A camera, link or mode changed after the operator approved: nothing was sent.
    public static let changed = "Cameras changed · try again"

    /// One camera's note for its record outcome; `nil` leaves the tile as it is (superseded).
    public static func note(_ outcome: TargetOutcome, direction: RecordDirection) -> String? {
        switch outcome {
        case .confirmed: direction == .start ? "Recording" : "Recording stopped"
        case .rejected(.cameraRefused): "Recording command rejected · check camera"
        case .rejected, .failed: "Not sent · check camera"
        case .superseded: nil
        case .pending, .accepted, .timedOut, .outcomeUnknown: "No confirmation · check camera"
        }
    }

    /// The group line: every target confirmed and every camera in the requested state, or how many did.
    public static func summary(_ result: RecordResult, allMatch: Bool) -> String {
        let targets = result.plan.targets.count
        if result.confirmed == targets && allMatch {
            return result.plan.direction == .start
                ? "Recording on \(result.confirmed) cameras" : "Recording stopped"
        }
        return "\(result.confirmed) of \(targets) confirmed · check camera tiles"
    }
}
