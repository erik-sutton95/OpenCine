#if os(iOS)
    import SwiftUI

    /// A known visibility value and its admitted host action.
    public struct MonitorDisplayToggle: Identifiable {
        public let id: String
        public let title: String
        public let isOn: Bool
        public let accessibilityLabel: String
        public let help: String?
        public let action: () -> Void
        public init(
            id: String, title: String, isOn: Bool, accessibilityLabel: String? = nil,
            help: String? = nil, action: @escaping () -> Void
        ) {
            self.id = id
            self.title = title
            self.isOn = isOn
            self.accessibilityLabel = accessibilityLabel ?? title
            self.help = help
            self.action = action
        }
    }

    /// Typed contents of one display mode's card. Only an eligible host supplies the live editor
    /// action; visibility rows and clean pins stay available without it.
    public struct MonitorDisplaySection: Identifiable {
        public let id: String
        public let title: String
        public let caption: String
        public let reset: (() -> Void)?
        public let editTitle: String
        public let editHint: String?
        public let edit: (() -> Void)?
        public let unavailableEditHelp: String?
        public let visibility: [MonitorDisplayToggle]
        public let pinsTitle: String?
        public let pins: [MonitorDisplayToggle]
        public init(
            id: String, title: String, caption: String, reset: (() -> Void)? = nil,
            editTitle: String = "Edit view", editHint: String? = nil, edit: (() -> Void)? = nil,
            unavailableEditHelp: String? = nil, visibility: [MonitorDisplayToggle] = [],
            pinsTitle: String? = nil, pins: [MonitorDisplayToggle] = []
        ) {
            self.id = id
            self.title = title
            self.caption = caption
            self.reset = reset
            self.editTitle = editTitle
            self.editHint = editHint
            self.edit = edit
            self.unavailableEditHelp = unavailableEditHelp
            self.visibility = visibility
            self.pinsTitle = pinsTitle
            self.pins = pins
        }
    }

    /// One rendering for every host: caption, Edit view (or why not), one switch row per
    /// visibility value, then the clean pins in an adaptive grid (A2-30).
    public struct MonitorDisplaySections: View {
        private let sections: [MonitorDisplaySection]
        public init(sections: [MonitorDisplaySection]) {
            self.sections = sections
        }
        public var body: some View {
            MonitorSnapshotRows(sections, id: \.id) { section in
                // A card identifier propagates over IDs assigned inside native inline rows.
                controlsCard(section)
            }.rows
        }
        /// A control-led section as the reference monitor drew it.
        private func controlsCard(_ section: MonitorDisplaySection) -> some View {
            MonitorSettingsRowCard(title: section.title, onReset: section.reset) {
                Text(section.caption).font(MonitorTheme.font(10.5)).foregroundStyle(MonitorTheme.muted)
                    .padding(.vertical, 5)
                if let edit = section.edit {
                    MonitorSettingsActionPill(title: section.editTitle, action: edit)
                        .padding(.vertical, 8)
                        .accessibilityHint(section.editHint ?? "")
                        .accessibilityIdentifier("monitor.settings.display.edit.\(section.id)")
                } else if let help = section.unavailableEditHelp {
                    caption(help).padding(.vertical, 6)
                }
                MonitorSnapshotRows(section.visibility, id: \.id) { item in
                    MonitorSettingsSwitchInlineRow(
                        title: item.title, help: item.help, isOn: item.isOn,
                        identifier: "monitor.settings.display.toggle.\(item.id)", action: item.action
                    )
                }.rows
                if !section.pins.isEmpty {
                    if let title = section.pinsTitle { caption(title).padding(.top, 8) }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 116), spacing: 7)], spacing: 7) {
                        MonitorSnapshotRows(section.pins, id: \.id) { item in
                            MonitorSettingsDisplayToggle(title: item.title, isOn: item.isOn, action: item.action)
                                .accessibilityLabel(item.accessibilityLabel)
                                .accessibilityValue(item.isOn ? "On" : "Off")
                                .accessibilityIdentifier("monitor.settings.display.toggle.\(item.id)")
                        }.rows
                    }
                }
            }
        }
        private func caption(_ text: String) -> some View {
            Text(text).font(MonitorTheme.font(11, weight: .semibold)).foregroundStyle(MonitorTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
#endif
