#if os(iOS)
    import SwiftUI

    /// A single-line readout shrinks only within its declared readable range, then truncates visibly.
    /// Accessibility keeps the complete supplied value even when the native line cannot fit.
    public struct MonitorBoundedReadoutText: View {
        private let value: String
        private let maximum: CGFloat
        private let minimum: CGFloat
        public init(_ value: String, maximumSize: CGFloat = 14, minimumSize: CGFloat = 11) {
            self.value = value
            maximum = maximumSize.isFinite ? max(1, maximumSize) : 14
            minimum = minimumSize.isFinite ? min(maximum, max(1, minimumSize)) : min(11, maximum)
        }
        public var body: some View {
            Text(value).font(MonitorTheme.font(maximum, weight: .medium)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(minimum / maximum).truncationMode(.tail)
                .accessibilityLabel(value)
        }
    }

    /// Large primary and small detail readouts form one column while retaining separate native targets.
    public struct MonitorPortraitFormatGroup<Primary: View, Detail: View>: View {
        private let showsDetail: Bool
        private let primary: () -> Primary
        private let detail: () -> Detail
        public init(
            showsDetail: Bool, @ViewBuilder primary: @escaping () -> Primary,
            @ViewBuilder detail: @escaping () -> Detail
        ) {
            self.showsDetail = showsDetail
            self.primary = primary
            self.detail = detail
        }
        public var body: some View {
            VStack(alignment: .trailing, spacing: 2) {
                primary().frame(minHeight: 44, alignment: .topTrailing)
                if showsDetail { detail().frame(minHeight: 44, alignment: .topTrailing) }
            }
        }
    }
#endif
