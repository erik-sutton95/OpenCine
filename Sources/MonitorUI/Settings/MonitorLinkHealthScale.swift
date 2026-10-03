#if os(iOS)
import MonitorPresentation
import SwiftUI

/// Shows the host-resolved link score without measuring or making transport decisions.
public struct MonitorLinkHealthScale: View {
    private let title: String
    private let caption: String
    private let score: Int

    public init(title: String, caption: String, score: Int) {
        self.title = title
        self.caption = caption
        self.score = score
    }

    private var band: MonitorLinkHealthBand { .init(score: score) }

    private var bandColor: Color {
        MonitorTheme.linkHealthColor(band)
    }
    private var bandName: String {
        switch band {
        case .poor: "POOR"
        case .watch: "WATCH"
        case .stable: "STABLE"
        }
    }
    private var litCount: Int {
        switch band {
        case .poor: 4
        case .watch: 8
        case .stable: 12
        }
    }
    private var bandSlot: Int {
        switch band {
        case .poor: 0
        case .watch: 1
        case .stable: 2
        }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title)
                .font(MonitorTheme.font(13, weight: .semibold))
                .foregroundStyle(MonitorTheme.text)
            Text(caption)
                .font(MonitorTheme.font(11.5, weight: .medium)).monospacedDigit()
                .foregroundStyle(MonitorTheme.muted)
            HStack(spacing: 0) {
                ForEach(0..<3, id: \.self) { slot in
                    ZStack {
                        if slot == bandSlot { marker }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 19)
            HStack(spacing: 3) {
                ForEach(0..<12, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(dashColor(index))
                        .frame(height: 6)
                }
            }
            HStack(spacing: 0) {
                legend("Poor", "<50").frame(maxWidth: .infinity, alignment: .leading)
                legend("Watch", "50-79").frame(maxWidth: .infinity, alignment: .center)
                legend("Stable", "80+").frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MonitorTheme.surface,
            in: RoundedRectangle(cornerRadius: MonitorTheme.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: MonitorTheme.radius, style: .continuous)
            .stroke(MonitorTheme.border, lineWidth: 1))
    }

    private var marker: some View {
        Text(bandName)
            .font(MonitorTheme.font(9.5, weight: .bold)).monospacedDigit()
            .kerning(0.5)
            .foregroundStyle(bandColor)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(bandColor.opacity(0.12), in: Capsule())
            .overlay(Capsule().stroke(bandColor, lineWidth: 1))
    }

    private func dashColor(_ index: Int) -> Color {
        guard index < litCount else { return MonitorTheme.faint.opacity(0.5) }
        if index < 4 { return MonitorTheme.linkHealthColor(.poor).opacity(0.8) }
        if index < 8 { return MonitorTheme.linkHealthColor(.watch).opacity(0.85) }
        return MonitorTheme.linkHealthColor(.stable).opacity(0.9)
    }

    private func legend(_ name: String, _ sub: String) -> some View {
        HStack(spacing: 4) {
            Text(name)
                .font(MonitorTheme.font(10, weight: .semibold))
                .foregroundStyle(MonitorTheme.muted)
            Text(sub)
                .font(MonitorTheme.font(9, weight: .regular)).monospacedDigit()
                .foregroundStyle(MonitorTheme.faint)
        }
    }
}
#endif
