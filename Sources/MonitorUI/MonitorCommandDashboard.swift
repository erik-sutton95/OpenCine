#if os(iOS)
    import MonitorPresentation
    import SwiftUI

    /// The command dashboard, SwiftUI twin of the Compose `MonitorCommandDashboard`: a reorderable
    /// grid of `tiles` and the `sections` column; landscape adds the `health` strip ending in
    /// `healthTrailing`. `hero`, the header's status presentation, heads it with the record chip and
    /// hero timecode. Landscape stacks
    /// hero, health and grid on the left beside a full-height side column; portrait pins the hero
    /// over the compact grid and the sections in one scroller. Type is the live surface's: readout
    /// labels and Sora tabular values (`MonitorReadoutTypography`).
    /// `pending` is true while any write is in flight and `applying` names the request it carries.
    /// Long press and drag reorders a tile with a `kind` through `onMoveTile` (kind, target slot);
    /// a tap opens its request. `sideColumnWidth` is the landscape column width (default: its share
    /// of the dashboard width, `MonitorCommandGridLayout.sideColumnWidth`).
    public struct MonitorCommandDashboard<Kind: Hashable, Request, HealthTrailing: View>: View {
        private let tiles: [MonitorCommandTile<Kind, Request>]
        private let sections: [MonitorCommandSection<Kind, Request>]
        private let health: MonitorCommandHealth
        private let portrait: Bool
        private let controls: CommandControls<Kind, Request>
        private let sideColumnWidth: CGFloat?
        private let hero: MonitorStatusPresentation?
        private let healthTrailing: HealthTrailing

        public init(
            tiles: [MonitorCommandTile<Kind, Request>], sections: [MonitorCommandSection<Kind, Request>],
            health: MonitorCommandHealth, hero: MonitorStatusPresentation? = nil, portrait: Bool, controlsEnabled: Bool,
            pending: Bool = false,
            applying: @escaping (Request) -> Bool = { _ in false }, sideColumnWidth: CGFloat? = nil,
            onOpenControl: @escaping (Request) -> Void, onMoveTile: @escaping (Kind, Int) -> Void,
            @ViewBuilder healthTrailing: () -> HealthTrailing
        ) {
            self.tiles = tiles
            self.sections = sections
            self.health = health
            self.hero = hero
            self.portrait = portrait
            controls = CommandControls(
                enabled: controlsEnabled, pending: pending, applying: applying, open: onOpenControl,
                move: onMoveTile)
            self.sideColumnWidth = sideColumnWidth
            self.healthTrailing = healthTrailing()
        }

        public var body: some View {
            if portrait {
                VStack(spacing: MonitorCommandGridLayout.stackSpacing) {
                    if let hero { CommandHeroBand(hero: hero, portrait: true) }
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 12) {
                            MonitorCommandGrid(tiles: tiles, controls: controls)
                                .frame(height: MonitorCommandGridLayout.portraitGridHeight(tileCount: tiles.count))
                            CommandSections(sections: sections, controls: controls, compact: false)
                        }
                    }
                }
            } else {
                GeometryReader { proxy in
                    // The baseline `.cmd-body` split: hero, health and grid on the left; the side
                    // column runs the full height beside them.
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: MonitorCommandGridLayout.stackSpacing) {
                            if let hero { CommandHeroBand(hero: hero, portrait: false) }
                            CommandHealthStrip(health: health, trailing: healthTrailing)
                            MonitorCommandGrid(tiles: tiles, controls: controls)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        CommandSideColumn(sections: sections, controls: controls)
                            .frame(
                                width: sideColumnWidth
                                    ?? MonitorCommandGridLayout.sideColumnWidth(pictureWidth: proxy.size.width))
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height)
                }
            }
        }
    }

    /// The host's write state and callbacks, shared by every tile of one dashboard.
    struct CommandControls<Kind: Hashable, Request> {
        let enabled: Bool
        let pending: Bool
        let applying: (Request) -> Bool
        let open: (Request) -> Void
        let move: (Kind, Int) -> Void

        func isApplying(_ tile: MonitorCommandTile<Kind, Request>) -> Bool {
            tile.request.map(applying) ?? false
        }

        /// The request a tap opens now; nil for a read-only tile or locked controls.
        func openable(_ tile: MonitorCommandTile<Kind, Request>) -> Request? {
            enabled ? tile.request : nil
        }

        func hint(_ tile: MonitorCommandTile<Kind, Request>, reorderable: Bool) -> String {
            tile.accessibilityHint(
                controlsEnabled: enabled, pending: pending, applying: isApplying(tile), reorderable: reorderable)
        }
    }

    /// The three-column primary grid (Compose `MonitorCommandGrid`): a tap opens a tile's request,
    /// a long press lifts a tile with a kind and dragging reorders it. Tiles are absolutely
    /// positioned so the held tile follows the finger while the others spring to their new slots.
    public struct MonitorCommandGrid<Kind: Hashable, Request>: View {
        private let tiles: [MonitorCommandTile<Kind, Request>]
        private let controls: CommandControls<Kind, Request>
        @State private var drag = MonitorCommandGridDrag<Kind>()
        @GestureState private var holding = false

        /// Spring used for both the live shuffle and the drop.
        private let shuffle = Animation.spring(response: 0.3, dampingFraction: 0.72)
        private let space = "monitor.command.grid"

        public init(
            tiles: [MonitorCommandTile<Kind, Request>], controlsEnabled: Bool, pending: Bool = false,
            applying: @escaping (Request) -> Bool = { _ in false },
            onOpenControl: @escaping (Request) -> Void, onMoveTile: @escaping (Kind, Int) -> Void
        ) {
            self.init(
                tiles: tiles,
                controls: CommandControls(
                    enabled: controlsEnabled, pending: pending, applying: applying, open: onOpenControl,
                    move: onMoveTile))
        }

        init(tiles: [MonitorCommandTile<Kind, Request>], controls: CommandControls<Kind, Request>) {
            self.tiles = tiles
            self.controls = controls
        }

        public var body: some View {
            GeometryReader { proxy in
                let columns = MonitorCommandGridLayout.columns
                let spacing = MonitorCommandGridLayout.spacing
                let rows = MonitorCommandGridLayout.rows(tileCount: tiles.count)
                let rowHeight = MonitorCommandGridLayout.rowHeight(height: proxy.size.height, rows: rows)
                let tileWidth = max(1, (proxy.size.width - spacing * CGFloat(columns - 1)) / CGFloat(columns))
                let cell = MonitorCommandGridCell(
                    tileWidth: tileWidth, rowHeight: rowHeight, spacing: spacing, columns: columns)
                ZStack(alignment: .topLeading) {
                    ForEach(CommandGridItem.items(tiles)) { item in
                        let index = item.index, tile = item.tile
                        let held = tile.kind != nil && drag.kind == tile.kind
                        CommandTile(title: tile.title, value: tile.value, height: rowHeight)
                            .frame(width: tileWidth)
                            .modifier(
                                CommandTileAccessibility(
                                    tile: tile, index: index, count: tiles.count, controls: controls))
                            .scaleEffect(held ? 1.06 : 1)
                            .shadow(color: .black.opacity(held ? 0.5 : 0), radius: 16, y: 8)
                            .zIndex(held ? 1 : 0)
                            .position(
                                held
                                    ? MonitorCommandGridLayout.dragCenter(
                                        drag.location, tileWidth: tileWidth, rowHeight: rowHeight, in: proxy.size)
                                    : MonitorCommandGridLayout.tileCenter(
                                        index: index, tileWidth: tileWidth, rowHeight: rowHeight,
                                        spacing: spacing, columns: columns))
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
                .contentShape(Rectangle())
                .coordinateSpace(.named(space))
                // The tap MUST be simultaneous: `.onTapGesture` and `.exclusively(before:)` are
                // subordinate to the reorder gesture, whose long press swallows the touch. The
                // reorder stays on the stable container so it survives every shuffle.
                .simultaneousGesture(
                    SpatialTapGesture(coordinateSpace: .named(space)).onEnded { tap($0.location, cell) })
                .gesture(reorder(cell))
                .onChange(of: holding) { _, held in
                    // A cancelled sequence never reaches `onEnded`; the gesture state still resets.
                    if !held, drag.kind != nil { drop() }
                }
            }
        }

        private func tap(_ location: CGPoint, _ cell: MonitorCommandGridCell) {
            guard drag.admitsTap(at: ProcessInfo.processInfo.systemUptime), !tiles.isEmpty,
                let index = MonitorCommandGridLayout.hitSlot(
                    at: location, tileWidth: cell.tileWidth, rowHeight: cell.rowHeight,
                    spacing: cell.spacing, columns: cell.columns, itemCount: tiles.count),
                let request = controls.openable(tiles[index])
            else { return }
            controls.open(request)
        }

        private func reorder(_ cell: MonitorCommandGridCell) -> some Gesture {
            LongPressGesture(minimumDuration: MonitorCommandGridLayout.reorderPressDuration)
                .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named(space)))
                .updating($holding) { value, state, _ in
                    if case .second(true, _) = value { state = true }
                }
                .onChanged { value in
                    guard case .second(true, let finger?) = value else { return }
                    let kinds = tiles.map(\.kind)
                    if drag.kind == nil, !drag.begin(at: finger.startLocation, kinds: kinds, cell: cell) {
                        return
                    }
                    if let target = drag.move(to: finger.location, kinds: kinds, cell: cell),
                        let kind = drag.kind
                    {
                        withAnimation(shuffle) { controls.move(kind, target) }
                    }
                }
                .onEnded { _ in drop() }
        }

        private func drop() {
            withAnimation(shuffle) { drag.end(at: ProcessInfo.processInfo.systemUptime) }
        }
    }

    /// One grid tile and its slot. A reorderable tile's identity follows its kind, so it springs
    /// to a new slot; a fixed one is its title in its place (the Compose `key`).
    private struct CommandGridItem<Kind: Hashable, Request>: Identifiable {
        enum ID: Hashable {
            case kind(Kind)
            case fixed(String, Int)
        }

        let index: Int
        let tile: MonitorCommandTile<Kind, Request>
        var id: ID { tile.kind.map { .kind($0) } ?? .fixed(tile.title, index) }

        static func items(_ tiles: [MonitorCommandTile<Kind, Request>]) -> [Self] {
            tiles.enumerated().map { Self(index: $0.offset, tile: $0.element) }
        }
    }

    /// What VoiceOver and XCUITest reach on a grid tile: title, value, what a tap and a long press
    /// do, the open action and the Compose tile's "Move earlier" and "Move later" actions.
    private struct CommandTileAccessibility<Kind: Hashable, Request>: ViewModifier {
        let tile: MonitorCommandTile<Kind, Request>
        let index: Int
        let count: Int
        let controls: CommandControls<Kind, Request>

        func body(content: Content) -> some View {
            let request = controls.openable(tile)
            let open: (() -> Void)? = request.map { request in { controls.open(request) } }
            content
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(tile.title)
                .accessibilityValue(tile.value)
                .accessibilityHint(controls.hint(tile, reorderable: true))
                .accessibilityIdentifier(
                    "monitor.command.tile." + (tile.kind.map { String(describing: $0) } ?? String(index)))
                .accessibilityAddTraits(request != nil ? .isButton : [])
                .modifier(OptionalAction(name: nil, perform: open))
                // SwiftUI lists the outermost named action first: "earlier" before "later".
                .modifier(
                    OptionalAction(
                        name: "Move \(tile.title) later", perform: move(to: index + 1, when: index < count - 1)))
                .modifier(
                    OptionalAction(
                        name: "Move \(tile.title) earlier", perform: move(to: index - 1, when: index > 0)))
        }

        private func move(to target: Int, when allowed: Bool) -> (() -> Void)? {
            guard allowed, let kind = tile.kind else { return nil }
            return { controls.move(kind, target) }
        }
    }

    /// Adds the default (nil `name`) or a named accessibility action only when there is one.
    private struct OptionalAction: ViewModifier {
        let name: String?
        let perform: (() -> Void)?

        @ViewBuilder func body(content: Content) -> some View {
            if let perform, let name {
                content.accessibilityAction(named: Text(name), perform)
            } else if let perform {
                content.accessibilityAction(.default, perform)
            } else {
                content
            }
        }
    }

    /// One primary grid value. Presentational: the grid owns the tap and the reorder on one
    /// container gesture, so a reorder never also fires a tap.
    private struct CommandTile: View {
        let title: String
        let value: String
        let height: CGFloat

        var body: some View {
            VStack(alignment: .leading, spacing: 4) {
                CommandLabel(text: title, color: MonitorTheme.muted, minimumScale: 0.64)
                Spacer(minLength: 0)
                Text(value)
                    .font(MonitorTheme.font(MonitorCommandGridLayout.valueFontSize(rowHeight: height), weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(MonitorTheme.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.46)
            }
            // Pad first, then clamp to `height`, so the tile is exactly `height` tall.
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .leading)
            .background(MonitorTheme.surface, in: RoundedRectangle(cornerRadius: MonitorCommandGridLayout.cornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: MonitorCommandGridLayout.cornerRadius)
                    .strokeBorder(MonitorTheme.border, lineWidth: 1)
            }
        }
    }

    /// Temp, Storage, Camera and Lens readouts and the host's trailing chip.
    private struct CommandHealthStrip<Trailing: View>: View {
        let health: MonitorCommandHealth
        let trailing: Trailing

        var body: some View {
            HStack(spacing: 10) {
                CommandStatusBlock(
                    label: "Temp", value: health.temperature,
                    color: health.temperatureOk ? MonitorTheme.linkHealthColor(.stable) : MonitorTheme.text)
                CommandStatusBlock(label: "Storage", value: health.storage)
                CommandStatusBlock(label: "Camera", value: health.camera)
                CommandStatusBlock(label: "Lens", value: health.lens)
                Spacer(minLength: 4)
                // The trailing chip keeps its natural size; the status blocks scale down first.
                trailing
                    .fixedSize()
                    .layoutPriority(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(MonitorTheme.surface, in: RoundedRectangle(cornerRadius: MonitorCommandGridLayout.cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: MonitorCommandGridLayout.cornerRadius)
                    .strokeBorder(MonitorTheme.border, lineWidth: 1))
        }
    }

    private struct CommandStatusBlock: View {
        let label: String
        let value: String
        var color: Color = MonitorTheme.text

        var body: some View {
            VStack(alignment: .leading, spacing: 2) {
                CommandLabel(text: label, color: MonitorTheme.muted, minimumScale: 0.8)
                Text(value)
                    .font(MonitorTheme.font(12, weight: .medium)).monospacedDigit()
                    .foregroundStyle(color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.55)
            }
            .frame(minWidth: 52, maxWidth: 148, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityValue(value)
        }
    }

    /// The landscape side column: the sections in a scroller whose fade and "More" hint clear once
    /// it is scrolled to (or fits within) the bottom.
    private struct CommandSideColumn<Kind: Hashable, Request>: View {
        let sections: [MonitorCommandSection<Kind, Request>]
        let controls: CommandControls<Kind, Request>
        @State private var contentBottom: CGFloat = .infinity

        var body: some View {
            GeometryReader { outer in
                scroller(viewportHeight: outer.size.height)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(MonitorCommandGridLayout.sideDescription(sections.map(\.title)))
            .accessibilityIdentifier("monitor.command.side")
        }

        private func scroller(viewportHeight: CGFloat) -> some View {
            let atBottom = contentBottom <= viewportHeight + 2
            return ScrollView(.vertical, showsIndicators: false) {
                CommandSections(sections: sections, controls: controls, compact: true)
                    .padding(.bottom, 20)
                    // Read the mounted content directly. A preference crossing this masked
                    // ScrollView can resolve to its default, which falsely reports the end.
                    .onGeometryChange(for: CGFloat.self) {
                        $0.frame(in: .named("cmdSideScroll")).maxY
                    } action: {
                        contentBottom = $0
                    }
            }
            .coordinateSpace(.named("cmdSideScroll"))
            .mask {
                if atBottom {
                    Rectangle()
                } else {
                    LinearGradient(
                        stops: [
                            .init(color: .black, location: 0), .init(color: .black, location: 0.9),
                            .init(color: .clear, location: 1),
                        ], startPoint: .top, endPoint: .bottom)
                }
            }
            .overlay(alignment: .bottom) {
                if !atBottom {
                    Text("MORE ⌄")
                        .font(MonitorTheme.font(CGFloat(MonitorReadoutTypography.labelSize), weight: .semibold))
                        .foregroundStyle(MonitorTheme.muted)
                        .tracking(CGFloat(MonitorReadoutTypography.labelTracking))
                        .frame(maxWidth: .infinity)
                        .padding(.bottom, 2)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                        .accessibilityLabel("More command controls below. Swipe up to reveal them.")
                        .accessibilityIdentifier("monitor.command.more")
                }
            }
            .animation(.easeInOut(duration: 0.15), value: atBottom)
        }
    }

    /// The section stack, shared by the side column (`compact`) and portrait.
    private struct CommandSections<Kind: Hashable, Request>: View {
        let sections: [MonitorCommandSection<Kind, Request>]
        let controls: CommandControls<Kind, Request>
        let compact: Bool

        var body: some View {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                    VStack(alignment: .leading, spacing: 4) {
                        CommandLabel(text: section.title, color: MonitorTheme.faint, minimumScale: 0.8)
                            .padding(.leading, 2)
                        // Pairs; a leftover cell spans the row (the prototype's `.span2`).
                        VStack(spacing: 5) {
                            ForEach(Array(stride(from: 0, to: section.cells.count, by: 2)), id: \.self) { start in
                                HStack(spacing: 6) {
                                    ForEach(start..<min(start + 2, section.cells.count), id: \.self) { index in
                                        CommandSmallTile(cell: section.cells[index], controls: controls, compact: compact)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private struct CommandSmallTile<Kind: Hashable, Request>: View {
        let cell: MonitorCommandTile<Kind, Request>
        let controls: CommandControls<Kind, Request>
        let compact: Bool

        private var valueColor: Color {
            if cell.amber { return MonitorTheme.accent }
            if cell.muted { return MonitorTheme.faint }
            return MonitorTheme.text
        }

        var body: some View {
            let request = controls.openable(cell)
            Button {
                if let request { controls.open(request) }
            } label: {
                VStack(alignment: .leading, spacing: 5) {
                    CommandLabel(text: cell.title, color: MonitorTheme.muted, minimumScale: 0.66)
                    Text(cell.value)
                        .font(MonitorTheme.font(15, weight: .medium)).monospacedDigit()
                        .foregroundStyle(valueColor)
                        .lineLimit(1)
                        .minimumScaleFactor(0.55)
                }
                .frame(
                    maxWidth: .infinity,
                    minHeight: compact
                        ? MonitorCommandGridLayout.sideTileMinHeight : MonitorCommandGridLayout.portraitSideTileHeight,
                    alignment: .leading
                )
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    MonitorTheme.surface, in: RoundedRectangle(cornerRadius: MonitorCommandGridLayout.cornerRadius)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: MonitorCommandGridLayout.cornerRadius)
                        .strokeBorder(MonitorTheme.border, lineWidth: 1))
            }
            .buttonStyle(.monitorTapTarget)
            .disabled(request == nil)
            .accessibilityLabel(cell.title)
            .accessibilityValue(cell.value)
            .accessibilityHint(controls.hint(cell, reorderable: false))
        }
    }

    /// The live surface's readout caption (`MonitorReadout` label): uppercase Sora semibold at the
    /// shared label size and tracking.
    private struct CommandLabel: View {
        let text: String
        let color: Color
        let minimumScale: CGFloat

        var body: some View {
            Text(text.uppercased())
                .font(MonitorTheme.font(CGFloat(MonitorReadoutTypography.labelSize), weight: .semibold))
                .tracking(CGFloat(MonitorReadoutTypography.labelTracking))
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(minimumScale)
        }
    }

    /// The hero band: the record chip, then the hero timecode with its frame field in the accent.
    /// The timecode is omitted when the body runs none.
    private struct CommandHeroBand: View {
        let hero: MonitorStatusPresentation
        let portrait: Bool

        var body: some View {
            HStack(spacing: 11) {
                CommandRecordChip(hero: hero)
                if let parts = hero.commandHeroTimecode {
                    (Text(parts.seconds).foregroundStyle(MonitorTheme.text)
                        + Text(parts.frames).foregroundStyle(MonitorTheme.accent))
                        .font(MonitorTheme.font(MonitorCommandGridLayout.heroTimecodeSize(portrait: portrait), weight: .medium))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(MonitorCommandGridLayout.heroMinimumScale)
                }
                Spacer(minLength: 0)
            }
            .frame(height: MonitorCommandGridLayout.heroHeight(portrait: portrait))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Timecode")
            .accessibilityValue(hero.commandHeroAccessibilityValue)
            .accessibilityIdentifier("monitor.command.hero")
        }
    }

    /// The header's record word: REC in the recording red with its lamp, STBY muted, unknown a
    /// dash (never standby).
    private struct CommandRecordChip: View {
        let hero: MonitorStatusPresentation

        var body: some View {
            let recording = hero.recording == true
            HStack(spacing: 6) {
                if recording {
                    Circle().fill(MonitorTheme.recording).frame(width: 8, height: 8)
                        .monitorPulse(period: MonitorMotion.recPulseDuration)
                } else {
                    Circle().fill(MonitorTheme.faint).frame(width: 8, height: 8)
                        .opacity(hero.recording == nil ? 0.5 : 1)
                }
                Text(hero.recordingLabel)
                    .font(MonitorTheme.font(11, weight: .semibold))
                    .tracking(CGFloat(MonitorReadoutTypography.labelTracking))
                    .foregroundStyle(recording ? MonitorTheme.recording : MonitorTheme.muted)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(MonitorTheme.surface, in: Capsule())
            .overlay(Capsule().strokeBorder(recording ? MonitorTheme.recording.opacity(0.6) : MonitorTheme.border, lineWidth: 1))
            .fixedSize()
        }
    }
#endif
