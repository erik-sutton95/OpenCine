import Foundation

/// Names the embedding app supplies. The integration never hard-codes an app brand.
public struct LunaIntegrationConfiguration: Sendable, Equatable {
    /// Keychain service holding the camera authorization identity and saved camera Wi-Fi.
    /// The default is the value OpenInstaCine has always used, so credentials it saved keep
    /// working; another app passes its own so it never reads OpenInstaCine's records.
    public var keychainService: String
    /// The app's name in operator-facing messages ("<name> currently supports ...").
    public var appName: String
    /// Prefix of the integration's NSLog lines.
    public var logPrefix: String

    public init(
        keychainService: String = "org.opencine.openinstacine.camera",
        appName: String = "This app",
        logPrefix: String = "Luna"
    ) {
        self.keychainService = keychainService
        self.appName = appName
        self.logPrefix = logPrefix
    }
}
