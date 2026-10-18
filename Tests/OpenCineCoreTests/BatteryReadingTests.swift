import OpenCineCore
import Testing

/// Kotlin twin: `BatteryReadingTest`. Same vectors, same expectations.
struct BatteryReadingTests {
    private static func power(_ value: Double?, _ precision: ObservationPrecision?) -> PowerStatus {
        PowerStatus(battery: value.map { ObservedValue($0, origin: .cameraReported, at: nil, precision: precision) } ?? .unknown)
    }

    @Test func aSourceDeclaresAGaugeOrAFractionAndSharedCodeNeverGuesses() {
        let vectors: [(Double?, ObservationPrecision?, BatteryReading?)] = [
            (0.6, .quantized(step: 0.2), .steps(filled: 3, of: 5)),     // Nikon five-bar gauge
            (1.0, .quantized(step: 0.2), .steps(filled: 5, of: 5)),
            (0.2, .quantized(step: 0.2), .steps(filled: 1, of: 5)),
            (0.25, .quantized(step: 0.25), .steps(filled: 1, of: 4)),
            (0.6, .quantized(step: 0.01), .fraction(0.6)),              // DJI and Luna percent
            (0.6, nil, .fraction(0.6)),
            (0.5, .quantized(step: 0.05), .fraction(0.5)),               // too fine for a gauge
            (1.2, .exact, .fraction(1.0)),
            (-0.1, .quantized(step: 0.2), .steps(filled: 0, of: 5)),
            (nil, .quantized(step: 0.2), nil),                           // unknown stays absent (D11)
        ]
        for (value, precision, expected) in vectors {
            #expect(Self.power(value, precision).batteryReading == expected, "\(String(describing: value)) \(String(describing: precision))")
        }
    }
}
