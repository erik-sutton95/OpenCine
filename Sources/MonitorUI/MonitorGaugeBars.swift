#if os(iOS)
import SwiftUI

/// A coarse gauge as `count` bars, lit up to `fraction`: link delivery, or a camera's battery
/// steps. Bars narrow below 3.5 points when their container is tighter. Kotlin twin:
/// `MonitorGaugeBars`.
public struct MonitorGaugeBars: View {
    public var fraction: Double
    public var count: Int
    public var tint: Color
    public var barHeight: CGFloat

    public init(fraction: Double, count: Int, tint: Color, barHeight: CGFloat = 9) {
        self.fraction = fraction
        self.count = count
        self.tint = tint
        self.barHeight = barHeight
    }

    public var body: some View {
        HStack(spacing: 1.5) {
            ForEach(0..<max(1, count), id: \.self) { index in
                RoundedRectangle(cornerRadius: 0.75)
                    .fill(tint.opacity(fraction >= Double(index + 1) / Double(max(1, count)) ? 1 : 0.2))
                    .frame(maxWidth: 3.5)
                    .frame(height: barHeight)
            }
        }
    }
}
#endif
