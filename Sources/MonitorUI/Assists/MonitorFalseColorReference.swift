#if os(iOS)
import MonitorPresentation
import SwiftUI

public typealias MonitorFalseColorReferenceSegment = MonitorPresentation.MonitorFalseColorReferenceSegment
public typealias MonitorFalseColorReferenceMarker = MonitorPresentation.MonitorFalseColorReferenceMarker
public typealias MonitorFalseColorReferenceValues = MonitorPresentation.MonitorFalseColorReferenceValues

public struct MonitorFalseColorReference: View {
    public static let panelSize = CGSize(width: 264, height: 52)
    let values: MonitorFalseColorReferenceValues
    var inspector = false
    public init(values: MonitorFalseColorReferenceValues, inspector: Bool = false) {
        self.values = values; self.inspector = inspector
    }
    public var body: some View {
        Group {
            if inspector {
                referenceContent.frame(height: 26)
            } else {
                referenceContent
                    .padding(7)
                    .frame(
                        width: Self.panelSize.width, height: Self.panelSize.height,
                        alignment: .topLeading
                    )
                    .monitorGlass(
                        in: RoundedRectangle(
                            cornerRadius: MonitorTheme.radius, style: .continuous))
                    .environment(\.colorScheme, .dark)
            }
        }
    }

    private var referenceContent: some View {
        VStack(alignment: .leading, spacing: 3) {
            if !inspector {
                HStack {
                    Text("False Color")
                        .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                    Spacer()
                    Text(
                        values.subtitle
                    )
                        .font(.system(size: 7.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    LinearGradient(
                        colors: neutralGradientColors,
                        startPoint: .leading,
                        endPoint: .trailing)
                    MonitorSnapshotRows(
                        values.segments
                    ) {
                        segment in
                        Rectangle()
                            .fill(
                                Color(
                                    red: segment.red,
                                    green: segment.green,
                                    blue: segment.blue)
                            )
                            .frame(
                                width: max(
                                    1,
                                    geometry.size.width
                                        * (segment.upperFraction - segment.lowerFraction))
                            )
                            .offset(x: geometry.size.width * segment.lowerFraction)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
            }
            .frame(height: inspector ? 14 : 8)
            axisView
        }
    }

    @ViewBuilder private var axisView: some View {
        if !values.markers.isEmpty {
            GeometryReader { geometry in
                MonitorSnapshotRows(
                    values.markers
                ) {
                    marker in
                    Text(marker.label)
                        .font(
                            inspector
                                ? MonitorTheme.font(7, weight: .medium)
                                : .system(size: 5.5, weight: .medium, design: .monospaced)
                        )
                        .foregroundStyle(.secondary)
                        .fixedSize()
                        .position(
                            x: min(
                                geometry.size.width - 8,
                                max(8, geometry.size.width * marker.fraction)),
                            y: inspector ? 4.5 : 3.5)
                }
            }
            .frame(height: inspector ? 9 : 7)
        } else {
            waveAxisView
        }
    }

    private var waveAxisView: some View {
        HStack(spacing: 4) {
            MonitorSnapshotRows(Array(values.axisLabels.enumerated()), id: \.offset)
            {
                index, label in
                if index > 0 { Spacer(minLength: 0) }
                Text(label)
                    .font(
                        inspector
                            ? MonitorTheme.font(7, weight: .medium)
                            : .system(size: 5.5, weight: .medium, design: .monospaced)
                    )
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
    }

    private var neutralGradientColors: [Color] {
        [Color(white: 0.54), Color(white: 0.75)]
    }
}
#endif
