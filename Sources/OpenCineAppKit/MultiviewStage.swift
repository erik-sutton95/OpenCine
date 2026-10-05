import Foundation
import OpenCineCore
import OpenCineMulticam

/// One camera value: the stage's program readouts and Grid's in-tile row.
public struct MultiviewReadout: Hashable, Sendable {
    public var title: String
    public var value: String
    /// What the camera advertises for this value, in order. Empty: not settable from the stage.
    /// Picking one calls the stage's `choose` action; the camera's readback decides what shows.
    public var choices: [String]

    public init(title: String, value: String, choices: [String] = []) {
        self.title = title
        self.value = value
        self.choices = choices
    }
}

/// The pill over a tile's picture while it is not live.
public struct MultiviewTileStatus: Hashable, Sendable {
    public var text: String
    public var accessibilityLabel: String
    /// Shows a spinner: the app is still working on it.
    public var inProgress: Bool

    public init(text: String, accessibilityLabel: String? = nil, inProgress: Bool) {
        self.text = text
        self.accessibilityLabel = accessibilityLabel ?? text
        self.inProgress = inProgress
    }
}

/// One entry of a camera's options. `.record` opens the stage's record confirmation for that
/// camera; every other kind calls the stage's `perform` action with `id`.
public struct MultiviewCameraAction: Hashable, Sendable, Identifiable {
    public enum Kind: Hashable, Sendable {
        case action
        case record
        case destructive
    }

    public var id: String
    public var title: String
    public var kind: Kind
    public var enabled: Bool

    public init(_ id: String, _ title: String, kind: Kind = .action, enabled: Bool = true) {
        self.id = id
        self.title = title
        self.kind = kind
        self.enabled = enabled
    }

    /// The id the stage's double tap and the Live View entry share.
    public static let liveView = "liveView"
}

/// One occupied slot as the app sees it now. Values only: the app maps its camera state, the
/// stage never reads a session.
public struct MultiviewTile: Hashable, Sendable {
    public var name: String
    public var model: String
    /// Resolution, rate and look, on roomy tiles and in the options.
    public var format: String
    /// 0...100, `nil` when unknown.
    public var battery: Int?
    public var charging: Bool
    public var storage: String
    public var timecode: String?
    /// `MultiviewTally` copy, or the app's own.
    public var tally: String
    /// Set while a take runs that the camera does not time: the tally counts from here.
    public var recordingSince: Date?
    /// Camera-reported recording: red tally and the recording border.
    public var recording: Bool
    public var lut: Bool
    /// The last result worth showing (a refused value, a failed start), in the options.
    public var note: String?
    /// The note on the tile itself, `nil` to keep the tile quiet.
    public var tileNote: String?
    public var readouts: [MultiviewReadout]
    /// Over the picture while it is not live.
    public var status: MultiviewTileStatus?
    /// The options' link line, a failure and a footnote.
    public var detail: String
    public var failure: String?
    public var footnote: String?
    public var actions: [MultiviewCameraAction]
    /// What VoiceOver reads after the slot letter.
    public var accessibilityValue: String

    public init(
        name: String, model: String = "", format: String = "", battery: Int? = nil,
        charging: Bool = false, storage: String = MultiviewTally.unavailable,
        timecode: String? = nil, tally: String = MultiviewTally.unavailable,
        recordingSince: Date? = nil, recording: Bool = false, lut: Bool = false,
        note: String? = nil, tileNote: String? = nil, readouts: [MultiviewReadout] = [], status: MultiviewTileStatus? = nil,
        detail: String = "", failure: String? = nil, footnote: String? = nil,
        actions: [MultiviewCameraAction] = [], accessibilityValue: String = ""
    ) {
        self.name = name
        self.model = model
        self.format = format
        self.battery = battery
        self.charging = charging
        self.storage = storage
        self.timecode = timecode
        self.tally = tally
        self.recordingSince = recordingSince
        self.recording = recording
        self.lut = lut
        self.note = note
        self.tileNote = tileNote
        self.readouts = readouts
        self.status = status
        self.detail = detail
        self.failure = failure
        self.footnote = footnote
        self.actions = actions
        self.accessibilityValue = accessibilityValue
    }

    /// The slot letter, A for the first.
    public static func letter(_ slot: Int) -> String {
        String(UnicodeScalar(UInt8(65 + min(25, max(0, slot)))))
    }
}

/// The tally copy. Only what the camera reported: no clock of the stage's own.
public enum MultiviewTally {
    /// An unknown value. Never a guess.
    public static let unavailable = "\u{2014}"

    /// `waiting`: a record command is in flight; `holding`: the picture is being restored;
    /// `failed`: the link needs attention. `seconds` is the camera's take length, `nil` while
    /// it reports none.
    public static func text(
        recording: Bool?, seconds: Int? = nil, waiting: Bool = false, holding: Bool = false,
        failed: Bool = false
    ) -> String {
        if waiting { return "WAIT" }
        if holding { return "HOLD" }
        if failed { return "CHECK" }
        guard let recording else { return unavailable }
        guard recording else { return "STBY" }
        return seconds.map(running) ?? "REC"
    }

    /// `REC mm:ss`.
    public static func running(_ seconds: Int) -> String {
        let seconds = max(0, seconds)
        return String(format: "REC %02d:%02d", seconds / 60, seconds % 60)
    }
}

/// The stage's assist tools, in palette order. Apps list the ones they offer.
public enum MultiviewTool: String, CaseIterable, Sendable {
    case layout = "LAYOUT"
    case camera = "CAMERA"
    case fit = "FIT"
    case lut = "LUT"
}

/// One camera the Add camera list offers.
public struct MultiviewPickerRow: Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String
    /// Under the title: why it cannot join, or how it will.
    public var detail: String?
    public var enabled: Bool
    /// Joins without its picture: an info glyph instead of the plus.
    public var limited: Bool

    public init(
        id: String, title: String, detail: String? = nil, enabled: Bool = true,
        limited: Bool = false
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.enabled = enabled
        self.limited = limited
    }
}

/// A record confirmation applies to the plan the operator saw: the same cameras, sessions,
/// links (control epochs), modes, command availability and reported recording states, as the
/// engine's admission fingerprint records them. Timestamps and routine telemetry are excluded so
/// refreshes do not dismiss it; a replacement link, a changed camera or availability does.
public struct MultiviewRecordContext: Hashable, Sendable {
    public let plan: RecordPlan
    public let busy: Bool
    public let closing: Bool

    public init(plan: RecordPlan, busy: Bool = false, closing: Bool = false) {
        self.plan = plan
        self.busy = busy
        self.closing = closing
    }

    public var stopping: Bool { plan.direction == .stop }
    /// Nothing in flight, not closing, and the plan commands at least one camera.
    public var canConfirm: Bool { !busy && !closing && plan.isExecutable }

    /// Why the plan is refused, for the disabled control's accessibility hint.
    public var refusal: String? {
        guard plan.isRefused, let reason = plan.exclusions.first?.reason else { return nil }
        switch reason {
        case .busy, .cameraTransitioning: return "A camera is busy."
        case .rejected(.recordingStateUnknown): return "Waiting for a camera's record state."
        case .rejected(.unavailable(.mode)): return "A camera is not in a video mode."
        default: return "A camera is not connected."
        }
    }

    /// The confirmation question for every camera, or for one (`single`).
    public func question(single: Bool) -> String {
        single
            ? (stopping ? "Stop recording?" : "Start recording?")
            : (stopping ? "Stop recording on all cameras?" : "Record on all cameras?")
    }

    /// A group command is coordinated dispatch, not synchronized recording.
    public static let groupNote =
        "Each camera confirms independently; recording is not synchronized."
}

extension MultiviewTile {
    /// A tile from Core values alone, for an app whose cameras report only through their
    /// `CameraSession`: battery, take state, timecode and the common settings. What the camera
    /// has not reported stays unavailable.
    public init(
        _ entry: MonitorEntryDescriptor, summary: EntrySummary, snapshot: CameraSnapshot?,
        waiting: Bool = false
    ) {
        let unknown = MultiviewTally.unavailable
        func value(_ key: SettingKey) -> MultiviewReadout {
            MultiviewReadout(
                title: MonitorCapturePresentation.title(key) ?? "",
                value: snapshot?.value(of: key).value.map(MonitorCapturePresentation.label)
                    ?? unknown)
        }
        let recording = summary.recording.value.map { $0 == .recording || $0 == .transitioning }
        let control: ConnectionState? =
            if case .reported(let state) = summary.control { state } else { nil }
        self.init(
            name: entry.name,
            battery: snapshot?.power.battery.value.map { Int(($0 * 100).rounded()) },
            charging: snapshot?.power.charging.value ?? false,
            timecode: snapshot?.timecode.value.map {
                String(format: "%02d:%02d:%02d", $0.hours, $0.minutes, $0.seconds)
            },
            tally: MultiviewTally.text(
                recording: recording, waiting: waiting,
                failed: control.map { if case .disconnected = $0 { true } else { false } } ?? false),
            recording: summary.recording.value == .recording,
            readouts: [value(.iso), value(.shutter), value(.whiteBalance), value(.focusMode)],
            status: control == .ready
                ? nil : MultiviewTileStatus(text: "Connecting…", inProgress: true),
            detail: control == .ready ? "Connected" : "Connecting…",
            actions: [
                MultiviewCameraAction(MultiviewCameraAction.liveView, "Live View"),
                MultiviewCameraAction(
                    "record", summary.recording.value == .recording ? "Stop recording" : "Start recording",
                    kind: .record),
                MultiviewCameraAction("remove", "Remove camera", kind: .destructive),
            ])
    }
}
