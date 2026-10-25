import Foundation

/// The host's key-value store; every value is an opaque JSON `Data` payload.
public protocol GyroKeyValueStore: AnyObject {
    /// Returns the stored payload, or nil when the key is absent.
    func data(forKey key: String) -> Data?
    /// Stores the payload, or removes the key when the payload is nil.
    func setData(_ data: Data?, forKey key: String)
}

/// Namespaced keys for the gyro preferences this module owns.
public struct GyroPreferenceKeys: Equatable, Sendable {
    /// Whether gyro logging is enabled.
    public let enabled: String
    /// Per-camera calibrations, stored as one JSON object keyed by camera id.
    public let calibrations: String
    /// Stabilization restores the app still owes.
    public let pendingRestores: String
    /// Whether the logs tip was dismissed.
    public let tipDismissed: String
    /// A legacy global calibration waiting for the first camera id that asks.
    public let legacyCalibration: String
    /// Set once the legacy migration ran.
    public let migrated: String

    /// Builds the key set under a host prefix, for example a bundle namespace.
    public static func namespaced(_ prefix: String) -> Self {
        Self(
            enabled: prefix + "enabled",
            calibrations: prefix + "calibrations",
            pendingRestores: prefix + "pendingRestores",
            tipDismissed: prefix + "tipDismissed",
            legacyCalibration: prefix + "legacyCalibration",
            migrated: prefix + "migrated")
    }
}

/// Old app-wide keys read once when calibrations became per-camera.
public struct GyroLegacyPreferenceKeys: Equatable, Sendable {
    /// Old app-wide enabled flag.
    public let enabled: String
    /// Old manual mount preset, dropped when presets became "not calibrated".
    public let mountPreset: String
    /// Old global calibration, adopted by the first camera that has none.
    public let calibration: String

    /// Creates the legacy key set for one host.
    public init(enabled: String, mountPreset: String, calibration: String) {
        self.enabled = enabled
        self.mountPreset = mountPreset
        self.calibration = calibration
    }
}

/// Host-persisted gyro preferences: the toggle, the logs tip and per-camera state.
public final class GyroPreferences {
    private let store: any GyroKeyValueStore
    private let keys: GyroPreferenceKeys

    /// Creates preferences over a host store and runs the legacy migration once.
    public init(
        store: any GyroKeyValueStore, keys: GyroPreferenceKeys,
        legacy: GyroLegacyPreferenceKeys?
    ) {
        self.store = store
        self.keys = keys
        if let legacy, store.data(forKey: keys.migrated) == nil {
            migrate(legacy)
        }
    }

    /// Whether gyro logging is enabled; false by default.
    public var enabled: Bool {
        get { bool(forKey: keys.enabled) ?? false }
        set { store.setData(encoded(newValue), forKey: keys.enabled) }
    }

    /// Whether the logs tip was dismissed; false by default.
    public var tipDismissed: Bool {
        get { bool(forKey: keys.tipDismissed) ?? false }
        set { store.setData(encoded(newValue), forKey: keys.tipDismissed) }
    }

    /// Stabilization restores the app still owes; empty by default.
    public var pendingRestores: [GyroPendingRestore] {
        get {
            guard let data = store.data(forKey: keys.pendingRestores) else { return [] }
            return (try? JSONDecoder().decode([GyroPendingRestore].self, from: data)) ?? []
        }
        set { store.setData(try? JSONEncoder().encode(newValue), forKey: keys.pendingRestores) }
    }

    /// Returns the saved calibration for a camera, adopting a valid legacy one once.
    public func calibration(for cameraID: String) -> GyroMountCalibration? {
        var object = calibrationObject()
        if let value = object[cameraID] {
            if let calibration = decodeCalibration(value) {
                return calibration
            }
            object.removeValue(forKey: cameraID)
            write(object)
            return nil
        }
        guard let data = store.data(forKey: keys.legacyCalibration) else { return nil }
        store.setData(nil, forKey: keys.legacyCalibration)
        guard let calibration = try? JSONDecoder().decode(GyroMountCalibration.self, from: data)
        else { return nil }
        if let value = encodedJSONValue(calibration) {
            object[cameraID] = value
        }
        write(object)
        return calibration
    }

    /// Stores a calibration for one camera id, keeping the other cameras' calibrations.
    public func saveCalibration(_ calibration: GyroMountCalibration, for cameraID: String) {
        var object = calibrationObject()
        if let value = encodedJSONValue(calibration) {
            object[cameraID] = value
        }
        write(object)
    }

    private func migrate(_ legacy: GyroLegacyPreferenceKeys) {
        if let enabled = bool(forKey: legacy.enabled) {
            store.setData(encoded(enabled), forKey: keys.enabled)
        }
        store.setData(nil, forKey: legacy.mountPreset)
        if let data = store.data(forKey: legacy.calibration) {
            store.setData(nil, forKey: legacy.calibration)
            if (try? JSONDecoder().decode(GyroMountCalibration.self, from: data)) != nil {
                store.setData(data, forKey: keys.legacyCalibration)
            }
        }
        store.setData(encoded(true), forKey: keys.migrated)
    }

    private func bool(forKey key: String) -> Bool? {
        guard let data = store.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(Bool.self, from: data)
    }

    private func encoded(_ value: Bool) -> Data? {
        try? JSONEncoder().encode(value)
    }

    private func calibrationObject() -> [String: Any] {
        guard let data = store.data(forKey: keys.calibrations),
            let object = try? JSONSerialization.jsonObject(with: data),
            let values = object as? [String: Any]
        else { return [:] }
        return values
    }

    private func decodeCalibration(_ value: Any) -> GyroMountCalibration? {
        guard
            let data = try? JSONSerialization.data(
                withJSONObject: value, options: [.fragmentsAllowed])
        else { return nil }
        return try? JSONDecoder().decode(GyroMountCalibration.self, from: data)
    }

    private func encodedJSONValue(_ calibration: GyroMountCalibration) -> Any? {
        guard let data = try? JSONEncoder().encode(calibration) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private func write(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        store.setData(data, forKey: keys.calibrations)
    }
}
