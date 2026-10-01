import OpenCineCore
import OpenCineMulticam

extension MulticamSnapshot {
    /// The engine's input gathered from live sessions of any integration, the way an app gathers
    /// it: one current snapshot per session, the app's picture health and busy entries, and one
    /// `now` for all of them.
    ///
    /// `now` must be on the same monotonic reference as every session's own clock. Today the
    /// three integrations use three references (see README.md, Seam findings, F1), so a cross-brand app
    /// cannot satisfy this yet.
    public static func gather(
        _ sessions: [any CameraSession], pictures: [StreamID: PictureHealth] = [:],
        busy: Set<MonitorEntryID> = [], now: MonotonicInstant
    ) async -> MulticamSnapshot {
        var cameras: [CameraSnapshot] = []
        for session in sessions {
            if let snapshot = await session.currentSnapshot() { cameras.append(snapshot) }
        }
        return MulticamSnapshot(cameras: cameras, pictures: pictures, busy: busy, now: now)
    }
}

/// `[CameraSessionID: any CameraSession]` for `RecordPlan.submit` and `RecordSubmission`.
public func sessionMap(_ sessions: [any CameraSession]) -> [CameraSessionID: any CameraSession] {
    Dictionary(sessions.map { ($0.id, $0) }) { _, last in last }
}
