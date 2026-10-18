#if os(iOS)
import SwiftUI

/// A coarse gauge retains its declared count. Up to ten steps use native cells; denser gauges
/// use exact filled/count text. Kotlin twin: `MonitorGaugeBars`.
public struct MonitorGaugeBars: View {
    public var fraction: Double
    public var count: Int
    public var tint: Color
    public var barHeight: CGFloat
    private var exactFilled: Int?

    public init(fraction: Double, count: Int, tint: Color, barHeight: CGFloat = 9) {
        self.fraction = fraction
        self.count = count
        self.tint = tint
        self.barHeight = barHeight
        self.exactFilled = nil
    }

    /// Battery callers keep the original integer count instead of round-tripping through a fraction.
    public init(filled: Int, count: Int, tint: Color, barHeight: CGFloat = 9) {
        self.fraction = Double(filled) / Double(max(1, count))
        self.count = count
        self.tint = tint
        self.barHeight = barHeight
        self.exactFilled = filled
    }

    /// Compact pills grow only for the textual fallback; ordinary gauge geometry stays fixed.
    public static func readoutWidth(filled: Int, count: Int, minimum: CGFloat, inset: CGFloat) -> CGFloat {
        guard count > 10 else { return minimum }
        return max(minimum, CGFloat("\(filled)/\(count)".count) * 6 + inset)
    }

    private var filled: Int {
        if let exactFilled { return exactFilled }
        guard fraction.isFinite, fraction > 0 else { return 0 }
        if fraction >= 1 { return max(1, count) }
        let scaled = (fraction * Double(max(1, count))).rounded()
        // Double(Int.max) lies above Int.max, so handle a full gauge before converting.
        if scaled >= Double(Int.max) { return max(1, count) }
        return Int(scaled)
    }

    public var body: some View {
        if count > 10 {
            Text(verbatim: "\(filled)/\(count)")
                .font(MonitorTheme.font(10, weight: .semibold)).monospacedDigit()
                .foregroundStyle(tint).lineLimit(1).minimumScaleFactor(0.5)
                .accessibilityLabel(Text(verbatim: "\(filled) of \(count) bars"))
                .accessibilityValue(Text(verbatim: "\(filled)/\(count)"))
        } else {
            HStack(spacing: 1.5) {
                ForEach(0..<min(10, max(1, count)), id: \.self) { index in
                    RoundedRectangle(cornerRadius: 0.75)
                        .fill(tint.opacity((exactFilled.map { index < $0 }
                            ?? (fraction >= Double(index + 1) / Double(max(1, count)))) ? 1 : 0.2))
                        .frame(maxWidth: 3.5)
                        .frame(height: barHeight)
                }
            }
        }
    }
}
#endif
