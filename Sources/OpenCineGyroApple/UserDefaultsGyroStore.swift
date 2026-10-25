#if os(iOS)
import Foundation
import OpenCineGyro

/// The gyro preferences' key-value store over one host defaults suite.
public final class UserDefaultsGyroStore: GyroKeyValueStore {
    private let defaults: UserDefaults

    /// Creates a store over an injected defaults instance.
    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// Reads one payload. A legacy `Bool` or `String` is bridged back to the JSON bytes the
    /// preferences decode; every other stored type is not a gyro payload.
    public func data(forKey key: String) -> Data? {
        guard let object = defaults.object(forKey: key) else { return nil }
        if let data = object as? Data { return data }
        if let number = object as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() {
            return Data(number.boolValue ? "true".utf8 : "false".utf8)
        }
        if let string = object as? String {
            return try? JSONEncoder().encode(string)
        }
        return nil
    }

    /// Stores one payload, or removes the key when the payload is nil.
    public func setData(_ data: Data?, forKey key: String) {
        guard let data else {
            defaults.removeObject(forKey: key)
            return
        }
        defaults.set(data, forKey: key)
    }
}
#endif
