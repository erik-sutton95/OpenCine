#if os(iOS)
    import SwiftUI
    import OpenCineMedia

    /// Compact HUD chip. One label: Stops, ND32, or ND 0.3, from the long-press setting.
    public struct MonitorNDFilterChip: View {
        private let reading: MonitorNDFilterSuggestion?
        private let notation: MonitorNDFilterNotation
        private let emptyLabel: String

        public init(
            reading: MonitorNDFilterSuggestion?, notation: MonitorNDFilterNotation = .factor,
            emptyLabel: String = "?"
        ) {
            self.reading = reading
            self.notation = notation
            self.emptyLabel = emptyLabel
        }

        public var body: some View {
            Text(reading?.chipLabel(notation) ?? emptyLabel)
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundStyle(
                    reading?.needsGlass == true ? MonitorTheme.accent : MonitorTheme.text
                )
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .monitorGlass(in: Capsule())
                .environment(\.colorScheme, .dark)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("ND Suggestion")
                .accessibilityValue(accessibilityValue)
        }

        private var accessibilityValue: String {
            guard let reading else { return "waiting for picture" }
            let label = reading.chipLabel(notation)
            if reading.needsGlass {
                return "\(label), \(reading.stopsLabel) stops over middle gray"
            }
            return "\(label), no ND"
        }
    }
#endif
