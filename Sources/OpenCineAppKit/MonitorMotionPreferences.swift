import Foundation

/// The operator's camera-motion choices (head tracking, stick and virtual joystick) under the
/// app's existing keys, defaults and ranges. Enum interpretation stays with the host: curve, size,
/// ramp and double-tap are stored raw so an unknown value written by a newer build survives.
/// Reads never write; ranged values clamp on read and on write.
public final class MonitorMotionPreferences: @unchecked Sendable {
    public struct Keys: Sendable {
        public let headTrackingEnabled: String
        public let gimbalStickSensitivity: String
        public let virtualJoystickInvertPan: String
        public let virtualJoystickInvertTilt: String
        public let virtualJoystickDeadzonePercent: String
        public let virtualJoystickResponseCurve: String
        public let virtualJoystickSize: String
        public let gimbalRamp: String
        public let gimbalDoubleTap: String

        public init(
            headTrackingEnabled: String, gimbalStickSensitivity: String,
            virtualJoystickInvertPan: String, virtualJoystickInvertTilt: String,
            virtualJoystickDeadzonePercent: String, virtualJoystickResponseCurve: String,
            virtualJoystickSize: String, gimbalRamp: String, gimbalDoubleTap: String
        ) {
            let keys = [
                headTrackingEnabled, gimbalStickSensitivity, virtualJoystickInvertPan,
                virtualJoystickInvertTilt, virtualJoystickDeadzonePercent,
                virtualJoystickResponseCurve, virtualJoystickSize, gimbalRamp, gimbalDoubleTap,
            ]
            precondition(keys.allSatisfy { !$0.isEmpty } && Set(keys).count == keys.count)
            self.headTrackingEnabled = headTrackingEnabled
            self.gimbalStickSensitivity = gimbalStickSensitivity
            self.virtualJoystickInvertPan = virtualJoystickInvertPan
            self.virtualJoystickInvertTilt = virtualJoystickInvertTilt
            self.virtualJoystickDeadzonePercent = virtualJoystickDeadzonePercent
            self.virtualJoystickResponseCurve = virtualJoystickResponseCurve
            self.virtualJoystickSize = virtualJoystickSize
            self.gimbalRamp = gimbalRamp
            self.gimbalDoubleTap = gimbalDoubleTap
        }

        /// The keys camera apps already use: `<prefix>.HeadTrackingEnabled` and so on.
        public init(prefix: String) {
            self.init(
                headTrackingEnabled: prefix + ".HeadTrackingEnabled",
                gimbalStickSensitivity: prefix + ".GimbalStickSensitivity",
                virtualJoystickInvertPan: prefix + ".VirtualJoystickInvertPan",
                virtualJoystickInvertTilt: prefix + ".VirtualJoystickInvertTilt",
                virtualJoystickDeadzonePercent: prefix + ".VirtualJoystickDeadzonePercent",
                virtualJoystickResponseCurve: prefix + ".VirtualJoystickResponseCurve",
                virtualJoystickSize: prefix + ".VirtualJoystickSize",
                gimbalRamp: prefix + ".GimbalRamp", gimbalDoubleTap: prefix + ".GimbalDoubleTap")
        }
    }

    public struct Defaults: Sendable {
        public var headTrackingEnabled: Bool
        public var gimbalStickSensitivity: Int
        public var virtualJoystickInvertPan: Bool
        public var virtualJoystickInvertTilt: Bool
        public var virtualJoystickDeadzonePercent: Int
        public var virtualJoystickResponseCurve: String
        public var virtualJoystickSize: String
        public var gimbalRamp: Int
        public var gimbalDoubleTap: Int

        public init(
            gimbalStickSensitivity: Int, virtualJoystickDeadzonePercent: Int,
            virtualJoystickResponseCurve: String, virtualJoystickSize: String,
            gimbalRamp: Int, gimbalDoubleTap: Int, headTrackingEnabled: Bool = false,
            virtualJoystickInvertPan: Bool = false, virtualJoystickInvertTilt: Bool = false
        ) {
            self.headTrackingEnabled = headTrackingEnabled
            self.gimbalStickSensitivity = gimbalStickSensitivity
            self.virtualJoystickInvertPan = virtualJoystickInvertPan
            self.virtualJoystickInvertTilt = virtualJoystickInvertTilt
            self.virtualJoystickDeadzonePercent = virtualJoystickDeadzonePercent
            self.virtualJoystickResponseCurve = virtualJoystickResponseCurve
            self.virtualJoystickSize = virtualJoystickSize
            self.gimbalRamp = gimbalRamp
            self.gimbalDoubleTap = gimbalDoubleTap
        }
    }

    public struct Limits: Sendable {
        public let sensitivity: ClosedRange<Int>
        public let deadzonePercent: ClosedRange<Int>

        public init(sensitivity: ClosedRange<Int>, deadzonePercent: ClosedRange<Int>) {
            self.sensitivity = sensitivity
            self.deadzonePercent = deadzonePercent
        }
    }

    // Configuration is immutable. UserDefaults synchronizes its individual reads and writes.
    private let storage: UserDefaults
    private let keys: Keys
    private let defaults: Defaults
    private let limits: Limits

    public init(storage: UserDefaults, keys: Keys, defaults: Defaults, limits: Limits) {
        self.storage = storage
        self.keys = keys
        self.defaults = defaults
        self.limits = limits
    }

    public var headTrackingEnabled: Bool {
        get { bool(keys.headTrackingEnabled, fallback: defaults.headTrackingEnabled) }
        set { storage.set(newValue, forKey: keys.headTrackingEnabled) }
    }
    public var gimbalStickSensitivity: Int {
        get { clamped(int(keys.gimbalStickSensitivity, fallback: defaults.gimbalStickSensitivity), limits.sensitivity) }
        set { storage.set(clamped(newValue, limits.sensitivity), forKey: keys.gimbalStickSensitivity) }
    }
    public var virtualJoystickInvertPan: Bool {
        get { bool(keys.virtualJoystickInvertPan, fallback: defaults.virtualJoystickInvertPan) }
        set { storage.set(newValue, forKey: keys.virtualJoystickInvertPan) }
    }
    public var virtualJoystickInvertTilt: Bool {
        get { bool(keys.virtualJoystickInvertTilt, fallback: defaults.virtualJoystickInvertTilt) }
        set { storage.set(newValue, forKey: keys.virtualJoystickInvertTilt) }
    }
    public var virtualJoystickDeadzonePercent: Int {
        get {
            clamped(int(keys.virtualJoystickDeadzonePercent, fallback: defaults.virtualJoystickDeadzonePercent),
                limits.deadzonePercent)
        }
        set { storage.set(clamped(newValue, limits.deadzonePercent), forKey: keys.virtualJoystickDeadzonePercent) }
    }
    /// The stored raw curve; an absent value reads as the host default.
    public var virtualJoystickResponseCurve: String {
        get { storage.string(forKey: keys.virtualJoystickResponseCurve) ?? defaults.virtualJoystickResponseCurve }
        set { storage.set(newValue, forKey: keys.virtualJoystickResponseCurve) }
    }
    /// The stored raw joystick size; an absent value reads as the host default.
    public var virtualJoystickSize: String {
        get { storage.string(forKey: keys.virtualJoystickSize) ?? defaults.virtualJoystickSize }
        set { storage.set(newValue, forKey: keys.virtualJoystickSize) }
    }
    public var gimbalRamp: Int {
        get { int(keys.gimbalRamp, fallback: defaults.gimbalRamp) }
        set { storage.set(newValue, forKey: keys.gimbalRamp) }
    }
    public var gimbalDoubleTap: Int {
        get { int(keys.gimbalDoubleTap, fallback: defaults.gimbalDoubleTap) }
        set { storage.set(newValue, forKey: keys.gimbalDoubleTap) }
    }

    private func bool(_ key: String, fallback: Bool) -> Bool {
        storage.object(forKey: key) == nil ? fallback : storage.bool(forKey: key)
    }

    private func int(_ key: String, fallback: Int) -> Int {
        storage.object(forKey: key) == nil ? fallback : storage.integer(forKey: key)
    }

    private func clamped(_ value: Int, _ range: ClosedRange<Int>) -> Int {
        min(max(range.lowerBound, value), range.upperBound)
    }
}
