import Foundation
import OpenCineCore

/// What the engine evaluates against at one instant. The app gathers it from the sessions and
/// media runtime it owns; the engine never subscribes to a session or holds a runtime object.
public struct MulticamSnapshot: Sendable {
    /// Latest snapshot of each live camera session.
    public var cameras: [CameraSessionID: CameraSnapshot]
    /// Health of each picture stream the app runs.
    public var pictures: [StreamID: PictureHealth]
    /// Entries with an app-side step still running (a connection step, an earlier record
    /// operation). Group commands exclude them.
    public var busy: Set<MonitorEntryID>
    /// The shared host clock (`MonotonicInstant.now()`), the reference every session stamps on.
    public var now: MonotonicInstant

    public init(
        cameras: [CameraSnapshot] = [], pictures: [StreamID: PictureHealth] = [:],
        busy: Set<MonitorEntryID> = [], now: MonotonicInstant = .now()
    ) {
        self.cameras = Dictionary(cameras.map { ($0.session, $0) }) { _, last in last }
        self.pictures = pictures
        self.busy = busy
        self.now = now
    }
}

public enum MulticamGroupError: Error, Hashable, Sendable {
    case invalidEntry(MonitorEntryError)
    case duplicateEntry(MonitorEntryID)
    case unknownEntry(MonitorEntryID)
}

/// Membership in slot order plus the staged (large) entry. Slots are `MonitorEntryID`s, so
/// reordering, staging, rotation and replacing an entry's picture or session keep them.
///
/// Removing an entry only changes membership. The app owns the entry's session and picture;
/// closing them never stops a camera's recording (Core `CameraSession.close`).
public struct MulticamGroup: Hashable, Sendable {
    public private(set) var entries: [MonitorEntryDescriptor] = []
    public private(set) var stage: MonitorEntryID?

    public init() {}

    public subscript(id: MonitorEntryID) -> MonitorEntryDescriptor? {
        entries.first { $0.id == id }
    }

    /// Adds `entry` at `index` (default: last). Capacity is not checked here: the app's
    /// qualification limit is a `ResourceBudget` value applied by `ResourceAdmission`.
    public mutating func add(_ entry: MonitorEntryDescriptor, at index: Int? = nil)
        throws(MulticamGroupError)
    {
        try Self.validate(entry)
        guard self[entry.id] == nil else { throw .duplicateEntry(entry.id) }
        entries.insert(entry, at: min(max(index ?? entries.count, 0), entries.count))
    }

    /// Replaces an entry's picture, session, authority or name in place, keeping its slot.
    public mutating func update(_ entry: MonitorEntryDescriptor) throws(MulticamGroupError) {
        try Self.validate(entry)
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else {
            throw .unknownEntry(entry.id)
        }
        entries[index] = entry
    }

    public mutating func remove(_ id: MonitorEntryID) {
        entries.removeAll { $0.id == id }
        if stage == id { stage = nil }
    }

    public mutating func move(_ id: MonitorEntryID, to index: Int) throws(MulticamGroupError) {
        guard let from = entries.firstIndex(where: { $0.id == id }) else { throw .unknownEntry(id) }
        let entry = entries.remove(at: from)
        entries.insert(entry, at: min(max(index, 0), entries.count))
    }

    /// Stages an entry (or none). Staging never touches sessions or pictures.
    public mutating func setStage(_ id: MonitorEntryID?) throws(MulticamGroupError) {
        if let id, self[id] == nil { throw .unknownEntry(id) }
        stage = id
    }

    /// Per-entry and aggregate state, with picture health, control-link health, telemetry
    /// freshness and reported recording kept apart. `telemetryMaxAge` is the app's freshness
    /// window.
    public func summary(at state: MulticamSnapshot, telemetryMaxAge: Duration) -> GroupSummary {
        GroupSummary(
            entries: entries.map { EntrySummary($0, at: state, telemetryMaxAge: telemetryMaxAge) })
    }

    private static func validate(_ entry: MonitorEntryDescriptor) throws(MulticamGroupError) {
        do { try entry.validate() } catch { throw .invalidEntry(error) }
    }
}

/// One role of an entry: not part of it, part of it with no report yet, or reported.
public enum RoleStatus<Value: Hashable & Sendable>: Hashable, Sendable {
    case absent
    case unreported
    case reported(Value)
}

public struct EntrySummary: Hashable, Sendable {
    public var entry: MonitorEntryID
    public var session: CameraSessionID?
    public var picture: RoleStatus<PictureHealth>
    public var control: RoleStatus<ConnectionState>
    /// Age of the newest camera report. `.unknown` without a session report.
    public var telemetry: Freshness
    /// Camera-reported only. A failed picture or a pending command never changes it.
    public var recording: ObservedValue<RecordingState>

    public init(_ entry: MonitorEntryDescriptor, at state: MulticamSnapshot, telemetryMaxAge: Duration) {
        self.entry = entry.id
        session = entry.cameraSession
        picture =
            entry.picture.map { state.pictures[$0.stream].map(RoleStatus.reported) ?? .unreported }
            ?? .absent
        let snapshot = entry.cameraSession.flatMap { state.cameras[$0] }
        control =
            entry.cameraSession == nil ? .absent : snapshot.map { .reported($0.connection) } ?? .unreported
        recording = snapshot?.recording ?? .unknown
        // ponytail: newest of the common observations; a snapshot-level "last report" instant in
        // Core would be exact (proposed Core change).
        let newest = snapshot.flatMap {
            [$0.mode.observedAt, $0.recording.observedAt, $0.power.battery.observedAt,
             $0.storage.observedAt].compactMap { $0 }.max()
        }
        if let newest {
            telemetry = state.now - newest <= telemetryMaxAge ? .fresh : .stale
        } else {
            telemetry = .unknown
        }
    }
}

public struct GroupSummary: Hashable, Sendable {
    public var entries: [EntrySummary]

    /// Distinct cameras reporting recording; two entries showing one camera count once.
    public var camerasRecording: Int { cameras { $0.recording.value == .recording } }
    /// Distinct cameras whose recording state is unknown. Never counted as idle.
    public var camerasRecordingUnknown: Int { cameras { !$0.recording.isKnown } }
    public var camerasReady: Int { cameras { $0.control == .reported(.ready) } }
    public var livePictures: Int { entries.filter { $0.picture == .reported(.live) }.count }
    public var staleTelemetry: Int { cameras { $0.telemetry == .stale } }

    private func cameras(_ include: (EntrySummary) -> Bool) -> Int {
        Set(entries.filter(include).compactMap(\.session)).count
    }
}
