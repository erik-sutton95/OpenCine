import Foundation
import OpenCineMedia

/// DJI camera access points stay readable in diagnostics. Lockstep with Kotlin
/// `com.opencapture.opencine.dji.PrivacyRedactor`.
extension PrivacyRedactor {
    public static func redact(_ text: String) -> String {
        redact(text, isSafeNetwork: isCameraNetwork)
    }

    public static func isCameraNetwork(_ raw: String) -> Bool {
        let n = raw.lowercased().replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "'", with: "")
        return n.contains("osmo") || n.contains("pocket") || n.contains("nano")
            || n.contains("muse") || n.contains("atto") || n.contains("xtra")
            || n.contains("edge")
    }
}
