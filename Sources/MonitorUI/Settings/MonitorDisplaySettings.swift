#if os(iOS)
    import SwiftUI
    import UIKit

    /// Stable capture-layout identity; storage and camera-mode eligibility belong to the host.
    public struct MonitorDisplayChoice: Identifiable {
        public let id: String
        public let title: String
        public init(id: String, title: String) {
            self.id = id
            self.title = title
        }
    }

    /// A known visibility value and its admitted host action.
    public struct MonitorDisplayToggle: Identifiable {
        public let id: String
        public let title: String
        public let isOn: Bool
        public let accessibilityLabel: String
        public let action: () -> Void
        public init(
            id: String, title: String, isOn: Bool, accessibilityLabel: String? = nil,
            action: @escaping () -> Void
        ) {
            self.id = id
            self.title = title
            self.isOn = isOn
            self.accessibilityLabel = accessibilityLabel ?? title
            self.action = action
        }
    }

    /// An absent toggle means the item is permanently included, rather than an inert lit switch.
    public struct MonitorDisplayOrderItem: Identifiable {
        public let id: String
        public let title: String
        public let isOn: Bool
        public let supplement: String?
        public let highlighted: Bool
        public let visibilityLabel: String
        public let visibilityValue: String
        public let toggle: (() -> Void)?
        public init(
            id: String, title: String, isOn: Bool, supplement: String? = nil,
            highlighted: Bool = false, visibilityLabel: String? = nil,
            visibilityValue: String? = nil,
            toggle: (() -> Void)? = nil
        ) {
            self.id = id
            self.title = title
            self.isOn = isOn
            self.supplement = supplement
            self.highlighted = highlighted
            self.visibilityLabel = visibilityLabel ?? title
            self.visibilityValue = visibilityValue ?? (isOn ? "Shown" : "Hidden")
            self.toggle = toggle
        }
    }

    /// Supplied order, reset and destination actions; persistence stays with the host.
    public struct MonitorDisplayOrderGroup {
        public let title: String
        public let caption: String
        public let items: [MonitorDisplayOrderItem]
        public let reset: (() -> Void)?
        /// A direct destination index, after removal of the dragged item.
        public let move: (String, Int) -> Void
        public init(
            title: String, caption: String, items: [MonitorDisplayOrderItem],
            reset: (() -> Void)? = nil, move: @escaping (String, Int) -> Void
        ) {
            self.title = title
            self.caption = caption
            self.items = items
            self.reset = reset
            self.move = move
        }
    }

    /// Typed contents of a display mode. Only an eligible host supplies the live editor action.
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
        public let readoutsTitle: String?
        public let readouts: [MonitorDisplayToggle]
        public let pinsTitle: String?
        public let pins: [MonitorDisplayToggle]
        public let tools: MonitorDisplayOrderGroup?
        public init(
            id: String, title: String, caption: String, reset: (() -> Void)? = nil,
            editTitle: String = "Edit view", editHint: String? = nil, edit: (() -> Void)? = nil,
            unavailableEditHelp: String? = nil, visibility: [MonitorDisplayToggle] = [],
            readoutsTitle: String? = nil, readouts: [MonitorDisplayToggle] = [],
            pinsTitle: String? = nil, pins: [MonitorDisplayToggle] = [],
            tools: MonitorDisplayOrderGroup? = nil
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
            self.readoutsTitle = readoutsTitle
            self.readouts = readouts
            self.pinsTitle = pinsTitle
            self.pins = pins
            self.tools = tools
        }
    }

    /// Common Display assembly, driven by actual values and actions instead of a whole-page slot.
    public struct MonitorDisplaySettings: View {
        private let layoutTitle: String
        private let layoutHelp: String
        private let choices: [MonitorDisplayChoice]
        @Binding private var selection: String
        @Binding private var expandedSection: String?
        private let sections: [MonitorDisplaySection]
        private let order: MonitorDisplayOrderGroup
        public init(
            layoutTitle: String = "Layout For", layoutHelp: String,
            choices: [MonitorDisplayChoice], selection: Binding<String>,
            expandedSection: Binding<String?>,
            sections: [MonitorDisplaySection], order: MonitorDisplayOrderGroup
        ) {
            self.layoutTitle = layoutTitle
            self.layoutHelp = layoutHelp
            self.choices = choices
            self._selection = selection
            self._expandedSection = expandedSection
            self.sections = sections
            self.order = order
        }
        public var body: some View {
            MonitorSettingsRowCard {
                MonitorSettingsInlineRow(
                    title: layoutTitle, help: layoutHelp, showTopDivider: false
                ) {
                    captureChoices
                }
            }
            MonitorSnapshotRows(sections, id: \.id) { section in
                MonitorSettingsGroupCard(
                    title: section.title, caption: section.caption,
                    onReset: section.reset,
                    expansion: Binding(
                        get: { expandedSection == section.id },
                        set: { expandedSection = $0 ? section.id : nil })
                ) {
                    sectionContents(section)
                }
                .accessibilityIdentifier("monitor.settings.display.section.\(section.id)")
            }.rows
            MonitorSettingsGroupCard(
                title: order.title, caption: order.caption, onReset: order.reset
            ) {
                MonitorDisplayOrderList(items: order.items, move: order.move)
            }
        }
        private var captureChoices: some View {
            MonitorSegmentedControl(
                options: choices.map(\.id), selection: $selection,
                title: { id in choices.first(where: { $0.id == id })?.title ?? id }
            )
            .accessibilityIdentifier("monitor.settings.display.capture")
        }
        @ViewBuilder private func sectionContents(_ section: MonitorDisplaySection) -> some View {
            VStack(alignment: .leading, spacing: 10) {
                if let edit = section.edit {
                    MonitorSettingsActionPill(title: section.editTitle, action: edit)
                        .accessibilityHint(section.editHint ?? "")
                        .accessibilityIdentifier("monitor.settings.display.edit.\(section.id)")
                    if !section.readouts.isEmpty {
                        if let title = section.readoutsTitle { caption(title) }
                        MonitorDisplayToggleGrid(items: section.readouts)
                    }
                    if !section.pins.isEmpty {
                        if let title = section.pinsTitle { caption(title) }
                        MonitorDisplayToggleGrid(items: section.pins)
                    }
                    if let tools = section.tools {
                        caption(tools.caption)
                        MonitorDisplayOrderList(items: tools.items, move: tools.move)
                    }
                } else {
                    if let help = section.unavailableEditHelp { caption(help) }
                    MonitorDisplayToggleGrid(items: section.visibility)
                }
            }
        }
        private func caption(_ text: String) -> some View {
            Text(text).font(MonitorTheme.font(11, weight: .semibold)).foregroundStyle(
                MonitorTheme.muted
            )
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Complete labels and switches must fit before a pane gains another column.
    public enum MonitorDisplayMetrics {
        public static func toggleColumnCount(
            compact: Bool, availableWidth: CGFloat, minimumCellWidth: CGFloat = 0
        ) -> Int {
            precondition(availableWidth >= 0 && minimumCellWidth >= 0)
            if !compact && availableWidth >= 480 && (availableWidth - 21) / 4 >= minimumCellWidth {
                return 4
            }
            return (availableWidth - 7) / 2 >= minimumCellWidth ? 2 : 1
        }
    }

    /// Native label measurement keeps each supplied toggle inside its card.
    public struct MonitorDisplayToggleGrid: View {
        private let items: [MonitorDisplayToggle]
        @State private var availableWidth: CGFloat = 0
        @ScaledMetric(relativeTo: .body) private var labelSize: CGFloat = 11.5
        public init(items: [MonitorDisplayToggle]) { self.items = items }
        public var body: some View {
            // Register the same bundled face used by the actual common toggle before measuring.
            let _ = MonitorTheme.font(labelSize, weight: .semibold)
            let font =
                UIFont(name: "Sora-SemiBold", size: labelSize)
                ?? UIFont.systemFont(ofSize: labelSize, weight: .semibold)
            let labelWidth =
                items.map {
                    ($0.title as NSString).size(withAttributes: [.font: font]).width
                }.max() ?? 0
            let count = MonitorDisplayMetrics.toggleColumnCount(
                compact: availableWidth < 480, availableWidth: availableWidth,
                minimumCellWidth: labelWidth + 39 + 18 + 14)
            LazyVGrid(
                columns: Array(
                    repeating: GridItem(.flexible(minimum: 0), spacing: 7), count: count),
                spacing: 7
            ) {
                MonitorSnapshotRows(items, id: \.id) { item in
                    MonitorSettingsDisplayToggle(
                        title: item.title, isOn: item.isOn, action: item.action
                    )
                    .accessibilityLabel(item.accessibilityLabel)
                    .accessibilityValue(item.isOn ? "On" : "Off")
                    .accessibilityIdentifier("monitor.settings.display.toggle.\(item.id)")
                }.rows
            }
            .background {
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { availableWidth = proxy.size.width }
                        .onChange(of: proxy.size.width) { _, width in availableWidth = width }
                }
            }
        }
    }

    /// Native drag previews and row drop destinations leave parent scrolling enabled for autoscroll.
    public struct MonitorDisplayOrderList: View {
        private let items: [MonitorDisplayOrderItem]
        private let move: (String, Int) -> Void
        @State private var dropTargetIndex: Int?
        private let shuffle = Animation.spring(response: 0.28, dampingFraction: 0.86)
        public init(items: [MonitorDisplayOrderItem], move: @escaping (String, Int) -> Void) {
            self.items = items
            self.move = move
        }
        public var body: some View {
            VStack(spacing: 0) {
                MonitorSnapshotRows(Array(items.enumerated()), id: \.element.id) { index, item in
                    HStack(spacing: 6) {
                        rowContent(item, index: index).frame(
                            maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "line.3.horizontal")
                            .font(MonitorTheme.font(12, weight: .semibold)).foregroundStyle(
                                MonitorTheme.faint
                            )
                            .frame(width: 44, height: 34).contentShape(Rectangle())
                            .draggable(item.id) {
                                rowContent(item, index: index)
                                    .frame(width: 300, alignment: .leading)
                                    .padding(.vertical, 8).padding(.horizontal, 10)
                                    .background(
                                        MonitorTheme.surface, in: RoundedRectangle(cornerRadius: 10)
                                    )
                            }
                            .accessibilityLabel("Reorder handle")
                            .accessibilityHint("Drag to reorder.")
                            .accessibilityIdentifier("monitor.settings.display.grip.\(item.id)")
                    }
                    .padding(.vertical, 6).padding(.horizontal, 4).frame(minHeight: 34)
                    .contentShape(Rectangle())
                    .overlay(alignment: .top) {
                        if dropTargetIndex == index {
                            Capsule().fill(MonitorTheme.accent).frame(height: 2).padding(
                                .horizontal, 4)
                        }
                    }
                    .dropDestination(for: String.self) { ids, _ in
                        defer { dropTargetIndex = nil }
                        guard let id = ids.first,
                            let source = items.firstIndex(where: { $0.id == id }),
                            source != index
                        else { return false }
                        withAnimation(shuffle) { move(id, index) }
                        return true
                    } isTargeted: { targeted in
                        dropTargetIndex =
                            targeted ? index : (dropTargetIndex == index ? nil : dropTargetIndex)
                    }
                }.rows
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        private func rowContent(_ item: MonitorDisplayOrderItem, index: Int) -> some View {
            HStack(spacing: 10) {
                Text("\(index + 1)").font(MonitorTheme.font(9, weight: .medium)).monospacedDigit()
                    .foregroundStyle(MonitorTheme.muted).frame(width: 18, height: 18)
                    .background(MonitorTheme.surface, in: Circle())
                Text(item.title).font(MonitorTheme.font(12.5, weight: .semibold))
                    .foregroundStyle(
                        item.highlighted
                            ? MonitorTheme.accent
                            : (item.isOn ? MonitorTheme.text : MonitorTheme.muted)
                    )
                    .lineLimit(1).minimumScaleFactor(0.75)
                Spacer(minLength: 0)
                if let supplement = item.supplement {
                    Text(supplement).font(MonitorTheme.font(9.5, weight: .bold)).monospacedDigit()
                        .foregroundStyle(MonitorTheme.faint)
                }
                if let toggle = item.toggle {
                    Button(action: toggle) {
                        Image(systemName: item.isOn ? "eye.fill" : "eye.slash")
                            .font(MonitorTheme.font(10, weight: .semibold))
                            .foregroundStyle(item.isOn ? MonitorTheme.accent : MonitorTheme.faint)
                            .frame(width: 28, height: 28).contentShape(Rectangle())
                    }
                    .buttonStyle(MonitorSettingsButtonStyle())
                    .accessibilityLabel(item.visibilityLabel).accessibilityValue(
                        item.visibilityValue
                    )
                    .accessibilityIdentifier("monitor.settings.display.visibility.\(item.id)")
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("\(item.title), position \(index + 1)")
            .accessibilityHint(
                item.toggle == nil
                    ? "Always included. Drag to reorder."
                    : "Tap the eye to show or hide. Drag to reorder."
            )
            .accessibilityAction(named: "Move \(item.title) earlier") {
                if index > 0 { move(item.id, index - 1) }
            }
            .accessibilityAction(named: "Move \(item.title) later") {
                if index < items.count - 1 { move(item.id, index + 1) }
            }
        }
    }
#endif
