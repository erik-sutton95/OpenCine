#if os(iOS)
import SwiftUI

public struct MonitorScopePanelPlate<Content: View>: View {
    let title: String
    let chip: String
    let size: CGSize
    @ViewBuilder var content: () -> Content

    public init(title: String, chip: String, size: CGSize, @ViewBuilder content: @escaping () -> Content) {
        self.title = title; self.chip = chip; self.size = size; self.content = content
    }
    public var body: some View {
        ZStack(alignment: .topLeading) {
            content()
            HStack(spacing: 4) {
                Text(title.uppercased())
                    .font(.system(size: 6.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(MonitorTheme.text.opacity(0.6))
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                Spacer(minLength: 2)
                Text(chip)
                    .font(.system(size: 6.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(MonitorTheme.accent.opacity(0.92))
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
            }
            .padding(.horizontal, 7)
            .padding(.top, 5)
            .padding(.bottom, 2)
        }
        .frame(width: size.width, height: size.height)
        .compositingGroup()
        .monitorGlass(
            in: RoundedRectangle(cornerRadius: 10, style: .continuous), density: .scope
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .shadow(color: .black.opacity(0.34), radius: 11, y: 8)
        .allowsHitTesting(false)
    }
}
#endif
