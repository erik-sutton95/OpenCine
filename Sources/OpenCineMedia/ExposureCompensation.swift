import Foundation

/// The one EV spelling every readout uses: `0.0`, `+0.3`, `−0.7` (U+2212), one decimal rounded
/// from the exact value like C `%.1f`. Kotlin twin: `media.ExposureCompensation.label(stops)`;
/// both suites check `Fixtures/capture-label-vectors.tsv`.
public enum ExposureCompensation {
    public static let minusSign = "\u{2212}"

    public static func label(stops: Double) -> String {
        let magnitude = String(format: "%.1f", abs(stops))
        return magnitude == "0.0" ? magnitude : (stops < 0 ? minusSign : "+") + magnitude
    }
}
