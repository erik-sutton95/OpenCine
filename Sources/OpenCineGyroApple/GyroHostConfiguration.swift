#if os(iOS)
import Foundation
import OpenCineGyro

/// The host values one app supplies to the shared gyro runtime.
public struct GyroHostConfiguration: Sendable {
    /// The app's display name, used for log filenames and metadata.
    public let appName: String
    /// The app-private directory that holds gyro logs.
    public let logDirectory: URL
    /// The host's namespaced preference keys.
    public let preferenceKeys: GyroPreferenceKeys
    /// The host's old app-wide keys, adopted once by the legacy migration.
    public let legacyKeys: GyroLegacyPreferenceKeys?

    /// Creates the configuration for one app.
    public init(
        appName: String, logDirectory: URL, preferenceKeys: GyroPreferenceKeys,
        legacyKeys: GyroLegacyPreferenceKeys? = nil
    ) {
        self.appName = appName
        self.logDirectory = logDirectory
        self.preferenceKeys = preferenceKeys
        self.legacyKeys = legacyKeys
    }
}
#endif
