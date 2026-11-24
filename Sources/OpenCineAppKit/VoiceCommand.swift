import Foundation
import Observation
import OpenCineCore

public enum VoiceCommand: Equatable, Sendable {
    public enum Lens: Sendable {
        case wide, tele

        public var label: String { self == .wide ? "1× wide lens" : "3× tele lens" }

        public var confirmation: String { "Selected the \(label)." }
    }

    case start
    case stop
    case preset(Int)
    case nextPreset
    case previousPreset
    case switchLens

    private static let phrases: [String: Self] = [
        "start": .start, "record": .start, "stop": .stop,
        "load next": .nextPreset, "load previous": .previousPreset,
        "switch lens": .switchLens, "change lens": .switchLens,
    ]

    private static let spokenPresetNumbers = ["one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
        "six": 6, "seven": 7, "eight": 8, "nine": 9]

    public static func parse(_ utterance: String) -> Self? {
        let words = tokens(utterance)
        guard words.first == "camera" else { return nil }
        if let command = phrases[words.dropFirst().joined(separator: " ")] { return command }
        // Keep hyphens in preset phrases so a negative number cannot become a positive one.
        let preset = utterance.lowercased().split { $0.isWhitespace || ",.!?".contains($0) }
        guard preset.count == 3, preset[0] == "camera", preset[1] == "load" || preset[1] == "preset"
        else { return nil }
        let name = preset[2]
        if let number = spokenPresetNumbers[String(name)] { return .preset(number) }
        guard let number = Int32(name), number > 0, String(number) == name else { return nil }
        return .preset(Int(number))
    }

    package static func isWakeWord(_ utterance: String) -> Bool { tokens(utterance) == ["camera"] }

    package static func tokens(_ utterance: String) -> [Substring] {
        utterance.lowercased().split { $0.isWhitespace || ",.!?-".contains($0) }
    }

    public var changesSettings: Bool {
        switch self {
        case .preset, .nextPreset, .previousPreset, .switchLens: true
        case .start, .stop: false
        }
    }

    package var recordingConfirmation: String? {
        switch self {
        case .start: "Recording started."
        case .stop: "Recording stopped."
        case .preset, .nextPreset, .previousPreset, .switchLens: nil
        }
    }

    package func isConfirmation(_ message: String) -> Bool {
        if self == .switchLens {
            return message == Lens.wide.confirmation || message == Lens.tele.confirmation
        }
        return message == recordingConfirmation
    }

    public func allows(_ snapshot: CameraSnapshot) -> Bool {
        guard VoiceControlTarget(snapshot)?.recording == (self == .stop ? .recording : .idle)
        else { return false }
        switch self {
        case .start, .stop:
            let intent: CameraCommandIntent = self == .start ? .startRecording : .stopRecording
            return snapshot.rejection(of: CameraCommand(intent, preconditions: .init(snapshot)), at: .now()) == nil
        case .preset, .nextPreset, .previousPreset, .switchLens:
            return true
        }
    }
}

@available(macOS 14, *)
extension MonitorControlModel {
    /// The platform recognizer has already matched a phrase. Use the same editor, outcome and
    /// per-setting recall paths as manual control, with the caller's native queue admission.
    public func executeVoiceCommand(
        _ command: VoiceCommand, target: VoiceControlTarget, presets: CameraSettingsPresetsModel,
        admission: CommandDispatchAdmission, switchLens: (() async -> String)? = nil
    ) async -> String {
        guard !recordPending, voiceTarget == target, let session,
            let fresh = await session.currentSnapshot(), voiceTarget == target,
            VoiceControlTarget(fresh) == target, command.allows(fresh), !recordPending
        else { return "Command unavailable in the current camera state." }

        switch command {
        case .start, .stop:
            guard let editor = recordEditor(), editor.recording == (command == .stop),
                let receipt = await commitRecordAndWait(from: editor, admission: admission)
            else { return "The recording command was not sent." }
            if receipt.stage == .confirmed, let confirmation = command.recordingConfirmation {
                return confirmation
            }
            return Self.note(for: receipt.stage, command == .stop ? "Stop" : "Record")
                ?? "The recording command was not confirmed."
        case .preset(let number):
            let name = "Preset \(number)"
            guard let preset = presets.presets.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }),
                let recall = await presets.recall(preset, admission: admission)
            else { return "\(name) is unavailable." }
            return CameraSettingsPresetCopy.result(recall)
        case .nextPreset, .previousPreset:
            return await presets.recallAdjacent(next: command == .nextPreset, admission: admission)
        case .switchLens:
            return await switchLens?() ?? "Lens switching is unavailable for this camera."
        }
    }
}

/// The observed facts that retire a voice command while waiting for a native queue. Property
/// readbacks and timecode ticks leave the target intact, including during a preset recall.
public struct VoiceControlTarget: Equatable, Sendable {
    public let session: CameraSessionID
    public let epoch: ControlEpoch
    public let mode: CaptureMode
    public let recording: RecordingState?

    public init?(_ snapshot: CameraSnapshot) {
        guard snapshot.connection == .ready, snapshot.authority == .owner,
            snapshot.mode.validity == .valid, let mode = snapshot.mode.value, mode.role == .video
        else { return nil }
        session = snapshot.session
        epoch = snapshot.epoch
        self.mode = mode
        recording = snapshot.recording.origin == .cameraReported && snapshot.recording.validity == .valid
            ? snapshot.recording.value : nil
    }
}

/// A thread-safe revocation that can travel into a vendor's native command queue.
public final class VoiceCommandPermit: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true

    @available(macOS 14, *)
    @MainActor
    public init(while permitted: () -> Bool) {
        let eligible = withObservationTracking(permitted, onChange: { [weak self] in self?.revoke() })
        if !eligible { revoke() }
    }

    public var isCurrent: Bool {
        lock.lock()
        defer { lock.unlock() }
        return active
    }

    public func revoke() {
        lock.lock()
        defer { lock.unlock() }
        active = false
    }
}

/// Times are seconds on a single monotonically increasing recognition timeline.
public struct VoiceUtteranceGate: Sendable {
    private var consumedThrough = -Double.infinity

    public init() {}

    public mutating func accept(_ text: String, start: Double, end: Double, now: Double) -> VoiceCommand? {
        guard start.isFinite, end.isFinite, now.isFinite,
            start >= 0, end > start, start >= consumedThrough, end <= now, now - end <= 3
        else { return nil }
        consumedThrough = end
        return VoiceCommand.parse(text)
    }
}
