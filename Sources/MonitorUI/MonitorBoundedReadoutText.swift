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

    /// The first full target publishes its occupied top through native layout, before row clearance.
    enum MonitorPortraitCaptureTargetTop: AlignmentID {
        static func defaultValue(in context: ViewDimensions) -> CGFloat { 0 }
    }
    extension VerticalAlignment {
        static let monitorPortraitCaptureTargetTop = VerticalAlignment(MonitorPortraitCaptureTargetTop.self)
    }

    /// Portrait capture readouts stack in one trailing column: resolution and frame rate on top,
    /// codec and color directly below. The column's top is the primary's top, so the primary
    /// shares the status row's top edge with the timecode and the STBY/REC chip. Each line is its
    /// own full-height target. The primary target expands upward, ending where the detail glyphs
    /// begin, while its label stays at the original top. The detail keeps its target below that
    /// boundary, so the painted lines stay together and no tap lands on two readouts.
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
            MonitorPortraitFormatStackLayout {
                primary().frame(maxHeight: .infinity, alignment: showsDetail ? .bottomTrailing : .topTrailing)
                    .alignmentGuide(.monitorPortraitCaptureTargetTop) { _ in 0 }
                if showsDetail { detail().frame(maxHeight: .infinity, alignment: .topTrailing) }
            }
        }
    }

    /// Trailing column whose second line starts at the first line's glyph height.
    public struct MonitorPortraitFormatStackLayout: Layout {
        /// The native target floor every portrait capture line keeps.
        public let target: CGFloat
        public init(target: CGFloat = 44) { self.target = target }

        public func sizeThatFits(
            proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
        ) -> CGSize {
            frames(subviews: subviews).size
        }

        public func placeSubviews(
            in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
        ) {
            let measured = frames(subviews: subviews)
            for (view, frame) in zip(subviews, measured.slots) {
                view.place(
                    at: CGPoint(x: bounds.maxX - frame.width, y: bounds.minY + frame.minY),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(width: frame.width, height: frame.height))
            }
        }

        /// Line frames in column coordinates: each line is as wide as its content; line two
        /// begins where the primary glyphs end. The first full-height target expands upward;
        /// subsequent full-height targets begin at the previous target's lower boundary.
        public func frames(subviews: Subviews) -> (size: CGSize, slots: [CGRect]) {
            frames(lines: subviews.map { $0.sizeThatFits(.unspecified) })
        }

        public func frames(lines: [CGSize]) -> (size: CGSize, slots: [CGRect]) {
            var slots: [CGRect] = []
            var y: CGFloat = 0
            var bottom: CGFloat = 0
            for (index, line) in lines.enumerated() {
                let height = max(target, line.height)
                let top = index == 0 && lines.count > 1 ? min(0, line.height - height) : y
                let slot = CGRect(
                    x: 0, y: top, width: line.width, height: height)
                slots.append(slot)
                bottom = max(bottom, slot.maxY)
                y = slot.maxY
            }
            let width = lines.map(\.width).max() ?? 0
            return (CGSize(width: width, height: bottom), slots)
        }
    }
#endif
