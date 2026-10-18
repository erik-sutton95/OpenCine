import Foundation
import OpenCineMedia

/// DJI camera access points in diagnostics: a DJI app keeps them readable and redacts every other
/// SSID. The neutral `PrivacyRedactor.redact(_:)` redacts all of them. Kotlin twin:
/// `com.opencapture.opencine.dji.DjiCameraNetwork`.
public enum DJICameraNetwork {
    /// The DJI family names a camera's access point carries.
    public static func isAccessPoint(_ ssid: String) -> Bool {
        let n = ssid.lowercased().replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "'", with: "")
        return n.contains("osmo") || n.contains("pocket") || n.contains("nano")
            || n.contains("muse") || n.contains("atto") || n.contains("xtra")
            || n.contains("edge")
    }

    /// The host redaction of a DJI app.
    public static func redact(_ text: String) -> String {
        PrivacyRedactor.redact(text, isSafeNetwork: isAccessPoint)
    }
}
