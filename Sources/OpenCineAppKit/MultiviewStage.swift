import Foundation
import MonitorPresentation
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

/// Over a tile's picture while it is not live.
public struct MultiviewTileStatus: Hashable, Sendable {
    /// The short line on the tile.
    public var text: String
    /// The full sentence: the status card's text and what assistive technology reads.
    public var detail: String
    /// Shows a spinner: the app is still working on it.
    public var inProgress: Bool
    /// What the status offers as its own buttons, each run through `perform` (the Compose
    /// status card shows them; the SwiftUI pill opens the options instead).
    public var actions: [MultiviewCameraAction]

    public init(
        text: String, detail: String? = nil, inProgress: Bool,
        actions: [MultiviewCameraAction] = []
    ) {
        self.text = text
        self.detail = detail ?? text
        self.inProgress = inProgress
        self.actions = actions
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
    /// The options close before `perform` runs. Options also close once their slot empties.
    public var closes: Bool

    public init(
        _ id: String, _ title: String, kind: Kind = .action, enabled: Bool = true,
        closes: Bool = false
    ) {
        self.id = id
        self.title = title
        self.kind = kind
        self.enabled = enabled
        self.closes = closes
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
    /// 0...100, `nil` when unknown or when the source reports bars instead.
    public var battery: Int?
    public var charging: Bool
    /// Filled steps of the source's coarse gauge, never an inferred percentage.
    public var batteryBars: Int?
    public var batteryBarCount: Int
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
    /// The camera's values, for Grid's in-tile row.
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
        charging: Bool = false, batteryBars: Int? = nil, batteryBarCount: Int = 5,
        storage: String = MultiviewTally.unavailable,
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
        self.batteryBars = batteryBars
        self.batteryBarCount = batteryBarCount
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

/// Slots backed by the host's currently admitted settings and native picture-look adapters.
/// Unknown or missing services are absent; offered tools retain the caller's existing order.
public struct MultiviewToolAvailability: Hashable, Sendable {
    public var cameraSettingsSlots: Set<Int>
    public var pictureLUTSlots: Set<Int>

    public init(cameraSettingsSlots: Set<Int> = [], pictureLUTSlots: Set<Int> = []) {
        self.cameraSettingsSlots = cameraSettingsSlots
        self.pictureLUTSlots = pictureLUTSlots
    }

    /// Intersects executable services with the stage's current occupied, valid tile indices.
    public func offeredTools(
        from requested: [MultiviewTool], occupiedSlots: Set<Int>
    ) -> [MultiviewTool] {
        requested.filter { tool in
            switch tool {
            case .camera: !cameraSettingsSlots.isDisjoint(with: occupiedSlots)
            case .lut: !pictureLUTSlots.isDisjoint(with: occupiedSlots)
            case .layout, .fit: true
            }
        }
    }

    /// The selected settings adapter, or the first currently occupied admitted slot.
    public func cameraSettingsSlot(selected: Int, occupiedSlots: Set<Int>) -> Int? {
        selectedSlot(selected, services: cameraSettingsSlots, occupied: occupiedSlots)
    }

    /// The selected picture-look adapter, or the first currently occupied admitted slot.
    public func pictureLUTSlot(selected: Int, occupiedSlots: Set<Int>) -> Int? {
        selectedSlot(selected, services: pictureLUTSlots, occupied: occupiedSlots)
    }

    private func selectedSlot(_ selected: Int, services: Set<Int>, occupied: Set<Int>) -> Int? {
        let admitted = services.intersection(occupied)
        return admitted.contains(selected) ? selected : admitted.min()
    }
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
    /// The app's own confirmation question (an eligible-subset plan naming the cameras it
    /// commands); `nil` asks the shared `question(single:)`.
    public let prompt: String?

    public init(plan: RecordPlan, busy: Bool = false, closing: Bool = false, prompt: String? = nil) {
        self.plan = plan
        self.busy = busy
        self.closing = closing
        self.prompt = prompt
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
        // The link as reported: a closed session is not connecting, and no report is a wait.
        let link: (status: MultiviewTileStatus?, detail: String) =
            switch control {
            case .ready: (nil, "Connected")
            case .disconnected:
                (MultiviewTileStatus(text: "Disconnected", inProgress: false), "Disconnected")
            case .discovered, .connecting, .recovering:
                (MultiviewTileStatus(text: "Connecting…", inProgress: true), "Connecting…")
            case nil:
                (MultiviewTileStatus(text: "Waiting for the camera", inProgress: true),
                 "Waiting for the camera")
            }
        self.init(
            name: entry.name,
            timecode: MonitorTimecodeFormat.label(snapshot),
            tally: MultiviewTally.text(
                recording: recording, waiting: waiting,
                failed: control.map { if case .disconnected = $0 { true } else { false } } ?? false),
            recording: summary.recording.value == .recording,
            readouts: [value(.iso), value(.shutter), value(.whiteBalance), value(.focusMode)],
            status: link.status, detail: link.detail,
            actions: [
                MultiviewCameraAction(MultiviewCameraAction.liveView, "Live View"),
                MultiviewCameraAction(
                    "record", summary.recording.value == .recording ? "Stop recording" : "Start recording",
                    kind: .record),
                MultiviewCameraAction("remove", "Remove camera", kind: .destructive),
            ])
        self = withPower(snapshot?.power)
    }
}

extension MultiviewTile {
    /// The tile's battery from the camera's typed power: a percent or a declared gauge, never
    /// both, and charging as the live chrome reads it (charging, else external power).
    public func withPower(_ power: PowerStatus?) -> MultiviewTile {
        var tile = self
        tile.battery = nil
        tile.batteryBars = nil
        switch power?.batteryReading {
        case .fraction(let value)?: tile.battery = Int((value * 100).rounded())
        case .steps(let filled, let count)?: tile.batteryBars = filled; tile.batteryBarCount = count
        case nil: break
        }
        tile.charging = power.flatMap { $0.charging.value ?? $0.externalPower.value } ?? false
        return tile
    }
}
