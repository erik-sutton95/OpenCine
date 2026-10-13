import Foundation
import OpenCineCore
import Testing

/// Kotlin twin: `FrameRateTest`. Same vectors, same expectations.
struct FrameRateTests {
    /// A5-09: a decimal frame rate (Luna's schema table) becomes the exact Rational once, in Core.
    @Test func aDecimalRateBecomesTheExactRational() {
        let vectors: [(Double, Rational?)] = [
            (23.976, Rational(24000, 1001)), (23.98, Rational(24000, 1001)), (24, Rational(24)),
            (25, Rational(25)), (29.97, Rational(30000, 1001)), (30, Rational(30)),
            (47.95, Rational(48000, 1001)), (59.94, Rational(60000, 1001)), (119.88, Rational(120000, 1001)),
            (240, Rational(240)), (12.5, Rational(25, 2)),
            (0, nil), (-24, nil), (.nan, nil), (.infinity, nil),
        ]
        for (fps, expected) in vectors {
            #expect(Rational.frameRate(fps) == expected, "\(fps)")
        }
    }
}
