#if os(iOS)
    import MonitorPresentation
    import MonitorUI
    import OpenCineMulticam
    import SwiftUI

    /// What the stage asks of the app. Every camera action is the app's: the stage lays out,
    /// selects, shows options and confirms record.
    public struct MultiviewStageActions {
        /// Double tap or the Live View option. The app checks the camera can open.
        public var openLiveView: (Int) -> Void
        /// Add camera on an empty slot.
        public var add: (Int) -> Void
        /// A `MultiviewCameraAction` other than record, by id, for a slot.
        public var perform: (_ action: String, _ slot: Int) -> Void
        /// A readout choice: slot, readout index and the choice the operator picked, as shown.
        public var choose: (_ slot: Int, _ readout: Int, _ choice: String) -> Void
        /// The LUT tool.
        public var toggleLUT: () -> Void
        /// The CAMERA tool: the app shows its settings panel for the slot over the stage, and
        /// hides it again on `popupsClosed`.
        public var openSettings: (Int) -> Void
        /// The close button.
        public var close: () -> Void
        /// The record plan now: every camera (`nil`) or one slot.
        public var recordContext: (_ slot: Int?) -> MultiviewRecordContext
        /// Runs an approved plan.
        public var record: (_ plan: RecordPlan, _ slot: Int?) async -> Void
        /// The options or settings popup closed (also on backgrounding).
        public var popupsClosed: () -> Void

        public init(
            openLiveView: @escaping (Int) -> Void, add: @escaping (Int) -> Void,
            perform: @escaping (String, Int) -> Void,
            choose: @escaping (Int, Int, String) -> Void = { _, _, _ in },
            toggleLUT: @escaping () -> Void = {}, openSettings: @escaping (Int) -> Void = { _ in },
            close: @escaping () -> Void,
            recordContext: @escaping (Int?) -> MultiviewRecordContext,
            record: @escaping (RecordPlan, Int?) async -> Void,
            popupsClosed: @escaping () -> Void = {}
        ) {
            self.openLiveView = openLiveView
            self.add = add
            self.perform = perform
            self.choose = choose
            self.toggleLUT = toggleLUT
            self.openSettings = openSettings
            self.close = close
            self.recordContext = recordContext
            self.record = record
            self.popupsClosed = popupsClosed
        }
    }

    /// A chrome button the app adds at the stage's network slot (top, beside close).
    public struct MultiviewStageButton {
        public var title: String
        public var value: String
        public var icon: MonitorIcon
        public var enabled: Bool
        public var identifier: String
        public var action: () -> Void

        public init(
            title: String, value: String = "", icon: MonitorIcon, enabled: Bool = true,
            identifier: String, action: @escaping () -> Void
        ) {
            self.title = title
            self.value = value
            self.icon = icon
            self.enabled = enabled
            self.identifier = identifier
            self.action = action
        }
    }

    /// The shared Multiview stage: slots laid out by `MultiviewPresentationLayout` (Grid or
    /// Center stage), each with its picture, identity chrome and options, plus close, the app's
    /// network button, the assist tools, the program readouts, DISP and record on all cameras.
    /// Values and actions only; the app owns sessions, sheets, its settings panel and the
    /// camera picker.
    public struct MultiviewStage<Picture: View, Backdrop: ViewModifier>: View {
        private let tiles: [MultiviewTile?]
        private let layout: MultiviewPresentationLayout
        @Binding private var arrangement: MultiviewPresentationLayout.Arrangement
        @Binding private var selected: Int
        @Binding private var fill: Bool
        private let tools: [MultiviewTool]
        private let readouts: [MultiviewReadout]?
        private let lut: Bool
        private let recording: Bool
        private let busy: Bool
        private let groupBusy: Bool
        private let confirmsRecord: Bool
        private let network: MultiviewStageButton?
        private let geometry: MultiviewStageGeometry
        private let actions: MultiviewStageActions
        private let picture: (Int) -> Picture
        private let backdrop: Backdrop
        private let viewport: CGSize
        private let safeArea: EdgeInsets
        @Environment(\.multiviewStageServices) private var services
        @Environment(\.multiviewStageVisible) private var stageVisible
        @Environment(\.multiviewStageState) private var sharedState
        @State private var fallbackState: MultiviewStageState
        private var presentation: MultiviewStageState { sharedState ?? fallbackState }
        private var clean: Bool { presentation.clean }
        @State private var optionsSlot: Int?
        @Environment(\.scenePhase) private var scenePhase

        /// - Parameters:
        ///   - tiles: one per slot, `nil` while the slot is empty.
        ///   - viewport, safeArea: the stage size and the insets `layout` was made with; the
        ///     options popup keeps inside them.
        ///   - readouts: the program camera's values under Center stage, `nil` to hide them.
        ///   - busy: the app is changing membership or the network: no close or add.
        ///   - groupBusy: a group record runs.
        ///   - backdrop: wraps the stage under its popups (a video backdrop reads `geometry`).
        public init(
            tiles: [MultiviewTile?], layout: MultiviewPresentationLayout, viewport: CGSize,
            safeArea: EdgeInsets,
            arrangement: Binding<MultiviewPresentationLayout.Arrangement>,
            selected: Binding<Int>, fill: Binding<Bool>, tools: [MultiviewTool],
            readouts: [MultiviewReadout]?, lut: Bool = false, recording: Bool,
            busy: Bool = false, groupBusy: Bool, confirmsRecord: Bool,
            network: MultiviewStageButton? = nil,
            geometry: MultiviewStageGeometry = MultiviewStageGeometry(),
            actions: MultiviewStageActions, @ViewBuilder picture: @escaping (Int) -> Picture,
            backdrop: Backdrop
        ) {
            _fallbackState = State(
                initialValue: MultiviewStageState(slotCount: max(1, tiles.count)))
            self.tiles = tiles
            self.layout = layout
            self.viewport = viewport
            self.safeArea = safeArea
            _arrangement = arrangement
            _selected = selected
            _fill = fill
            self.tools = tools
            self.readouts = readouts
            self.lut = lut
            self.recording = recording
            self.busy = busy
            self.groupBusy = groupBusy
            self.confirmsRecord = confirmsRecord
            self.network = network
            self.geometry = geometry
            self.actions = actions
            self.picture = picture
            self.backdrop = backdrop
        }

        public var body: some View {
            ZStack(alignment: .topLeading) {
                MonitorTheme.canvas
                MultiviewStageCanvas(slots: tiles.count, layout: layout, geometry: geometry) {
                    index in
                    let frame = layout.tiles[index]
                    let overlay = layout.readoutsOverlay && index == selected
                    tileView(
                        index, compact: frame.width < 200 || frame.height < 136,
                        condensed: frame.height < 80,
                        // Grid's selected tile carries its values between the footer columns.
                        inlineValues: overlay && arrangement == .grid,
                        // The floating View Assist palette covers the main tile's lower
                        // left; its footer starts where the stage value row does.
                        footerLeading: overlay ? layout.readouts.x - frame.x : 0)
                }
                if !clean {
                    exitButton(size: layout.sessionControls.width)
                        .frame(
                            width: layout.sessionControls.width,
                            height: layout.sessionControls.height
                        )
                        .position(x: layout.sessionControls.midX, y: layout.sessionControls.midY)
                    assistPalette
                    if let network {
                        networkButton(network, size: layout.network.width)
                            .frame(width: layout.network.width, height: layout.network.height)
                            .position(x: layout.network.midX, y: layout.network.midY)
                    }
                    if arrangement == .centerStage, let readouts {
                        programReadouts(readouts)
                            .frame(width: layout.readouts.width, height: layout.readouts.height)
                            .position(x: layout.readouts.midX, y: layout.readouts.midY)
                    }
                }
                displayButton
                    .frame(width: layout.display.width, height: layout.display.height)
                    .position(x: layout.display.midX, y: layout.display.midY)
                recordAll(diameter: layout.record.width)
                    .position(x: layout.record.midX, y: layout.record.midY)
            }
            .frame(width: viewport.width, height: viewport.height)
            .background(MonitorTheme.canvas)
            .modifier(backdrop)
            .overlay { floatingPopups }
            .onChange(of: scenePhase) { _, phase in if phase != .active { closePopups() } }
            .onReceive(
                NotificationCenter.default.publisher(
                    for: UIApplication.willResignActiveNotification)
            ) { _ in closePopups() }
            .onDisappear { closePopups() }
            .onChange(of: stageVisible) { _, visible in if !visible { closePopups() } }
            // A removed camera takes its options with it.
            .onChange(of: optionsSlot.map { tiles.indices.contains($0) && tiles[$0] != nil }) {
                _, open in
                if open == false { closePopups() }
            }
        }

        private func closePopups() {
            optionsSlot = nil
            actions.popupsClosed()
        }

        @ViewBuilder
        private var floatingPopups: some View {
            if let slot = optionsSlot, let tile = tiles[slot] {
                let width = max(1, viewport.width - safeArea.leading - safeArea.trailing - 32)
                let height = max(1, viewport.height - safeArea.top - safeArea.bottom - 32)
                ZStack {
                    Color.black.opacity(0.18).contentShape(Rectangle())
                        .onTapGesture { closePopups() }
                        .accessibilityLabel("Dismiss camera panel")
                        .accessibilityAddTraits(.isButton)
                        .accessibilityIdentifier("multiview.popup.dismiss")
                    MultiviewCameraOptions(
                        tile: tile, maximumHeight: min(520, height), confirmsRecord: confirmsRecord,
                        recordContext: { actions.recordContext(slot) },
                        record: { await actions.record($0, slot) }, close: closePopups
                    ) { action in
                        if action.id == MultiviewCameraAction.liveView {
                            openLiveView(slot)
                        } else {
                            if action.closes { closePopups() }
                            actions.perform(action.id, slot)
                        }
                    }
                    .frame(width: min(440, width))
                    .position(
                        x: safeArea.leading
                            + (viewport.width - safeArea.leading - safeArea.trailing) / 2,
                        y: safeArea.top + (viewport.height - safeArea.top - safeArea.bottom) / 2)
                }
                .accessibilityAddTraits(.isModal)
                .preferredColorScheme(.dark)
            }
        }

        private func programReadouts(_ readouts: [MultiviewReadout]) -> some View {
            HStack(spacing: 6) {
                ForEach(Array(readouts.enumerated()), id: \.offset) { index, value in
                    readout(value, slot: selected, index: index)
                }
            }
            .frame(maxWidth: 316)
            .accessibilityIdentifier("multiview.readouts")
        }

        @ViewBuilder
        private func readout(_ value: MultiviewReadout, slot: Int, index: Int) -> some View {
            let label = VStack(spacing: 3) {
                Text(value.value).font(MonitorTheme.font(14, weight: .medium)).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.7)
                Text(value.title).font(MonitorTheme.font(7, weight: .semibold))
                    .tracking(0.8).foregroundStyle(MonitorTheme.muted)
            }
            .frame(maxWidth: .infinity)
            if value.choices.isEmpty {
                label
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(value.title + " " + value.value)
            } else {
                Menu {
                    ForEach(Array(value.choices.enumerated()), id: \.offset) { _, name in
                        Button(name) { actions.choose(slot, index, name) }
                    }
                } label: {
                    label
                }
                .accessibilityLabel(value.title + " " + value.value)
                .accessibilityIdentifier("multiview.value.\(value.title.lowercased())")
            }
        }

        // MARK: Tools

        @ViewBuilder
        private var assistPalette: some View {
            if layout.portrait && arrangement == .centerStage {
                toolColumn(frame: layout.assists, tablet: layout.tablet)
            } else {
                collapsiblePalette
            }
        }

        private var occupiedSlots: Set<Int> { Set(tiles.indices.filter { tiles[$0] != nil }) }

        private var toolItems: [MonitorToolItem] {
            let cameras = !occupiedSlots.isEmpty
            let offered = services?.availability.offeredTools(from: tools, occupiedSlots: occupiedSlots) ?? tools
            return offered.map { tool in
                switch tool {
                case .layout:
                    MonitorToolItem(
                        id: tool.rawValue, title: arrangement == .grid ? "FOCUS" : "GRID",
                        enabled: false, hasOptions: false,
                        accessibilityLabel: arrangement == .grid ? "Show Center stage" : "Show grid",
                        accessibilityValue: arrangement == .grid ? "Grid" : "Center stage",
                        accessibilityIdentifier: "multiview.layout")
                case .camera:
                    MonitorToolItem(
                        id: tool.rawValue, title: "CAMERA", enabled: false, hasOptions: false,
                        available: cameras, accessibilityLabel: "Camera settings",
                        accessibilityValue: "", accessibilityIdentifier: "multiview.settings")
                case .fit:
                    MonitorToolItem(
                        id: tool.rawValue, title: fill ? "FILL" : "FIT", enabled: false,
                        hasOptions: false,
                        accessibilityLabel: fill ? "Fit feed in frame" : "Fill frame with feed",
                        accessibilityValue: fill ? "Fill" : "Fit",
                        accessibilityIdentifier: "multiview.fitFill")
                case .lut:
                    MonitorToolItem(
                        id: tool.rawValue, title: "LUT", enabled: lut,
                        hasOptions: services?.configureLUT != nil,
                        available: cameras, accessibilityLabel: services?.automaticLUT == false
                            ? "Toggle LUT for all cameras" : "Toggle Auto LUT for all cameras")
                }
            }
        }

        @ViewBuilder
        private func toolIcon(_ id: String) -> some View {
            switch MultiviewTool(rawValue: id) {
            case .lut: MonitorAssistIcon.lut
            case .fit: fill ? MonitorIcon.minimize : MonitorIcon.maximize
            case .layout: arrangement == .grid ? MonitorIcon.layoutList : MonitorIcon.layoutGrid
            default: MonitorIcon.slidersHorizontal  // camera settings
            }
        }

        /// Portrait Center stage: the same tools as a plain, always-visible column
        /// spanning the secondary feeds. No chevron, drag or collapse.
        private func toolColumn(frame: MonitorRect, tablet: Bool) -> some View {
            let iconSide = MonitorSystemButtonMetrics.iconSide(tablet: tablet)
            return VStack(spacing: 0) {
                ForEach(toolItems) { tool in
                    Button {
                        activate(tool.id)
                    } label: {
                        toolIcon(tool.id)
                            .frame(width: iconSide, height: iconSide)
                            .foregroundStyle(
                                tool.enabled ? MonitorTheme.accent : MonitorTheme.secondary
                            )
                            .frame(maxWidth: .infinity, minHeight: 44, maxHeight: .infinity)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(MonitorButtonStyle())
                    .modifier(ToolOptionsMenu(enabled: tool.hasOptions) { configureTool(tool.id) })
                    .disabled(!tool.available)
                    .opacity(tool.available ? 1 : 0.4)
                    .accessibilityLabel(tool.accessibilityLabel ?? tool.title)
                    .accessibilityValue(tool.accessibilityValue ?? (tool.enabled ? "On" : "Off"))
                    .accessibilityIdentifier(
                        tool.accessibilityIdentifier ?? "multiview.tool.\(tool.id)")
                }
            }
            .padding(4)
            .frame(width: frame.width, height: frame.height)
            .monitorGlass(in: RoundedRectangle(cornerRadius: 14), density: .compact)
            .position(x: frame.midX, y: frame.midY)
        }

        private var collapsiblePalette: some View {
            let items = toolItems
            // Landscape stages mount Live View's palette as Live View does:
            // horizontal, anchored at its collapsed bottom-leading slot, growing
            // trailing short of DISP. Portrait Grid grows from its compact rail
            // within the viewport so expanded labels retain their full width.
            let horizontal = layout.assistsHorizontal
            let palette = MonitorAssistPaletteLayout(
                portrait: !horizontal, tablet: layout.tablet, expanded: true,
                toolCount: items.count,
                maximumWidth: horizontal
                    ? layout.display.x - 8 - layout.assists.x
                    : Double(viewport.width) - layout.assists.x - 14,
                maximumHeight: horizontal
                    ? layout.assists.maxY - max(layout.sessionControls.y, 8)
                    : layout.assists.height)
            let frame = palette.anchored(leading: layout.assists.x, bottom: layout.assists.maxY)
            return MonitorAssistPalette(
                tools: items, layout: palette,
                usageSeed: ["LAYOUT": 4, "CAMERA": 3, "FIT": 2, "LUT": 1],
                usage: Binding(
                    get: { presentation.toolUsage }, set: { presentation.toolUsage = $0 }),
                expanded: Binding(
                    get: { presentation.toolsExpanded }, set: { presentation.toolsExpanded = $0 }),
                onToggle: activate,
                onOptions: configureTool,
                accessibilityName: "Multiview tools", accessibilityPrefix: "multiview.toolbar"
            ) { id in
                toolIcon(id)
            }
            .frame(width: frame.width, height: frame.height)
            .position(x: frame.midX, y: frame.midY)
        }

        private func activate(_ id: String) {
            switch MultiviewTool(rawValue: id) {
            case .lut:
                if let services, services.availability.pictureLUTSlot(selected: selected, occupiedSlots: occupiedSlots) == nil { return }
                actions.toggleLUT()
            case .fit: fill.toggle()
            case .layout: arrangement = arrangement == .grid ? .centerStage : .grid
            case .camera:
                optionsSlot = nil
                let slot: Int?
                if let services {
                    slot = services.availability.cameraSettingsSlot(selected: selected, occupiedSlots: occupiedSlots)
                } else {
                    slot = tiles.indices.contains(selected) && tiles[selected] != nil
                        ? selected : tiles.firstIndex { $0 != nil }
                }
                if let slot { actions.openSettings(slot) }
            case nil: break
            }
        }

        private func configureTool(_ id: String) {
            guard MultiviewTool(rawValue: id) == .lut, let services,
                let slot = services.availability.pictureLUTSlot(selected: selected, occupiedSlots: occupiedSlots)
            else { return }
            services.configureLUT?(slot)
        }

        // MARK: Chrome buttons

        private func networkButton(_ button: MultiviewStageButton, size: CGFloat) -> some View {
            MonitorChromeButton(button.title, size: CGSize(width: size, height: size)) {
                closePopups()
                button.action()
            } label: {
                button.icon.frame(width: size * 29 / 54, height: size * 29 / 54)
            }
            .disabled(!button.enabled)
            .accessibilityLabel(button.title)
            .accessibilityValue(button.value)
            .accessibilityIdentifier(button.identifier)
        }

        private var displayButton: some View {
            Button {
                presentation.clean.toggle()
            } label: {
                VStack(spacing: 4) {
                    Text("DISP").font(MonitorTheme.font(12, weight: .bold)).tracking(0.4)
                    HStack(spacing: 3) {
                        Capsule().fill(clean ? Color.white.opacity(0.28) : MonitorTheme.accent)
                        Capsule().fill(clean ? MonitorTheme.accent : Color.white.opacity(0.28))
                    }.frame(width: 31, height: 3)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .monitorGlass(in: RoundedRectangle(cornerRadius: 14), density: .compact)
                .contentShape(Rectangle())
            }
            .foregroundStyle(clean ? .white : MonitorTheme.muted).buttonStyle(.plain)
            .accessibilityLabel("Change display mode").accessibilityValue(clean ? "Clean" : "Live")
            .accessibilityIdentifier("multiview.display")
        }

        private func exitButton(size: CGFloat) -> some View {
            MonitorChromeButton("Close Multiview", size: CGSize(width: size, height: size)) {
                actions.close()
            } label: {
                MonitorIcon.x.frame(width: size * 26 / 54, height: size * 26 / 54)
            }
            .accessibilityIdentifier("multiview.close")
            .accessibilityLabel("Close Multiview").disabled(busy || groupBusy)
        }

        private func recordAll(diameter: CGFloat) -> some View {
            MultiviewRecordAction(
                confirmationEnabled: confirmsRecord, context: { actions.recordContext(nil) },
                record: { await actions.record($0, nil) }
            ) {
                // Read inside the action's label so plan-building (every camera's state)
                // re-renders only this button, not the whole stage.
                let context = actions.recordContext(nil)
                MonitorRecordLamp(diameter: diameter, recording: recording)
                    .overlay { if groupBusy { ProgressView().tint(.white) } }
                    .opacity(
                        (!context.busy && context.plan.isExecutable) || groupBusy ? 1 : 0.4)
            }
            .buttonStyle(MultiviewPressStyle())
            .accessibilityLabel(recording ? "Stop all recording" : "Record all")
            .accessibilityIdentifier("multiview.recordAll")
        }

        // MARK: Tiles

        /// Center stage offers "Add camera" on the big tile while it is empty; otherwise on
        /// the first empty tile.
        private var addSlot: Int? {
            if arrangement == .centerStage, tiles.indices.contains(selected),
                tiles[selected] == nil
            {
                return selected
            }
            return tiles.firstIndex { $0 == nil }
        }

        private func tileView(
            _ index: Int, compact: Bool, condensed: Bool, inlineValues: Bool,
            footerLeading: CGFloat
        ) -> some View {
            let tile = tiles[index]
            let isSelected = index == selected
            return ZStack {
                RoundedRectangle(cornerRadius: 12).fill(MonitorTheme.surface)
                if let tile {
                    picture(index)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .allowsHitTesting(false)
                    // This hit surface stays beneath the options button. Neither selecting a
                    // camera nor rearranging the stage replaces its picture host.
                    Color.clear.contentShape(Rectangle())
                        .gesture(
                            TapGesture(count: 2).exclusively(before: TapGesture()).onEnded { tap in
                                switch tap {
                                case .first: openLiveView(index)
                                case .second: selected = index
                                }
                            }
                        )
                        .accessibilityElement()
                        .accessibilityLabel("Select camera " + MultiviewTile.letter(index))
                        .accessibilityValue((isSelected ? "Selected; " : "") + tile.accessibilityValue)
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction { selected = index }
                        .accessibilityIdentifier("multiview.tile.\(index)")
                    if !clean {
                        MultiviewTileChrome(
                            tile: tile, index: index, selected: isSelected, compact: compact,
                            condensed: condensed, reservedLeading: footerLeading,
                            inlineValues: inlineValues,
                            choose: { actions.choose(index, $0, $1) }
                        ) {
                            closePopups()
                            optionsSlot = index
                        }
                    }
                    if let status = tile.status {
                        statusPill(status, slot: index, compact: compact)
                    }
                } else if !clean, addSlot == index {
                    Button {
                        actions.add(index)
                    } label: {
                        HStack(spacing: 9) {
                            MonitorIcon.plus.frame(width: 23, height: 23)
                            Text("Add camera").font(MonitorTheme.font(12, weight: .medium))
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(MonitorTheme.muted)
                    .accessibilityLabel("Add camera")
                    .accessibilityIdentifier("multiview.add")
                    .disabled(busy || groupBusy)
                }
            }
            .foregroundStyle(.white)
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(
                        tile != nil && isSelected && !clean
                            ? MonitorTheme.accent : Color.white.opacity(0.08),
                        lineWidth: isSelected && tile != nil && !clean ? 2 : 1
                    )
                    .allowsHitTesting(false)
            }
            .overlay {
                if tile?.recording == true {
                    MonitorRecordingBorder(cornerRadius: 12).accessibilityHidden(true)
                }
            }
        }

        private func statusPill(_ status: MultiviewTileStatus, slot: Int, compact: Bool)
            -> some View
        {
            Button {
                closePopups()
                optionsSlot = slot
            } label: {
                HStack(spacing: 5) {
                    if status.inProgress { ProgressView().controlSize(.mini) }
                    Text(status.text)
                        .font(MonitorTheme.font(compact ? 9 : 12, weight: .medium))
                        .lineLimit(2).multilineTextAlignment(.center)
                }
                .padding(.horizontal, 9).padding(.vertical, 6)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain).padding(.horizontal, 8)
            .accessibilityLabel(status.detail)
            .accessibilityHint("Open camera options for details and recovery")
        }

        private func openLiveView(_ slot: Int) {
            closePopups()
            actions.openLiveView(slot)
        }
    }

    extension MultiviewStage where Backdrop == EmptyModifier {
        /// A stage without a video backdrop.
        public init(
            tiles: [MultiviewTile?], layout: MultiviewPresentationLayout, viewport: CGSize,
            safeArea: EdgeInsets,
            arrangement: Binding<MultiviewPresentationLayout.Arrangement>,
            selected: Binding<Int>, fill: Binding<Bool>, tools: [MultiviewTool],
            readouts: [MultiviewReadout]?, lut: Bool = false, recording: Bool, busy: Bool = false,
            groupBusy: Bool, confirmsRecord: Bool, network: MultiviewStageButton? = nil,
            geometry: MultiviewStageGeometry = MultiviewStageGeometry(),
            actions: MultiviewStageActions, @ViewBuilder picture: @escaping (Int) -> Picture
        ) {
            self.init(
                tiles: tiles, layout: layout, viewport: viewport, safeArea: safeArea,
                arrangement: arrangement, selected: selected, fill: fill, tools: tools,
                readouts: readouts, lut: lut, recording: recording, busy: busy,
                groupBusy: groupBusy, confirmsRecord: confirmsRecord, network: network,
                geometry: geometry, actions: actions, picture: picture, backdrop: EmptyModifier())
        }
    }

    /// A tile's identity and camera values over its picture. Formats nothing itself: every
    /// string is the app's, so the stage has no clock, polling or inferred timecode (a tally
    /// with `recordingSince` counts from the camera's first recording report).
    struct MultiviewTileChrome: View {
        let tile: MultiviewTile
        let index: Int
        let selected: Bool
        let compact: Bool
        let condensed: Bool
        /// The floating View Assist palette covers the main tile's lower left.
        var reservedLeading: CGFloat = 0
        /// Grid's selected tile shows its camera values between the footer columns.
        var inlineValues = false
        /// A pick from an inline value's choices: readout index, choice.
        var choose: (_ readout: Int, _ choice: String) -> Void = { _, _ in }
        let openOptions: () -> Void

        var body: some View {
            ZStack {
                if condensed { condensedChrome } else { regularChrome }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }

        private var condensedChrome: some View {
            HStack(spacing: 5) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(MultiviewTile.letter(index) + " · " + tile.name)
                        .font(MonitorTheme.font(9, weight: .semibold)).lineLimit(1)
                    HStack(spacing: 6) {
                        battery
                        tally.font(MonitorTheme.font(7)).lineLimit(1)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).allowsHitTesting(false)
                optionsButton
            }
            .padding(.leading, 8).padding(.trailing, 2)
            .shadow(color: .black.opacity(0.9), radius: 2, y: 1)
        }

        private var optionsButton: some View {
            Button(action: openOptions) {
                MonitorIcon.ellipsis.frame(width: 18, height: 18)
                    .frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Camera \(MultiviewTile.letter(index)) options")
            .accessibilityIdentifier("multiview.options.\(index)")
        }

        private var regularChrome: some View {
            VStack(spacing: 0) {
                HStack(spacing: compact ? 5 : 8) {
                    Text(MultiviewTile.letter(index))
                        .font(MonitorTheme.font(compact ? 9 : 11, weight: .semibold))
                        .frame(width: compact ? 21 : 27, height: compact ? 21 : 27)
                        .background(
                            selected ? MonitorTheme.accent.opacity(0.24) : .black.opacity(0.35),
                            in: RoundedRectangle(cornerRadius: 6)
                        )
                        .foregroundStyle(selected ? MonitorTheme.accent : .white)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tile.name)
                            .font(MonitorTheme.font(compact ? 9 : 12, weight: .semibold))
                        Text(tile.model)
                            .font(MonitorTheme.font(compact ? 6 : 8))
                            .foregroundStyle(.white.opacity(0.7))
                    }.lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                    if !compact, let timecode = tile.timecode {
                        Text(timecode)
                            .font(MonitorTheme.font(11, weight: .medium)).monospacedDigit()
                            .lineLimit(1).fixedSize()
                            .accessibilityLabel("Timecode " + timecode)
                    }
                    optionsButton
                }
                .padding(.leading, compact ? 7 : 11)
                .padding(.trailing, 2)
                Spacer(minLength: 0)
                // Two bottom-aligned columns so the left block ends on the same line as
                // the right block (and the stage's camera-values row).
                HStack(alignment: .bottom, spacing: 6) {
                    VStack(alignment: .leading, spacing: compact ? 2 : 4) {
                        if !compact {
                            Text(tile.format)
                                .font(MonitorTheme.font(9, weight: .semibold)).lineLimit(1)
                        }
                        HStack(spacing: 6) {
                            battery
                            Text(tile.storage)
                        }
                        .font(MonitorTheme.font(compact ? 7.5 : 9, weight: .medium))
                        if compact, let timecode = tile.timecode {
                            Text(timecode).monospacedDigit()
                                .font(MonitorTheme.font(8, weight: .medium))
                                .accessibilityLabel("Timecode " + timecode)
                        }
                    }
                    .layoutPriority(1)
                    .allowsHitTesting(false)
                    if inlineValues {
                        // Inline with both columns; the values take what is left over.
                        HStack(alignment: .bottom, spacing: 4) {
                            ForEach(Array(tile.readouts.enumerated()), id: \.element.title) {
                                inlineValue($1, index: $0)
                            }
                        }
                        .frame(maxWidth: 220)
                        .frame(maxWidth: .infinity)
                    } else {
                        Spacer(minLength: 0)
                    }
                    VStack(alignment: .trailing, spacing: compact ? 2 : 4) {
                        tally
                            .foregroundStyle(tile.recording ? .red : .white)
                            .font(MonitorTheme.font(compact ? 7.5 : 9, weight: .medium))
                        HStack(spacing: 6) {
                            if tile.lut { Text("LUT").foregroundStyle(MonitorTheme.accent) }
                            if let note = tile.tileNote {
                                Text(note).foregroundStyle(.orange).lineLimit(1)
                            } else if selected && !compact {
                                Text("SELECTED").foregroundStyle(MonitorTheme.accent)
                            }
                        }
                        .font(MonitorTheme.font(compact ? 8 : 10, weight: .medium))
                    }
                    .layoutPriority(1)
                    .allowsHitTesting(false)
                }
                .monospacedDigit()
                .padding(.horizontal, compact ? 8 : 11)
                .padding(.leading, reservedLeading)
                .padding(.bottom, compact ? 5 : 9)
            }
            .shadow(color: .black.opacity(0.9), radius: 2, y: 1)
        }

        @ViewBuilder
        private var tally: some View {
            if let since = tile.recordingSince {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(
                        MultiviewTally.running(Int(context.date.timeIntervalSince(since))))
                }
            } else {
                Text(tile.tally)
            }
        }

        /// A value with the camera's advertised choices opens them, as the stage's value row does.
        @ViewBuilder
        private func inlineValue(_ readout: MultiviewReadout, index: Int) -> some View {
            let label = VStack(spacing: 1) {
                Text(readout.value).font(MonitorTheme.font(11, weight: .medium))
                    .lineLimit(1).minimumScaleFactor(0.6)
                Text(readout.title).font(MonitorTheme.font(6, weight: .semibold))
                    .tracking(0.5).foregroundStyle(MonitorTheme.muted).lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            .frame(maxWidth: .infinity)
            if readout.choices.isEmpty {
                label
                    .allowsHitTesting(false)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(readout.title + " " + readout.value)
            } else {
                Menu {
                    ForEach(Array(readout.choices.enumerated()), id: \.offset) { _, name in
                        Button(name) { choose(index, name) }
                    }
                } label: {
                    label
                }
                .accessibilityLabel(readout.title + " " + readout.value)
                .accessibilityIdentifier("multiview.value.\(readout.title.lowercased())")
            }
        }

        /// The camera battery pill without its glyph.
        private var battery: some View {
            MultiviewBatteryPill(
                percent: tile.battery, bars: tile.batteryBars, barCount: tile.batteryBarCount)
        }
    }

    /// One glass pill with the camera's battery percent, or the bars of a coarse gauge, colored by
    /// charge.
    struct MultiviewBatteryPill: View {
        let percent: Int?
        var bars: Int? = nil
        var barCount: Int = 5

        var body: some View {
            let tablet = UIDevice.current.userInterfaceIdiom == .pad
            Group {
                if let bars {
                    MonitorGaugeBars(
                        filled: bars, count: barCount, tint: color)
                } else {
                    Text(percent.map { "\($0)%" } ?? MultiviewTally.unavailable)
                }
            }
                .font(MonitorTheme.font(tablet ? 11 : 10, weight: .semibold)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.7)
                .foregroundStyle(color)
                .padding(.horizontal, 6)
                .frame(width: bars.map { MonitorGaugeBars.readoutWidth(filled: $0, count: barCount,
                    minimum: tablet ? 44 : 40, inset: 12) } ?? (tablet ? 44 : 40),
                    height: tablet ? 22 : 20, alignment: .leading)
                .monitorGlass(in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(
                    bars.map { "Camera battery \($0) of \(barCount) bars" }
                        ?? percent.map { "Camera battery \($0) percent" } ?? "Camera battery unavailable")
        }

        /// Phone and camera batteries share one scale.
        private var color: Color {
            guard let percent = bars.map({ (Double($0) * 100 / Double(max(1, barCount))).rounded(.towardZero) }) ?? percent.map(Double.init) else {
                return MonitorTheme.text
            }
            return percent <= 20
                ? MonitorTheme.recording
                : percent <= 40
                    ? MonitorTheme.edrSRGB(
                        red: 0.914, green: 0.674, blue: 0.208, gain: MonitorTheme.hdrGain)
                    : MonitorTheme.linkHealthColor(.stable)
        }
    }

    /// One camera's details and actions, over the stage.
    struct MultiviewCameraOptions: View {
        let tile: MultiviewTile
        let maximumHeight: CGFloat
        let confirmsRecord: Bool
        let recordContext: () -> MultiviewRecordContext
        let record: (RecordPlan) async -> Void
        let close: () -> Void
        let perform: (MultiviewCameraAction) -> Void

        var body: some View {
            MonitorCapturePanel(
                title: tile.name, subtitle: tile.model, maximumHeight: maximumHeight,
                bottomCornerRadius: 16, edge: .top, close: close
            ) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(tile.format)
                        Spacer()
                        MultiviewBatteryRow(
                            percent: tile.battery, charging: tile.charging, bars: tile.batteryBars,
                            barCount: tile.batteryBarCount)
                        Text(tile.storage)
                    }.font(MonitorTheme.font(11))
                    if let timecode = tile.timecode {
                        Text(timecode).font(MonitorTheme.font(12)).monospacedDigit()
                    }
                    Text(tile.detail).foregroundStyle(MonitorTheme.muted)
                    if let failure = tile.failure { Text(failure).foregroundStyle(.orange) }
                    if let note = tile.note { Text(note) }
                    Divider()
                    ForEach(tile.actions) { action in
                        switch action.kind {
                        case .record:
                            MultiviewRecordAction(
                                confirmationEnabled: confirmsRecord, single: tile.name,
                                context: recordContext, record: record
                            ) {
                                actionLabel(action.title)
                            }
                            .disabled(!action.enabled)
                        case .destructive:
                            Button(role: .destructive) {
                                perform(action)
                            } label: {
                                actionLabel(action.title)
                            }
                            .disabled(!action.enabled)
                        case .action:
                            Button {
                                perform(action)
                            } label: {
                                actionLabel(action.title)
                            }
                            .disabled(!action.enabled)
                        }
                    }
                    if let footnote = tile.footnote {
                        Text(footnote).foregroundStyle(MonitorTheme.muted)
                    }
                }
                .font(MonitorTheme.font(11))
                .buttonStyle(MonitorButtonStyle())
            }
            .tint(MonitorTheme.accent)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("multiview.cameraOptions")
        }

        private func actionLabel(_ title: String) -> some View {
            Text(title).font(MonitorTheme.font(12, weight: .medium))
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .padding(.horizontal, 12)
                .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 9))
                .contentShape(Rectangle())
        }
    }

    /// The camera glyph beside a battery-shaped outline with the number inside.
    struct MultiviewBatteryRow: View {
        let percent: Int?
        let charging: Bool
        var bars: Int? = nil
        var barCount: Int = 5

        var body: some View {
            HStack(spacing: 5) {
                MonitorIcon.camera
                    .foregroundStyle(MonitorTheme.muted)
                    .frame(width: 10, height: 10)
                HStack(spacing: 1) {
                    if charging {
                        MonitorIcon.zap.frame(width: 7, height: 7).foregroundStyle(tint)
                    }
                    Group {
                        if let bars {
                            MonitorGaugeBars(
                                filled: bars, count: barCount, tint: tint,
                                barHeight: 7
                            ).padding(.horizontal, 2)
                        } else {
                            Text(readout)
                        }
                    }
                        .font(.system(size: 10, weight: .medium, design: .default))
                        .monospacedDigit()
                        .foregroundStyle(tint)
                        .lineLimit(1)
                        .minimumScaleFactor(barCount > 10 ? 0.5 : 0.65)
                }
                .frame(width: bars.map { MonitorGaugeBars.readoutWidth(filled: $0, count: barCount,
                    minimum: 26, inset: charging ? 13 : 6) } ?? 26, height: 15)
                .overlay {
                    RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                        .strokeBorder(tint.opacity(0.85), lineWidth: 1.2)
                }
                .overlay(alignment: .trailing) {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(tint.opacity(0.85))
                        .frame(width: 1.6, height: 6)
                        .offset(x: 3)
                }
            }
            .accessibilityLabel("Camera battery")
            .accessibilityValue(bars.map { "\($0) of \(barCount) bars" } ?? readout)
        }

        private var readout: String { percent.map(String.init) ?? MultiviewTally.unavailable }

        /// Three or more of five bars (41 and up) green, two (21 to 40) yellow, one red.
        private var tint: Color {
            guard let percent = bars.map({ (Double($0) * 100 / Double(max(1, barCount))).rounded(.towardZero) }) ?? percent.map(Double.init) else {
                return MonitorTheme.faint
            }
            if percent <= 20 { return .red }
            if percent <= 40 { return .yellow }
            return MonitorTheme.linkHealthColor(.stable)
        }
    }

    /// The long-press options menu a tool offers only when its host supplies a working adapter.
    private struct ToolOptionsMenu: ViewModifier {
        let enabled: Bool
        let action: @MainActor () -> Void

        func body(content: Content) -> some View {
            if enabled {
                content.contextMenu { Button("Configure LUT") { action() } }
            } else {
                content
            }
        }
    }

    /// Record on every camera, or on one (`single`, its name). With confirmation on, the
    /// dialog holds the plan the operator saw; any change to it (`MultiviewRecordContext`)
    /// dismisses the dialog, and the approved plan is checked again before it runs.
    public struct MultiviewRecordAction<Label: View>: View {
        let confirmationEnabled: Bool
        var single: String?
        let context: () -> MultiviewRecordContext
        let record: (RecordPlan) async -> Void
        @ViewBuilder let label: () -> Label
        @Environment(\.multiviewStageVisible) private var stageVisible
        @Environment(\.scenePhase) private var scenePhase
        @State private var approvalRevision = UUID()
        @State private var showingConfirmation = false
        private struct Approval {
            let id = UUID()
            let context: MultiviewRecordContext
        }
        @State private var pending: Approval?

        public init(
            confirmationEnabled: Bool, single: String? = nil,
            context: @escaping () -> MultiviewRecordContext,
            record: @escaping (RecordPlan) async -> Void, @ViewBuilder label: @escaping () -> Label
        ) {
            self.confirmationEnabled = confirmationEnabled
            self.single = single
            self.context = context
            self.record = record
            self.label = label
        }

        public var body: some View {
            // One plan per render for the modifiers; the tap and the confirmation re-read it.
            let now = context()
            return Button {
                let current = context()
                guard stageVisible, current.canConfirm else { return }
                if confirmationEnabled {
                    pending = Approval(context: current)
                    showingConfirmation = true
                } else {
                    perform(current)
                }
            } label: {
                label()
            }
            .disabled(!stageVisible || !now.canConfirm)
            .accessibilityHint(now.refusal ?? "")
            .confirmationDialog(
                now.prompt ?? now.question(single: single != nil), isPresented: $showingConfirmation,
                titleVisibility: .visible
            ) {
                if let approved = pending {
                    Button(now.stopping ? "Stop" : "Start", role: now.stopping ? .destructive : nil) {
                        guard pending?.id == approved.id else { return }
                        pending = nil
                        perform(approved.context)
                    }
                }
                Button("Cancel", role: .cancel) { pending = nil }
            } message: {
                Text(single ?? MultiviewRecordContext.groupNote)
            }
            .onChange(of: now) { _, _ in retireApproval() }
            .onChange(of: stageVisible) { _, visible in if !visible { retireApproval() } }
            .onChange(of: scenePhase) { _, phase in if phase != .active { retireApproval() } }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
                retireApproval()
            }
            .onDisappear { retireApproval() }
        }

        private func retireApproval() {
            approvalRevision = UUID()
            pending = nil
            showingConfirmation = false
        }

        private func perform(_ approved: MultiviewRecordContext) {
            let revision = approvalRevision
            Task { @MainActor in
                let current = context()
                guard stageVisible, approvalRevision == revision,
                    approved == current, current.canConfirm else { return }
                await record(approved.plan)
            }
        }
    }

    /// Add camera: one row per camera the app offers. The ones that cannot join say why.
    public struct MultiviewCameraPicker: View {
        let rows: [MultiviewPickerRow]
        let searching: String
        let empty: String?
        let footer: String?
        let cancel: () -> Void
        let pick: (String) -> Void

        /// - Parameters:
        ///   - searching: shown with a spinner while `rows` is empty and `empty` is `nil`.
        ///   - empty: shown instead when nothing more will appear.
        public init(
            rows: [MultiviewPickerRow], searching: String = "Looking for nearby cameras…",
            empty: String? = nil, footer: String? = nil, cancel: @escaping () -> Void,
            pick: @escaping (String) -> Void
        ) {
            self.rows = rows
            self.searching = searching
            self.empty = empty
            self.footer = footer
            self.cancel = cancel
            self.pick = pick
        }

        public var body: some View {
            GeometryReader { geometry in
                ZStack {
                    Color.black.opacity(0.55).ignoresSafeArea()
                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            Text("Add camera").font(MonitorTheme.font(20, weight: .semibold))
                            Spacer()
                            Button("Cancel", action: cancel)
                                .frame(minWidth: 64, minHeight: 44)
                                .contentShape(Rectangle())
                        }.padding(.horizontal, 20).padding(.top, 8)
                        ScrollView {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(rows) { row in
                                    Button {
                                        pick(row.id)
                                    } label: {
                                        HStack {
                                            VStack(alignment: .leading, spacing: 3) {
                                                Text(row.title).lineLimit(2)
                                                if let detail = row.detail {
                                                    Text(detail)
                                                        .font(MonitorTheme.font(12))
                                                        .foregroundStyle(MonitorTheme.muted)
                                                }
                                            }
                                            Spacer()
                                            (row.limited ? MonitorIcon.info : MonitorIcon.plus)
                                                .frame(width: 20, height: 20)
                                        }
                                        .padding(.horizontal, 16).frame(minHeight: 52)
                                        .background(
                                            MonitorTheme.raised,
                                            in: RoundedRectangle(cornerRadius: MonitorTheme.radius)
                                        )
                                        .contentShape(Rectangle())
                                    }
                                    .disabled(!row.enabled)
                                    .opacity(row.enabled ? 1 : 0.5)
                                }
                                if rows.isEmpty {
                                    HStack(spacing: 12) {
                                        if empty == nil { ProgressView() }
                                        Text(empty ?? searching)
                                    }.frame(minHeight: 52)
                                }
                                if let footer {
                                    Text(footer)
                                        .font(MonitorTheme.font(13))
                                        .foregroundStyle(MonitorTheme.muted)
                                        .padding(.top, 4)
                                }
                            }.padding(.horizontal, 20).padding(.bottom, 20)
                        }
                        .monitorScrollFade()
                    }
                    .frame(
                        width: min(460, max(0, geometry.size.width - 32)),
                        height: min(
                            CGFloat(max(1, min(4, rows.count))) * 60 + 140,
                            max(0, geometry.size.height - 24))
                    )
                    .monitorGlass(in: RoundedRectangle(cornerRadius: MonitorTheme.radius))
                    .environment(\.colorScheme, .dark)
                    .shadow(radius: 24)
                    .accessibilityIdentifier("multiview.cameraPicker")
                }
            }
            .font(MonitorTheme.font(16)).foregroundStyle(MonitorTheme.text)
            .tint(MonitorTheme.accent).buttonStyle(MultiviewPressStyle())
        }
    }

    /// Press feedback for the record lamp and the picker rows.
    struct MultiviewPressStyle: ButtonStyle {
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .opacity(configuration.isPressed ? 0.6 : 1)
                .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
                .animation(
                    reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
        }
    }
#endif
