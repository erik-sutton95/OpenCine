import Foundation
import OpenCineCore
import OpenCineMulticam

/// What the app reads from its camera for one tile; the coordinator adds what the stage owns
/// (tally, notes, status, actions). Kotlin twin: `MultiviewTileReadings`.
public struct MultiviewTileReadings {
    public var name: String
    public var model: String
    public var format: String
    public var storage: String
    public var timecode: String?
    public var readouts: [MultiviewReadout]
    /// The camera's take length, nil while it reports none.
    public var recordingSeconds: Int?
    public var power: PowerStatus?
    /// A picture has arrived on the member's current link.
    public var hasPicture: Bool
    public var accessibilityValue: String

    public init(
        name: String, model: String = "", format: String = "",
        storage: String = MultiviewTally.unavailable, timecode: String? = nil,
        readouts: [MultiviewReadout] = [], recordingSeconds: Int? = nil, power: PowerStatus? = nil,
        hasPicture: Bool, accessibilityValue: String = ""
    ) {
        self.name = name
        self.model = model
        self.format = format
        self.storage = storage
        self.timecode = timecode
        self.readouts = readouts
        self.recordingSeconds = recordingSeconds
        self.power = power
        self.hasPicture = hasPicture
        self.accessibilityValue = accessibilityValue
    }
}

extension MultiviewCameraAction {
    /// The stage's own camera options beside `liveView`.
    public static let record = "record"
    public static let lut = "lut"
    public static let reconnect = "reconnect"
    public static let experimental = "experimental"
    public static let remove = "remove"
}

extension MultiviewTile {
    /// The note on the tile itself: the plain record confirmations (`RecordAll`'s confirmed
    /// notes) stay in the options only.
    public static func tileNote(_ note: String?) -> String? {
        note == RecordAll.note(.confirmed, direction: .start)
            || note == RecordAll.note(.confirmed, direction: .stop) ? nil : note
    }
}

/// A record command's confirmation window on one camera: a refusal ends it, the camera's own
/// newer report of the asked state confirms it, the window closing leaves it unconfirmed. Nothing
/// is resent. Kotlin twin: `MultiviewRecordConfirmation`.
public enum MultiviewRecordConfirmation {
    public enum Outcome: Hashable, Sendable {
        case confirmed
        case refused
        /// The window closed, or the link was replaced, without a confirmation.
        case unconfirmed
    }

    /// The stage's window: a reply or a matching report within 8 s.
    public static let window: Duration = .seconds(8)

    /// Polls every 100 ms on `clock` until the window closes.
    /// - Parameters:
    ///   - current: the command's link is still the member's.
    ///   - reply: the camera's reply to the command so far: true accepted, false refused.
    ///   - report: the camera's latest take report.
    ///   - acknowledged: called once when the camera accepted the command.
    @MainActor
    public static func wait(
        start: Bool, sentAt: Date, window: Duration = window, clock: HostClock,
        current: @MainActor () -> Bool, reply: @MainActor () -> Bool?,
        report: @MainActor () -> MultiviewRecordReport?, acknowledged: @MainActor () -> Void
    ) async -> Outcome {
        let deadline = clock.now() + window
        var accepted = false
        while clock.now() < deadline {
            try? await clock.sleep(.milliseconds(100))
            guard current() else { return .unconfirmed }
            if let answer = reply() {
                if !answer { return .refused }
                if !accepted {
                    accepted = true
                    acknowledged()
                }
            }
            if let latest = report(), latest.receivedAt > sentAt, latest.recording == start {
                return .confirmed
            }
        }
        return .unconfirmed
    }
}

@available(macOS 14, *)
extension MultiviewCoordinator {
    /// The camera's last reported take state on `slot`, nil until it reported one.
    public func recordingActive(slot: Int) -> Bool? { links[slot].recordReport?.recording }

    public var anyRecording: Bool {
        members.indices.contains { members[$0].camera != nil && recordingActive(slot: $0) == true }
    }

    /// Slots with a camera, in order.
    public var memberSlots: [Int] { members.indices.filter { members[$0].camera != nil } }

    public var canRecordTogether: Bool {
        !busy && !groupRecordingBusy && recordPlan(slot: nil).isExecutable
    }

    private func entry(_ slot: Int) -> MonitorEntryDescriptor? {
        guard let camera = members[slot].camera else { return nil }
        let name = describe(camera).name
        return MonitorEntryDescriptor(
            id: members[slot].entryID, name: name,
            picture: PictureSourceDescriptor(stream: members[slot].stream, label: name),
            cameraSession: links[slot].session.id, telemetry: .cameraSession,
            controlAuthority: .owner)
    }

    /// The engine's view of `slots` (default: every member), in slot order. A one-member view
    /// equals the full view for that member's plans and leases.
    public func multicamGroup(of slots: [Int]? = nil) -> MulticamGroup {
        var group = MulticamGroup()
        for slot in slots ?? memberSlots {
            if let entry = entry(slot) { try? group.add(entry) }
        }
        return group
    }

    public func multicamSnapshot(of slots: [Int]? = nil) -> MulticamSnapshot {
        let chosen = (slots ?? memberSlots).filter { members[$0].camera != nil }
        return MulticamSnapshot(
            cameras: chosen.map { links[$0].snapshot },
            pictures: Dictionary(
                uniqueKeysWithValues: chosen.map { (members[$0].stream, links[$0].pictureHealth) }),
            busy: Set(
                chosen.filter {
                    members[$0].recordingBusy || members[$0].connecting || members[$0].recovering
                }.map { members[$0].entryID }),
            now: clock.now())
    }

    /// The operator's record press as an explicit strict plan: stop when any requested camera
    /// reports recording, else start. `slot == nil` is every member.
    public func recordPlan(slot: Int?) -> RecordPlan {
        let requested = slot.map { [$0] } ?? memberSlots
        let entries = requested.map { members[$0].entryID }
        return RecordAll.plan(
            entries,
            recording: { id in
                requested.contains { self.members[$0].entryID == id && self.recordingActive(slot: $0) == true }
            },
            in: multicamGroup(of: requested), at: multicamSnapshot(of: requested))
    }

    /// The record plan for every member (`nil`) or one slot, with what blocks it now.
    public func recordContext(slot: Int?) -> MultiviewRecordContext {
        MultiviewRecordContext(
            plan: recordPlan(slot: slot), busy: busy || groupRecordingBusy, closing: closing)
    }

    /// Sends an approved plan: one explicit start or stop per camera, revalidated first, each
    /// outcome on its own member. A partial result is never compensated.
    public func record(_ plan: RecordPlan, together: Bool) async {
        guard !busy, !closing, !groupRecordingBusy else { return }
        if together {
            groupRecordingBusy = true
            groupRecordingNote = RecordAll.progress(plan.direction)
        }
        defer { if together { groupRecordingBusy = false } }
        let sessions = Dictionary(
            memberSlots.map { (links[$0].session.id, links[$0].session) }) { first, _ in first }
        guard
            let result = await RecordAll.run(
                plan, in: multicamGroup(), at: multicamSnapshot(), sessions: sessions)
        else {
            // Stale: a camera, link or mode changed after the operator approved.
            if together { groupRecordingNote = RecordAll.changed }
            return
        }
        let group = multicamGroup()
        for member in members {
            guard let outcome = result.outcome(for: member.entryID, in: group),
                let note = RecordAll.note(outcome, direction: plan.direction)
            else { continue }
            member.recordingNote = note
        }
        guard together else { return }
        let start = plan.direction == .start
        let allMatch = memberSlots.allSatisfy {
            members[$0].recordingAvailable && recordingActive(slot: $0) == start
        }
        groupRecordingNote = RecordAll.summary(result, allMatch: allMatch)
    }

    /// The stage's values for `slot`, nil while it is empty: the app's readings with the tally,
    /// notes, status and options the stage owns.
    public func tile(_ slot: Int, _ readings: MultiviewTileReadings) -> MultiviewTile? {
        let member = members[slot]
        guard let camera = member.camera else { return nil }
        let preview = policy.hasPreview(camera)
        let settled = !busy && !member.connecting && !member.recovering
        let recording = recordingActive(slot: slot)
        var actions = [
            MultiviewCameraAction(
                MultiviewCameraAction.liveView, "Live View",
                enabled: member.controlHost != nil && !member.recovering),
            MultiviewCameraAction(
                MultiviewCameraAction.record,
                recording == true ? "Stop recording" : "Start recording", kind: .record,
                enabled: member.recordingAvailable && !member.recordingBusy && !groupRecordingBusy
                    && !closing),
            MultiviewCameraAction(
                MultiviewCameraAction.lut,
                member.lutEnabled ? "Disable Auto LUT" : "Enable Auto LUT", enabled: preview),
        ]
        if preview || member.failureMessage != nil {
            actions.append(
                MultiviewCameraAction(
                    MultiviewCameraAction.reconnect, "Reconnect", enabled: settled, closes: true))
        }
        if member.failureMessage != nil, !member.experimental, member.identity == nil {
            actions.append(
                MultiviewCameraAction(
                    MultiviewCameraAction.experimental, "Try experimental shared Wi-Fi",
                    enabled: settled, closes: true))
        }
        actions.append(
            MultiviewCameraAction(
                MultiviewCameraAction.remove, "Remove camera", kind: .destructive,
                enabled: !(busy || member.connecting || groupRecordingBusy || member.recordingBusy
                    || closing)))
        let note = member.recordingNote
        let showsStatus = !readings.hasPicture || member.failureMessage != nil || member.recovering
        return MultiviewTile(
            name: readings.name, model: readings.model, format: readings.format,
            storage: readings.storage, timecode: readings.timecode,
            tally: MultiviewTally.text(
                recording: recording, seconds: readings.recordingSeconds,
                waiting: member.recordingBusy, holding: member.recovering,
                failed: member.failureMessage != nil),
            recording: recording == true, lut: member.lutEnabled, note: note,
            tileNote: MultiviewTile.tileNote(note), readouts: readings.readouts,
            status: showsStatus
                ? MultiviewTileStatus(
                    text: member.recovering
                        ? "Restoring picture…"
                        : member.failureMessage == nil ? member.status : "Connection failed · Options",
                    detail: member.failureMessage ?? member.status,
                    inProgress: member.recovering
                        || (member.failureMessage == nil && !member.networkVerified))
                : nil,
            detail: member.status, failure: member.failureMessage,
            footnote: member.networkVerified && !preview
                ? "Remove this camera to enable group recording for your other cameras." : nil,
            actions: actions, accessibilityValue: readings.accessibilityValue
        ).withPower(readings.power)
    }
}
