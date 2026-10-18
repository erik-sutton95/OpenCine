/// One independent setting as projected by its host. Order, exact options and unknown current
/// values are preserved; the existing typed request is a UI target, not a wire admission receipt.
/// Compose twin: `IndependentSettingRow` in camera-controls.
public struct IndependentSettingRow<RowID: Hashable, Request>: Identifiable {
    public let id: RowID
    public let title: String
    public let options: [String]
    public let current: String?
    public let request: Request?
    public let unavailableReason: String?

    public init(
        id: RowID, title: String, options: [String], current: String?,
        request: Request?, unavailableReason: String?
    ) {
        self.id = id
        self.title = title
        self.options = options
        self.current = current
        self.request = request
        self.unavailableReason = unavailableReason
    }

    /// Called only by an explicit selection. Refused rows explain the host's decision; stale or
    /// disabled interactions and unlisted options cannot reach either host callback.
    public func select(
        _ option: String, interactionEnabled: Bool, currentSource: () -> Bool,
        onSelect: (Request, String) -> Void, onUnavailable: (RowID, String?) -> Void
    ) {
        guard interactionEnabled, currentSource(), options.contains(option) else { return }
        guard let request else {
            onUnavailable(id, unavailableReason)
            return
        }
        onSelect(request, option)
    }
}

extension IndependentSettingRow: Sendable where RowID: Sendable, Request: Sendable {}

#if os(iOS)
    import MonitorUI
    import SwiftUI

    /// Ordered independent rows with no coupled selection or command. Hosts supply availability and
    /// current-source checks and retain their existing request dispatch and refusal policy.
    /// Compose twin: `MonitorIndependentSettingsPanel` in camera-controls.
    public struct MonitorIndependentSettingsPanel<RowID: Hashable, Request>: View {
        private let rows: [IndependentSettingRow<RowID, Request>]
        private let interactionEnabled: Bool
        private let currentSource: () -> Bool
        private let onSelect: (Request, String) -> Void
        private let onUnavailable: (RowID, String?) -> Void

        public init(
            rows: [IndependentSettingRow<RowID, Request>], interactionEnabled: Bool,
            currentSource: @escaping () -> Bool, onSelect: @escaping (Request, String) -> Void,
            onUnavailable: @escaping (RowID, String?) -> Void
        ) {
            self.rows = rows
            self.interactionEnabled = interactionEnabled
            self.currentSource = currentSource
            self.onSelect = onSelect
            self.onUnavailable = onUnavailable
        }

        public var body: some View {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(rows) { row in
                    rowView(row)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("monitor.independentSettings")
        }

        private func rowView(_ row: IndependentSettingRow<RowID, Request>) -> some View {
            let identifier = "monitor.independentSettings.\(row.id)"
            return VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Text(row.title)
                        .font(MonitorTheme.font(12, weight: .semibold))
                        .foregroundStyle(MonitorTheme.muted)
                        .frame(width: 44, alignment: .leading)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier(identifier + ".title")
                    VStack(alignment: .leading, spacing: 6) {
                        if let current = row.current, !row.options.contains(current) {
                            Text(current)
                                .font(MonitorTheme.font(13, weight: .semibold))
                                .foregroundStyle(MonitorTheme.text)
                                .accessibilityIdentifier(identifier + ".current")
                        }
                        if !row.options.isEmpty {
                            MonitorTabStrip {
                                ForEach(Array(row.options.enumerated()), id: \.offset) {
                                    index, option in
                                    let selected = row.current == option
                                    Button {
                                        row.select(
                                            option, interactionEnabled: interactionEnabled,
                                            currentSource: currentSource, onSelect: onSelect,
                                            onUnavailable: onUnavailable)
                                    } label: {
                                        Text(option)
                                            .font(MonitorTheme.font(13, weight: .semibold))
                                            .foregroundStyle(
                                                selected ? MonitorTheme.accent : MonitorTheme.text
                                            )
                                            .padding(.horizontal, 14)
                                            // Reserve a point so native pixel-edge rounding cannot
                                            // reduce the observed target below the 44pt floor.
                                            .frame(maxWidth: .infinity, minHeight: 45)
                                            .monitorTabSurface(selected: selected)
                                    }
                                    .buttonStyle(MonitorTabButtonStyle())
                                    .disabled(!interactionEnabled)
                                    .accessibilityLabel(option)
                                    .accessibilityAddTraits(selected ? .isSelected : [])
                                    .accessibilityIdentifier(identifier + ".option.\(index)")
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                // A row without a request stays tappable so its host can explain the refusal.
                .opacity(row.request == nil ? 0.35 : 1)
                if let reason = row.unavailableReason {
                    Text(reason)
                        .font(MonitorTheme.font(11))
                        .foregroundStyle(MonitorTheme.muted)
                        .accessibilityIdentifier(identifier + ".reason")
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(identifier)
        }
    }
#endif
