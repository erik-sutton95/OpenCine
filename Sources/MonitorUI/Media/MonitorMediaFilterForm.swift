#if os(iOS)
    import SwiftUI

    /// The source owns identity; labels never determine the value sent to its action.
    public struct MonitorMediaFilterChoice: Identifiable, Equatable, Sendable {
        public var id: String
        public var label: String

        public init(id: String, label: String) {
            self.id = id
            self.label = label
        }
    }

    /// Multiple supplied photo-size choices; the host owns selection and filtering.
    public struct MonitorMediaPhotoSizeChoices {
        public var options: [MonitorMediaFilterChoice]
        public var selectedIds: Set<String>
        public var onToggle: (String) -> Void

        public init(
            options: [MonitorMediaFilterChoice], selectedIds: Set<String>,
            onToggle: @escaping (String) -> Void
        ) {
            self.options = options
            self.selectedIds = selectedIds
            self.onToggle = onToggle
        }
    }

    /// Exclusive supplied relative windows; the host computes their date boundaries.
    public struct MonitorMediaDateWindowChoices {
        public var options: [MonitorMediaFilterChoice]
        public var selectedId: String?
        public var onToggle: (String) -> Void

        public init(
            options: [MonitorMediaFilterChoice], selectedId: String?,
            onToggle: @escaping (String) -> Void
        ) {
            self.options = options
            self.selectedId = selectedId
            self.onToggle = onToggle
        }
    }

    /// Observed volumes with source identities; an absent input omits storage filtering.
    public struct MonitorMediaStorageChoices {
        public var options: [MonitorMediaFilterChoice]
        public var selectedId: String?
        public var onToggle: (String) -> Void

        public init(
            options: [MonitorMediaFilterChoice], selectedId: String?,
            onToggle: @escaping (String) -> Void
        ) {
            self.options = options
            self.selectedId = selectedId
            self.onToggle = onToggle
        }
    }

    /// The default retains each platform's existing arrangement.
    public enum MonitorMediaFilterChipLayout: Equatable, Sendable {
        case platformDefault
        case horizontalScroll
    }

    /// Filter body shared by brand media pages. Native calendars stay in the shell.
    public struct MonitorMediaFilterForm: View {
        public struct ColorOption: Identifiable, Equatable, Sendable {
            public var id: UInt8
            public var label: String
            public init(id: UInt8, label: String) {
                self.id = id
                self.label = label
            }
        }

        public var formats: [String]
        public var resolutions: [String]
        public var colors: [ColorOption]
        public var formatSelection: Set<String>
        public var resolutionSelection: Set<String>
        public var colorSelection: Set<UInt8>
        public var dateStartLabel: String?
        public var dateEndLabel: String?
        public var hasDates: Bool
        public var onToggleFormat: (String) -> Void
        public var onToggleResolution: (String) -> Void
        public var onToggleColor: (UInt8) -> Void
        public var onPickStart: () -> Void
        public var onPickEnd: () -> Void
        public var onClear: () -> Void
        public var photoSizes: MonitorMediaPhotoSizeChoices?
        public var dateWindows: MonitorMediaDateWindowChoices?
        public var storage: MonitorMediaStorageChoices?
        public var chipLayout: MonitorMediaFilterChipLayout
        public var showsInlineClear: Bool
        /// A source can retain an active filter while its available choices are hidden.
        public var hasActiveFilters: Bool?
        /// Opaque source identities support color catalogues without narrowing them to wire bytes.
        public var colorChoices: [MonitorMediaFilterChoice]?
        public var colorIDs: Set<String>
        public var onToggleColorID: ((String) -> Void)?

        public init(
            formats: [String], resolutions: [String], colors: [ColorOption],
            formatSelection: Set<String>, resolutionSelection: Set<String>,
            colorSelection: Set<UInt8>, dateStartLabel: String?, dateEndLabel: String?,
            hasDates: Bool, onToggleFormat: @escaping (String) -> Void,
            onToggleResolution: @escaping (String) -> Void,
            onToggleColor: @escaping (UInt8) -> Void, onPickStart: @escaping () -> Void,
            onPickEnd: @escaping () -> Void, onClear: @escaping () -> Void,
            photoSizes: MonitorMediaPhotoSizeChoices? = nil,
            dateWindows: MonitorMediaDateWindowChoices? = nil,
            storage: MonitorMediaStorageChoices? = nil,
            chipLayout: MonitorMediaFilterChipLayout = .platformDefault,
            showsInlineClear: Bool = true, hasActiveFilters: Bool? = nil,
            colorChoices: [MonitorMediaFilterChoice]? = nil, colorIDs: Set<String> = [],
            onToggleColorID: ((String) -> Void)? = nil
        ) {
            self.formats = formats
            self.resolutions = resolutions
            self.colors = colors
            self.formatSelection = formatSelection
            self.resolutionSelection = resolutionSelection
            self.colorSelection = colorSelection
            self.dateStartLabel = dateStartLabel
            self.dateEndLabel = dateEndLabel
            self.hasDates = hasDates
            self.onToggleFormat = onToggleFormat
            self.onToggleResolution = onToggleResolution
            self.onToggleColor = onToggleColor
            self.onPickStart = onPickStart
            self.onPickEnd = onPickEnd
            self.onClear = onClear
            self.photoSizes = photoSizes
            self.dateWindows = dateWindows
            self.storage = storage
            self.chipLayout = chipLayout
            self.showsInlineClear = showsInlineClear
            self.hasActiveFilters = hasActiveFilters
            self.colorChoices = colorChoices; self.colorIDs = colorIDs; self.onToggleColorID = onToggleColorID
        }

        private var empty: Bool {
            formats.isEmpty && resolutions.isEmpty && !hasDates && (colorChoices?.isEmpty ?? colors.isEmpty)
                && (photoSizes?.options.isEmpty ?? true)
                && (dateWindows?.options.isEmpty ?? true)
                && (storage?.options.isEmpty ?? true)
        }

        private var active: Bool {
            if let hasActiveFilters { return hasActiveFilters }
            return !formatSelection.isEmpty || !resolutionSelection.isEmpty
                || !colorSelection.isEmpty || !colorIDs.isEmpty
                || dateStartLabel != nil || dateEndLabel != nil
                || !(photoSizes?.selectedIds.isEmpty ?? true)
                || dateWindows?.selectedId != nil || storage?.selectedId != nil
        }

        public var body: some View {
            VStack(alignment: .leading, spacing: 10) {
                if !formats.isEmpty {
                    chipSection("FORMAT", formats, formatSelection, onToggleFormat)
                }
                if !resolutions.isEmpty {
                    chipSection("RESOLUTION", resolutions, resolutionSelection, onToggleResolution)
                }
                if let photoSizes, !photoSizes.options.isEmpty {
                    choiceSection(
                        "SIZE", photoSizes.options, photoSizes.selectedIds, photoSizes.onToggle)
                }
                if let dateWindows, !dateWindows.options.isEmpty {
                    choiceSection(
                        "DATE", dateWindows.options, Set(dateWindows.selectedId.map { [$0] } ?? []),
                        dateWindows.onToggle)
                }
                if hasDates {
                    section("DATE") {
                        HStack(spacing: 6) {
                            dateField("Start", dateStartLabel, onPickStart)
                            Text("–").font(MonitorTheme.font(10.5, weight: .semibold))
                                .foregroundStyle(MonitorTheme.muted)
                            dateField("End", dateEndLabel, onPickEnd)
                        }
                    }
                }
                if let colorChoices, !colorChoices.isEmpty {
                    choiceSection("COLOUR", colorChoices, colorIDs) { onToggleColorID?($0) }
                } else if colorChoices == nil, !colors.isEmpty {
                    choiceSection("COLOUR", colors.map { .init(id: String($0.id), label: $0.label) },
                        Set(colorSelection.map { String($0) })) { id in
                            if let byte = UInt8(id) { onToggleColor(byte) }
                        }
                }
                if let storage, !storage.options.isEmpty {
                    choiceSection(
                        "STORAGE", storage.options, Set(storage.selectedId.map { [$0] } ?? []),
                        storage.onToggle)
                }
                if empty {
                    Text("Nothing in this tab to filter by.")
                        .font(MonitorTheme.font(11)).foregroundStyle(MonitorTheme.faint)
                }
                if showsInlineClear && active {
                    Button("Clear all filters", action: onClear)
                        .font(MonitorTheme.font(11, weight: .semibold))
                        .foregroundStyle(MonitorTheme.accent)
                        .accessibilityIdentifier("monitor.media.filter.clear")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content)
            -> some View
        {
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(MonitorTheme.font(9, weight: .bold)).foregroundStyle(
                    MonitorTheme.muted)
                content()
            }
        }

        private func chipSection(
            _ title: String, _ titles: [String], _ active: Set<String>,
            _ toggle: @escaping (String) -> Void
        ) -> some View {
            choiceSection(
                title, titles.map { MonitorMediaFilterChoice(id: $0, label: $0) }, active, toggle)
        }

        private func choiceSection(
            _ title: String, _ choices: [MonitorMediaFilterChoice], _ active: Set<String>,
            _ toggle: @escaping (String) -> Void
        ) -> some View {
            section(title) {
                choiceGrid(
                    choices, active, group: title.lowercased(), storageIcon: title == "STORAGE",
                    toggle)
            }
        }

        private func chipGrid(
            _ titles: [String], _ active: Set<String>, _ toggle: @escaping (String) -> Void
        ) -> some View {
            choiceGrid(
                titles.map { MonitorMediaFilterChoice(id: $0, label: $0) }, active, group: "colour",
                toggle)
        }

        @ViewBuilder
        private func choiceGrid(
            _ choices: [MonitorMediaFilterChoice], _ active: Set<String>, group: String,
            storageIcon: Bool = false, _ toggle: @escaping (String) -> Void
        ) -> some View {
            let columns = [GridItem(.adaptive(minimum: 150), spacing: 5)]
            if chipLayout == .horizontalScroll {
                ScrollView(.horizontal) {
                    HStack(spacing: 5) {
                        ForEach(choices) { choice in
                            choiceButton(
                                choice, active: active, group: group, storageIcon: storageIcon,
                                expands: false, toggle)
                        }
                    }
                }
                .scrollIndicators(.hidden)
            } else {
                LazyVGrid(columns: columns, spacing: 5) {
                    ForEach(choices) { choice in
                        choiceButton(
                            choice, active: active, group: group, storageIcon: storageIcon,
                            expands: true, toggle)
                    }
                }
            }
        }

        private func choiceButton(
            _ choice: MonitorMediaFilterChoice, active: Set<String>, group: String,
            storageIcon: Bool, expands: Bool, _ toggle: @escaping (String) -> Void
        ) -> some View {
            Button {
                toggle(choice.id)
            } label: {
                HStack(spacing: 4) {
                    if storageIcon {
                        Image(systemName: "sdcard.fill").font(.system(size: 10, weight: .semibold))
                    }
                    Text(choice.label)
                        .font(MonitorTheme.font(10, weight: .semibold))
                        .lineLimit(1).minimumScaleFactor(0.85)
                }
                .foregroundStyle(
                    active.contains(choice.id) ? MonitorTheme.accent : MonitorTheme.muted
                )
                .frame(maxWidth: expands ? .infinity : nil, minHeight: 30)
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(
                    active.contains(choice.id)
                        ? MonitorTheme.accent.opacity(0.14) : Color.white.opacity(0.04),
                    in: Capsule())
            }
            .buttonStyle(FilterChoiceButtonStyle())
            .accessibilityLabel(choice.label)
            .accessibilityAddTraits(active.contains(choice.id) ? .isSelected : [])
            .accessibilityIdentifier("monitor.media.filter.\(group).\(choice.id)")
        }

        private func dateField(_ title: String, _ label: String?, _ action: @escaping () -> Void)
            -> some View
        {
            Button(action: action) {
                Text(label ?? title)
                    .font(MonitorTheme.font(10.5, weight: .semibold))
                    .foregroundStyle(label == nil ? MonitorTheme.muted : MonitorTheme.text)
                    .frame(maxWidth: .infinity, minHeight: 34)
                    .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 9))
            }
            .buttonStyle(MonitorButtonStyle())
            .accessibilityLabel(title)
            .accessibilityValue(label ?? "Any")
            .accessibilityIdentifier("monitor.media.filter.\(title.lowercased())")
        }
    }

    /// Keep the compact drawn chip while retaining its 44-point native hit area.
    private struct FilterChoiceButtonStyle: ButtonStyle {
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .modifier(FilterChoiceTouchArea())
                .opacity(configuration.isPressed ? MonitorMotion.pressOpacity : 1)
                .scaleEffect(
                    configuration.isPressed && !reduceMotion ? MonitorMotion.pressScale : 1
                )
                .animation(MonitorMotion.press(reduceMotion), value: configuration.isPressed)
        }
    }

    private struct FilterChoiceSize: PreferenceKey {
        static let defaultValue: CGSize = .zero
        static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
            let next = nextValue()
            if next != .zero { value = next }
        }
    }

    private struct FilterChoiceTouchArea: ViewModifier {
        @State private var measuredSize: CGSize = .zero

        func body(content: Content) -> some View {
            let horizontal =
                measuredSize != .zero ? max(0, (44 - measuredSize.width) / 2) : 0
            let vertical =
                measuredSize != .zero ? max(0, (44 - measuredSize.height) / 2) : 0
            content
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(key: FilterChoiceSize.self, value: proxy.size)
                    }
                }
                .onPreferenceChange(FilterChoiceSize.self) { measuredSize = $0 }
                .padding(.horizontal, horizontal).padding(.vertical, vertical)
                .contentShape(Rectangle())
                .padding(.horizontal, -horizontal).padding(.vertical, -vertical)
        }
    }

#endif
