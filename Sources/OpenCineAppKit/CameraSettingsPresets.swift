import Foundation
import Observation
import OpenCineCore

/// Operator copy for exposure and white balance presets. Kotlin twin: `CameraSettingsPresetCopy`.
public enum CameraSettingsPresetCopy {
    public static let title = "Camera presets"
    public static let help =
        "Save this camera's exposure and white balance, then recall them later. A recall sets only what the connected camera offers."
    public static let connectFirst = "Connect a camera to save or recall its presets."
    public static let nothingToSave =
        "This camera reports no exposure or white balance it can set right now."
    public static let empty = "No presets saved for this camera model yet."

    public static func title(_ key: SettingKey) -> String {
        switch key {
        case .iso: "ISO"
        case .shutter: "Shutter"
        case .aperture: "Aperture"
        case .exposureCompensation: "EV"
        case .whiteBalance: "White balance"
        case .whiteBalanceTint: "Tint"
        default: key.rawValue
        }
    }

    public static func value(_ value: SettingValue) -> String {
        if case .whiteBalanceTint(let tint) = value {
            let text = String(format: "%g", locale: Locale(identifier: "en_US_POSIX"), tint)
            return tint > 0 ? "+\(text)" : text
        }
        return MonitorCapturePresentation.label(value)
    }

    /// One line naming what a preset holds: "ISO 800 · 1/50 · WB 5600K".
    public static func summary(_ preset: CameraSettingsPreset) -> String {
        preset.values.map { value in
            switch value.key {
            case .iso: "ISO \(Self.value(value))"
            case .exposureCompensation: "EV \(Self.value(value))"
            case .whiteBalance: "WB \(Self.value(value))"
            case .whiteBalanceTint: "Tint \(Self.value(value))"
            default: Self.value(value)
            }
        }.joined(separator: " · ")
    }

    public static func skip(_ skip: CameraSettingsPresetSkip) -> String {
        switch skip {
        case .unsupported: "not offered by this camera"
        case .readOnly: "read-only on this camera"
        case .outOfDomain: "value not offered by this camera"
        case .unavailable(.mode): "not available in this mode"
        case .unavailable(.recordingActive): "not available while recording"
        case .unavailable(.otherSetting(let key)): "needs \(title(key)) first"
        case .unavailable: "not available right now"
        }
    }

    public static func failure(_ stage: CommandStage) -> String {
        switch stage {
        case .rejected(.cameraRefused): "refused by the camera"
        case .rejected(.sessionClosed), .rejected(.notConnected), .rejected(.wrongSession): "camera not connected"
        case .rejected(.noAuthority), .rejected(.authorityExpired): "no control of the camera"
        case .rejected: "not sent"
        case .failed(.notApplied): "not applied by the camera"
        case .failed(.superseded): "replaced by a newer change"
        case .failed(.notSent): "not sent"
        case .outcomeUnknown: "link dropped before it confirmed"
        default: "not confirmed by the camera"
        }
    }

    /// The operator's one-line result: what was recalled, what the camera skipped and what failed.
    public static func result(_ recall: CameraSettingsPresetRecall) -> String {
        var text = "Recalled \(recall.name)."
        let skipped = recall.skipped.map { "\(title($0.key)) (\(skip($0.skip)))" }
        if !skipped.isEmpty { text += " Skipped: \(skipped.joined(separator: ", "))." }
        let failed = recall.failed.map { "\(title($0.key)) (\(failure($0.stage)))" }
        if !failed.isEmpty { text += " Not applied: \(failed.joined(separator: ", "))." }
        return text
    }
}

/// Which presets a camera sees: one list per integration and camera model, so every body of the
/// same model shares its presets and another model never offers values it was not saved from.
public enum CameraSettingsPresetScope {
    /// `nil` when the saved camera names no model.
    public static func key(_ camera: SavedCamera) -> String? {
        let model = camera.model.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.isEmpty ? nil : "\(camera.integration.rawValue)/\(model)"
    }
}

/// Saved presets per scope in the app's own `storage`, as `CameraSettingsPresetCodec` text under
/// `prefix` plus the scope. Kotlin twin: `CameraSettingsPresetStore` over `SharedPreferences`.
@available(macOS 14, *)
@MainActor
@Observable
public final class CameraSettingsPresetStore {
    @ObservationIgnored private let storage: UserDefaults
    @ObservationIgnored private let prefix: String
    /// Bumped by every write, so a view listing presets redraws.
    public private(set) var revision = 0

    public init(storage: UserDefaults, prefix: String = "cameraSettingsPresets") {
        precondition(!prefix.isEmpty)
        self.storage = storage
        self.prefix = prefix
    }

    public func presets(scope: String) -> [CameraSettingsPreset] {
        _ = revision
        return storage.string(forKey: key(scope)).map(CameraSettingsPresetCodec.decode) ?? []
    }

    /// Adds `preset`, or replaces the one with the same name (ignoring case) in place.
    public func save(_ preset: CameraSettingsPreset, scope: String) {
        var list = presets(scope: scope)
        if let index = list.firstIndex(where: { $0.name.lowercased() == preset.name.lowercased() }) {
            list[index] = CameraSettingsPreset(id: list[index].id, name: preset.name, values: preset.values)
        } else {
            list.append(preset)
        }
        write(list, scope: scope)
    }

    public func delete(id: String, scope: String) {
        write(presets(scope: scope).filter { $0.id != id }, scope: scope)
    }

    private func write(_ list: [CameraSettingsPreset], scope: String) {
        storage.set(CameraSettingsPresetCodec.encode(list), forKey: key(scope))
        revision += 1
    }

    private func key(_ scope: String) -> String { "\(prefix).\(scope)" }
}

/// The presets of the shell's camera: saves its current exposure and white balance and recalls a
/// preset through the shell's common controls. `admission` supplies the host's dispatch gate for
/// each recall (a remote-control or Multiview owner), `nil` to submit to the session directly.
/// Kotlin twin: `CameraSettingsPresetsModel`.
@available(macOS 14, *)
@MainActor
@Observable
public final class CameraSettingsPresetsModel {
    @ObservationIgnored public let store: CameraSettingsPresetStore
    @ObservationIgnored private let shell: ShellModel
    @ObservationIgnored private let admission: @MainActor () -> CommandDispatchAdmission?
    /// A recall is in flight.
    public private(set) var recalling = false
    /// The last save or recall result for the operator, `nil` until there is one.
    public private(set) var message: String?

    public init(store: CameraSettingsPresetStore, shell: ShellModel,
        admission: @escaping @MainActor () -> CommandDispatchAdmission? = { nil }) {
        self.store = store
        self.shell = shell
        self.admission = admission
    }

    /// The connected camera's preset list; `nil` when no camera with a known model is connected.
    public var scope: String? { shell.monitor.flatMap { CameraSettingsPresetScope.key($0.camera.saved) } }

    public var presets: [CameraSettingsPreset] { scope.map { store.presets(scope: $0) } ?? [] }

    /// Whether the camera reports something a preset could hold right now.
    public var canSave: Bool {
        guard scope != nil, let snapshot = shell.control.snapshot else { return false }
        return CameraSettingsPreset.capture(name: "", from: snapshot) != nil
    }

    public var canRecall: Bool { scope != nil && shell.control.snapshot?.connection == .ready && !recalling }

    /// The name a new preset gets when the operator leaves it empty.
    public var suggestedName: String { "Preset \(presets.count + 1)" }

    /// Saves the camera's current values under `name` (trimmed; empty takes `suggestedName`).
    @discardableResult public func save(name: String) -> CameraSettingsPreset? {
        guard let scope else { message = CameraSettingsPresetCopy.connectFirst; return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let chosen = trimmed.isEmpty ? suggestedName : trimmed
        guard let snapshot = shell.control.snapshot,
            let preset = CameraSettingsPreset.capture(name: chosen, from: snapshot)
        else { message = CameraSettingsPresetCopy.nothingToSave; return nil }
        store.save(preset, scope: scope)
        message = "Saved \(chosen): \(CameraSettingsPresetCopy.summary(preset))."
        return preset
    }

    public func delete(_ preset: CameraSettingsPreset) {
        guard let scope else { return }
        store.delete(id: preset.id, scope: scope)
        message = nil
    }

    /// Recalls `preset` on the connected camera and reports the result in `message`.
    @discardableResult public func recall(_ preset: CameraSettingsPreset) async -> CameraSettingsPresetRecall? {
        guard !recalling else { return nil }
        guard canRecall else { message = CameraSettingsPresetCopy.connectFirst; return nil }
        recalling = true
        message = "Recalling \(preset.name)..."
        let result = await shell.control.recall(preset, admission: admission())
        recalling = false
        message = CameraSettingsPresetCopy.result(result)
        return result
    }
}
