#if os(iOS)
    import MonitorPresentation
    import SwiftUI

    /// Expanded delivery chrome with finite host details and independent cancel/collapse actions.
    /// The host retains expansion state, placement, task ownership and destination artwork.
    public struct MonitorMediaDeliveryProgressPanel<DestinationIcon: View>: View {
        private let value: MonitorMediaDeliveryProgressValue
        private let details: MonitorMediaDeliveryProgressDetailsValue
        private let onCancel: (() -> Void)?
        private let onCollapse: (() -> Void)?
        private let destinationIcon: DestinationIcon

        public init(
            value: MonitorMediaDeliveryProgressValue,
            details: MonitorMediaDeliveryProgressDetailsValue = .init(),
            onCancel: (() -> Void)? = nil,
            onCollapse: (() -> Void)? = nil,
            @ViewBuilder destinationIcon: () -> DestinationIcon
        ) {
            self.value = value
            self.details = details
            self.onCancel = onCancel
            self.onCollapse = onCollapse
            self.destinationIcon = destinationIcon()
        }

        public var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                MonitorMediaDeliveryProgressContent(
                    value: value,
                    onCancel: onCancel,
                    onExpand: nil,
                    showsInlineProgress: false,
                    destinationIcon: destinationIcon
                )
                if value.showsProgress {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(MonitorTheme.border.opacity(0.55))
                            Capsule().fill(MonitorTheme.accent)
                                .frame(width: max(4, geo.size.width * value.fraction))
                        }
                    }
                    .frame(height: 4)
                    .accessibilityIdentifier("monitor.share.progress.bar")
                }
                if let filename = details.filename {
                    HStack(spacing: 6) {
                        Text("File").font(MonitorTheme.font(10, weight: .semibold))
                            .foregroundStyle(MonitorTheme.muted)
                        Text(filename).font(MonitorTheme.font(11)).monospacedDigit()
                            .foregroundStyle(MonitorTheme.text).lineLimit(1)
                    }
                    .accessibilityIdentifier("monitor.share.progress.filename")
                }
                if let destination = details.destination {
                    Text("Destination: \(destination)").font(MonitorTheme.font(11))
                        .foregroundStyle(MonitorTheme.muted)
                        .accessibilityIdentifier("monitor.share.progress.destination")
                }
                if let onCollapse {
                    Button("Collapse", action: onCollapse)
                        .font(MonitorTheme.font(12, weight: .semibold))
                        .foregroundStyle(MonitorTheme.accent)
                        .buttonStyle(MonitorSettingsButtonStyle())
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .accessibilityIdentifier("monitor.share.progress.collapse")
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .monitorGlass(in: RoundedRectangle(cornerRadius: 12), density: .delivery)
        }
    }

    /// Shared status content keeps compact callers' existing rendering when expansion is absent.
    struct MonitorMediaDeliveryProgressContent<DestinationIcon: View>: View {
        let value: MonitorMediaDeliveryProgressValue
        let onCancel: (() -> Void)?
        let onExpand: (() -> Void)?
        var showsInlineProgress = true
        let destinationIcon: DestinationIcon

        var body: some View {
            HStack(spacing: 10) {
                if let onExpand {
                    Button(action: onExpand) { statusContent }
                        .buttonStyle(MonitorSettingsButtonStyle())
                        .accessibilityHint("Expand delivery progress")
                        .accessibilityIdentifier("monitor.share.progress.expand")
                } else {
                    statusContent
                }
                if let onCancel {
                    Button("Cancel", action: onCancel)
                        .font(MonitorTheme.font(11, weight: .semibold))
                        .foregroundStyle(MonitorTheme.muted)
                }
            }
        }

        private var statusContent: some View {
            HStack(spacing: 10) {
                if value.preparing {
                    ProgressView().controlSize(.small).tint(MonitorTheme.accent)
                } else {
                    destinationIcon.frame(width: 13, height: 13).foregroundStyle(
                        MonitorTheme.accent)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(value.status).font(MonitorTheme.font(12, weight: .semibold))
                        .foregroundStyle(MonitorTheme.text).lineLimit(1)
                    if let batch = value.batch {
                        Text(batch).font(MonitorTheme.font(10, weight: .medium)).monospacedDigit()
                            .foregroundStyle(MonitorTheme.muted)
                    }
                }
                Spacer(minLength: 4)
                if showsInlineProgress && value.showsProgress {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(MonitorTheme.border.opacity(0.55))
                            Capsule().fill(MonitorTheme.accent)
                                .frame(width: max(4, geo.size.width * value.fraction))
                        }
                    }.frame(width: 44, height: 4)
                }
            }
        }
    }
#endif
