import Foundation

/// Operator help shared by the settings compositions.
public enum MonitorSettingsCopy {
    public static let keepScreenAwake =
        "Keeps the screen awake while this app is active. Turn off to use the device's normal auto-lock setting. The system may still dim the screen when the device is hot."

    /// The account sign-in consent on the camera's Wi-Fi (A2-23): signing in hops to the internet
    /// through the app's one internet hop, then reconnects the camera.
    public static let accountConsentTitle = "Leave camera Wi\u{2011}Fi to sign in?"
    public static func accountConsentMessage(service: String) -> String {
        "We'll hop to home Wi\u{2011}Fi or cellular so you can sign in to \(service), then reconnect to the camera automatically."
    }
    public static let accountConsentAction = "Sign in"
    /// Asked before a Settings browser link leaves the camera's Wi-Fi (A2-22).
    public static func browserConfirmation(title: String, app: String) -> String {
        "To open \(title), \(app) will disconnect from the camera's Wi-Fi and switch to cellular or another internet-connected Wi-Fi network. You can reconnect to the camera after you finish."
    }
    /// Shown when a Settings browser link found no internet route after leaving the camera's Wi-Fi.
    public static func browserInternetFailure(app: String) -> String {
        "\(app) couldn't reach the internet after leaving the camera's Wi-Fi. Check cellular or another Wi-Fi network and try again."
    }
    /// Shown when the account hop left the camera's Wi-Fi but found no internet route.
    public static let accountInternetFailure =
        "Couldn't reach the internet after leaving the camera's Wi\u{2011}Fi. Check cellular or home Wi\u{2011}Fi."
}
