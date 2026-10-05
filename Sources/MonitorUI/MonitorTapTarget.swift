#if os(iOS)
    import SwiftUI

    /// Plain button style that pads the label's hit-test region to Apple's 44×44pt HIG minimum
    /// without growing controls that are already larger.
    public struct MonitorTapTargetButtonStyle: ButtonStyle {
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        public var minSize: CGFloat

        public init(minSize: CGFloat = 44) { self.minSize = minSize }

        public func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .minTapTarget(minSize)
                .opacity(configuration.isPressed ? 0.6 : 1)
                .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
                .animation(
                    reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
        }
    }

    extension ButtonStyle where Self == MonitorTapTargetButtonStyle {
        public static var monitorTapTarget: MonitorTapTargetButtonStyle {
            MonitorTapTargetButtonStyle()
        }
    }

    extension View {
        public func glassCapsule(interactive: Bool = false) -> some View {
            liquidGlass(in: Capsule(), interactive: interactive)
        }

        public func glassCircle(interactive: Bool = false) -> some View {
            liquidGlass(in: Circle(), interactive: interactive)
        }

        /// Pads this view's hit-test region to at least `minSize`×`minSize` pt without growing
        /// the drawn control.
        public func minTapTarget(_ minSize: CGFloat = 44) -> some View {
            modifier(MinTapTargetModifier(minSize: minSize))
        }

        /// Historical page-card call sites now use the shared solid surface. Floating
        /// monitor controls use `monitorGlass` instead.
        // ponytail: `interactive` changes nothing; it stays so the old call sites compile.
        @ViewBuilder
        public func liquidGlass(in shape: some Shape, tint: Color? = nil, interactive: Bool = false)
            -> some View
        {
            background(tint ?? MonitorTheme.surface, in: shape)
                .overlay(shape.stroke(MonitorTheme.border, lineWidth: 1))
        }
    }

    private struct MinTapTargetSizeKey: PreferenceKey {
        static let defaultValue: CGSize = .zero

        static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
            let next = nextValue()
            if next != .zero {
                value = next
            }
        }
    }

    /// Expands hit testing to at least `minSize` without growing the layout box: positive
    /// padding widens `contentShape`, then matching negative padding restores sibling spacing.
    private struct MinTapTargetModifier: ViewModifier {
        var minSize: CGFloat
        @State private var measuredSize: CGSize = .zero

        func body(content: Content) -> some View {
            let horizontalPad =
                measuredSize == .zero ? 0 : max(0, (minSize - measuredSize.width) / 2)
            let verticalPad =
                measuredSize == .zero ? 0 : max(0, (minSize - measuredSize.height) / 2)

            content
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(key: MinTapTargetSizeKey.self, value: proxy.size)
                    }
                }
                .onPreferenceChange(MinTapTargetSizeKey.self) { measuredSize = $0 }
                .padding(.horizontal, horizontalPad)
                .padding(.vertical, verticalPad)
                .contentShape(Rectangle())
                .padding(.horizontal, -horizontalPad)
                .padding(.vertical, -verticalPad)
        }
    }
#endif
