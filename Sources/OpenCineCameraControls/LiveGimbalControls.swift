#if os(iOS)
    import MonitorPresentation
    import MonitorUI
    import OpenCineCameraVocabulary
    import OpenCineMotion
    import SwiftUI

    /// What the gimbal sheet and the motion control panel (programmed moves) read and drive. Each
    /// app adapts its model and camera session; differences between apps live in the adapter, never
    /// here.
    @MainActor
    public protocol GimbalPanelHost: AnyObject, Observable {
        var hapticsEnabled: Bool { get }
        var isEditingChrome: Bool { get }
        var liveChromeInteractive: Bool { get }
        /// The camera's own names for the gimbal modes.
        var cameraLabelProfile: CameraLabelProfile { get }
        var liveGimbalPanel: LiveGimbalPanel { get set }
        var gimbalFloatCenter: CGPoint? { get set }
        var assistMirrorsHorizontally: Bool { get }
        /// An edit applies only under the camera and connection phase it started with.
        var connectedCameraID: UUID? { get }
        var connectionPhaseLabel: String { get }
        var gimbalProgram: GimbalProgram { get }
        var overlayGimbalWaypoint: GimbalWaypoint? { get }
        /// Horizontal field of view the waypoint marks project through.
        var waypointOverlayHFovDeg: Double { get }
        var gimbalPoseInvertPan: Bool { get }
        var programmedZoomUnavailableReason: String? { get }
        var canSetGimbalConfiguration: Bool { get }
        var canRunProgrammedMove: Bool { get }
        var gimbalMoveRunning: Bool { get }
        var gimbalMovePaused: Bool { get }
        var gimbalMoveCanPause: Bool { get }
        var gimbalStartCountdown: Int? { get }
        var gimbalMode: GimbalMode { get }
        var gimbalSpeed: GimbalSpeed { get }
        var gimbalRamp: GimbalRamp { get set }
        var gimbalDoubleTap: GimbalDoubleTap { get set }
        func setGimbalMode(_ mode: GimbalMode)
        func setGimbalSpeed(_ speed: GimbalSpeed)
        func setGimbalWaypoint(_ slot: GimbalWaypointSlot)
        func clearGimbalWaypoint(_ slot: GimbalWaypointSlot)
        func setGimbalLegDuration(ab: TimeInterval?, bc: TimeInterval?)
        func setGimbalSmoothness(_ value: Double)
        func setGimbalLoop(_ enabled: Bool)
        func runProgrammedMove()
        func pauseOrResumeProgrammedMove()
        func restartProgrammedMove()
        func clearGimbalProgram()
    }

    /// The live chrome's round close button.
    public struct LiveCloseButton<Palette: LiveChromePalette>: View {
        var action: () -> Void
        var size: CGFloat = 34

        public init(action: @escaping () -> Void, size: CGFloat = 34) {
            self.action = action
            self.size = size
        }

        public var body: some View {
            Button(action: action) {
                MonitorIcon.x
                    .frame(width: size * 0.38, height: size * 0.38)
                    .foregroundStyle(Palette.text)
                    .frame(width: size, height: size)
                    .glassCircle(interactive: true)
            }
            .buttonStyle(.monitorTapTarget)
            .accessibilityLabel("Close")
        }
    }

    /// Only interaction eligibility belongs in the environment. Capturing the
    /// floating modifier also captures its changing placement and rebuilds controls
    /// at pointer cadence, even though their values have not changed.
    public struct MotionControlInteraction: Equatable, Sendable {
        public var isDragging = false
        public var blockedUntil: TimeInterval = 0

        public init(isDragging: Bool = false, blockedUntil: TimeInterval = 0) {
            self.isDragging = isDragging
            self.blockedUntil = blockedUntil
        }

        public func allowsInteraction(at uptime: TimeInterval) -> Bool {
            !isDragging && uptime >= blockedUntil
        }

        public func callAsFunction() -> Bool {
            allowsInteraction(at: ProcessInfo.processInfo.systemUptime)
        }
    }

    private struct MotionControlInteractionKey: EnvironmentKey {
        static let defaultValue = MotionControlInteraction()
    }

    extension EnvironmentValues {
        public var motionControlCanInteract: MotionControlInteraction {
            get { self[MotionControlInteractionKey.self] }
            set { self[MotionControlInteractionKey.self] = newValue }
        }
    }

    public enum LiveGimbalPanel: Equatable {
        case none
        case sheet
        case editor
        case runPill
    }

    public enum LiveGimbalCopy {
        public static let title = "Gimbal"
        public static let mode = "Mode"
        public static let speed = "Speed"
        public static let ramp = "Ramp"
        public static let programmedMove = "Motion Control"
        public static let runMove = "Start"
        public static let stopMove = "Stop"
        public static let set = "Set"
        public static let update = "Update"
        public static let clear = "Clear"
        public static let accessibilityButton = "Gimbal controls"
        public static let accessibilityHint = "Opens follow, speed, ramp, and motion control"
        public static let holdDuration: TimeInterval = 0.3
        public static let dragSlop: CGFloat = 8
    }

    public struct LiveGimbalButton<Host: GimbalPanelHost, Palette: LiveChromePalette>: View {
        @Environment(Host.self) private var model
        @Environment(\.interfaceLocked) private var interfaceLocked

        public init() {}

        public var body: some View {
            Button {
                guard !interfaceLocked else { return }
                switch model.liveGimbalPanel {
                case .none:
                    model.liveGimbalPanel = .sheet
                case .sheet:
                    model.liveGimbalPanel = .none
                case .editor, .runPill:
                    model.liveGimbalPanel = .sheet
                }
            } label: {
                MonitorIcon.crosshair
                    .frame(width: 18, height: 18)
                    .foregroundStyle(Palette.text)
                    .frame(
                        width: LiveChromeMetrics.zoomButtonSize,
                        height: LiveChromeMetrics.zoomButtonSize
                    )
                    .monitorReadoutShadow()
            }
            .buttonStyle(.monitorTapTarget)
            .opacity(interfaceLocked ? 0.4 : 1)
            .allowsHitTesting(!interfaceLocked)
            .disabled(interfaceLocked)
            .accessibilityLabel(LiveGimbalCopy.accessibilityButton)
            .accessibilityHint(LiveGimbalCopy.accessibilityHint)
            .accessibilityIdentifier("monitor.system.gimbalControls")
        }
    }

    public struct LiveGimbalOverlay<Host: GimbalPanelHost, Palette: LiveChromePalette>: View {
        @Environment(Host.self) private var model
        var layout: LiveMonitorLayout
        var feed: CGRect
        var joystickBounds: CGRect = .zero
        var zoomBounds: CGRect = .zero
        var coveredByZoom = false

        public init(
            layout: LiveMonitorLayout, feed: CGRect, joystickBounds: CGRect = .zero,
            zoomBounds: CGRect = .zero,
            coveredByZoom: Bool = false
        ) {
            self.layout = layout
            self.feed = feed
            self.joystickBounds = joystickBounds
            self.zoomBounds = zoomBounds
            self.coveredByZoom = coveredByZoom
        }

        private var bounds: CGRect {
            CGRect(
                x: max(8, layout.safeArea.leading),
                y: max(8, layout.safeArea.top),
                width: max(
                    1,
                    layout.viewport.width - max(8, layout.safeArea.leading)
                        - max(
                            8, layout.safeArea.trailing)),
                height: max(
                    1,
                    layout.viewport.height - max(8, layout.safeArea.top)
                        - max(
                            8, layout.safeArea.bottom))
            )
        }

        private var defaultEditorBounds: CGRect {
            guard layout.viewport.height > layout.viewport.width else {
                return bounds
            }
            let top = max(bounds.minY, 44)
            let bottom = zoomBounds.isEmpty ? bounds.maxY : min(bounds.maxY, zoomBounds.minY - 8)
            return CGRect(
                x: bounds.minX, y: top, width: bounds.width,
                height: max(1, bottom - top))
        }

        /// Only the unset position avoids the zoom chip. Dragging still uses the
        /// whole viewport, and the compact pill keeps the editor's default top edge.
        private var defaultTop: CGFloat {
            let height = min(defaultEditorBounds.height, 420)
            let center = MonitorMotionPlacement.center(
                preferred: nil,
                size: .init(width: Double(Self.editorWidth), height: Double(height)),
                viewport: .init(
                    width: Double(layout.viewport.width), height: Double(layout.viewport.height)),
                bounds: .init(
                    x: defaultEditorBounds.minX, y: defaultEditorBounds.minY,
                    width: defaultEditorBounds.width, height: defaultEditorBounds.height))
            return CGFloat(center.y) - height / 2
        }

        private var editorMaximumHeight: CGFloat {
            // Keep the card's height stable through a first drag and its commit.
            defaultEditorBounds.height
        }

        public var body: some View {
            ZStack(alignment: .topLeading) {
                if model.liveGimbalPanel == .editor || model.liveGimbalPanel == .runPill
                    || model.gimbalMoveRunning
                {
                    LiveGimbalWaypointMarks<Host, Palette>(feed: feed)
                        .zIndex(0)
                }
                if model.liveGimbalPanel == .editor {
                    MonitorMotionDismissBackdrop(excluding: [joystickBounds, zoomBounds]) {
                        model.liveGimbalPanel = .runPill
                    }
                    .accessibilityLabel("Minimize motion control")
                    .accessibilityIdentifier("motion.minimizeBackdrop")
                    // The card's explicit Minimize button serves VoiceOver. An
                    // accessible full-screen backdrop masks the controls in its holes.
                    .accessibilityHidden(true)
                    .zIndex(0.5)

                    LiveGimbalMoveEditor<Host, Palette>(maximumHeight: editorMaximumHeight)
                        .frame(width: Self.editorWidth)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityElement(children: .contain)
                        .accessibilityHidden(coveredByZoom)
                        .modifier(
                            LiveGimbalFloatMove(
                                stored: Bindable(model).gimbalFloatCenter,
                                sizeHint: CGSize(
                                    width: Self.editorWidth, height: min(editorMaximumHeight, 420)),
                                bounds: bounds,
                                viewport: layout.viewport,
                                defaultTop: defaultTop
                            )
                        )
                        .zIndex(1)
                }

                if model.liveGimbalPanel == .runPill {
                    LiveGimbalRunPill<Host, Palette>()
                        .fixedSize()
                        .modifier(
                            LiveGimbalFloatMove(
                                stored: Bindable(model).gimbalFloatCenter,
                                sizeHint: CGSize(width: 172, height: 44),
                                bounds: bounds,
                                viewport: layout.viewport,
                                defaultTop: defaultTop,
                                immediateDrag: true
                            )
                        )
                        .zIndex(1)
                }
            }
            .frame(
                width: layout.viewport.width, height: layout.viewport.height, alignment: .topLeading
            )
            .allowsHitTesting(model.liveGimbalPanel == .editor || model.liveGimbalPanel == .runPill)
        }

        // A generic type holds no stored statics.
        private static var editorWidth: CGFloat { 340 }

    }

    /// Direct drag like movable scopes. The pill uses a high-priority drag so the
    /// compact chrome follows the finger; the editor uses a regular drag so
    /// waypoint buttons, duration dials and the smoothness slider keep theirs.
    public struct LiveGimbalFloatMove: ViewModifier {
        @Binding var stored: CGPoint?
        var sizeHint: CGSize
        var bounds: CGRect
        var viewport: CGSize
        var defaultTop: CGFloat? = nil
        var immediateDrag = false

        public init(
            stored: Binding<CGPoint?>, sizeHint: CGSize, bounds: CGRect, viewport: CGSize,
            defaultTop: CGFloat? = nil, immediateDrag: Bool = false
        ) {
            _stored = stored
            self.sizeHint = sizeHint
            self.bounds = bounds
            self.viewport = viewport
            self.defaultTop = defaultTop
            self.immediateDrag = immediateDrag
        }
        @State private var measured = CGSize.zero
        @State private var dragging = false
        @State private var blockedUntil: TimeInterval = 0
        @State private var placement = MonitorFloatingDrag<CGPoint>()
        @GestureState private var pointerActive = false

        private var size: CGSize {
            CGSize(
                width: measured.width > 1 ? measured.width : sizeHint.width,
                height: measured.height > 1 ? measured.height : sizeHint.height)
        }

        private var center: CGPoint {
            let preferred = (placement.preview ?? stored).map {
                MonitorMotionPlacement.Point(x: Double($0.x), y: Double($0.y))
            }
            let fallback = defaultTop.map {
                MonitorMotionPlacement.Point(
                    x: Double(viewport.width / 2), y: Double($0 + size.height / 2))
            }
            let resolved = MonitorMotionPlacement.center(
                preferred: preferred ?? fallback,
                size: placementSize,
                viewport: .init(width: Double(viewport.width), height: Double(viewport.height)),
                bounds: placementBounds)
            return CGPoint(x: CGFloat(resolved.x), y: CGFloat(resolved.y))
        }

        private var placementSize: MonitorMotionPlacement.Size {
            .init(width: Double(size.width), height: Double(size.height))
        }

        private func clampedCenter(_ point: CGPoint) -> CGPoint {
            let resolved = MonitorMotionPlacement.clamp(
                .init(x: Double(point.x), y: Double(point.y)),
                size: placementSize, bounds: placementBounds)
            return CGPoint(x: CGFloat(resolved.x), y: CGFloat(resolved.y))
        }

        private var placementBounds: MonitorRect {
            MonitorRect(
                x: bounds.minX, y: bounds.minY, width: bounds.width, height: bounds.height)
        }

        public func body(content: Content) -> some View {
            content
                .background(
                    GeometryReader { proxy in
                        Color.clear
                            .onAppear { measured = proxy.size }
                            .onChange(of: proxy.size) { _, next in measured = next }
                    }
                )
                .environment(
                    \.motionControlCanInteract,
                    MotionControlInteraction(isDragging: dragging, blockedUntil: blockedUntil)
                )
                .position(center)
                .onChange(of: bounds) { _, _ in cancelDrag() }
                .onChange(of: viewport) { _, _ in cancelDrag() }
                .onDisappear { cancelDrag() }
                .onChange(of: pointerActive) { _, active in
                    if !active { cancelDrag() }
                }
                .gesture(directDrag, including: immediateDrag ? .none : .all)
                .highPriorityGesture(directDrag, including: immediateDrag ? .all : .none)
                .sensoryFeedback(trigger: dragging) { _, isDragging in
                    isDragging ? .impact(flexibility: .rigid, intensity: 1) : nil
                }
        }

        private func cancelDrag() {
            placement.cancel()
            dragging = false
        }

        private var directDrag: some Gesture {
            DragGesture(minimumDistance: LiveGimbalCopy.dragSlop, coordinateSpace: .global)
                .updating($pointerActive) { _, active, _ in active = true }
                .onChanged { value in
                    if !dragging {
                        dragging = true
                        placement.begin(at: center)
                    }
                    guard let origin = placement.origin else { return }
                    placement.move(
                        to: clampedCenter(
                            CGPoint(
                                x: origin.x + value.translation.width,
                                y: origin.y + value.translation.height)
                        ))
                }
                .onEnded { _ in
                    blockedUntil = ProcessInfo.processInfo.systemUptime + 0.15
                    dragging = false
                    placement.end { stored = $0 }
                }
                .map { _ in () }
        }

    }

    private struct MotionSettingsBottomKey: PreferenceKey {
        static let defaultValue: CGFloat = 0

        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
            value = max(value, nextValue())
        }
    }

    private struct MotionSettingsOverflowReporter: ViewModifier {
        @Binding var canScrollFurther: Bool
        var viewportHeight: CGFloat
        @State private var contentBottom: CGFloat = 0

        func body(content: Content) -> some View {
            if #available(iOS 18.0, *) {
                content.onScrollGeometryChange(for: Bool.self) { geometry in
                    geometry.contentSize.height - geometry.containerSize.height
                        - geometry.contentOffset.y > 2
                } action: { _, more in
                    canScrollFurther = more
                }
            } else {
                content
                    .onPreferenceChange(MotionSettingsBottomKey.self) { bottom in
                        contentBottom = bottom
                        canScrollFurther = bottom > viewportHeight + 2
                    }
                    .onChange(of: viewportHeight) { _, height in
                        canScrollFurther = contentBottom > height + 2
                    }
            }
        }
    }

    /// The native scroll-geometry callback replaces this preference on iOS 18+;
    /// do not keep resolving unused content geometry while the window moves.
    private struct MotionSettingsBottomReporter: ViewModifier {
        func body(content: Content) -> some View {
            if #available(iOS 18.0, *) {
                content
            } else {
                content.background {
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: MotionSettingsBottomKey.self,
                            value: proxy.frame(in: .named("motion.settings")).maxY)
                    }
                }
            }
        }
    }

    private struct LiveGimbalMoveEditor<Host: GimbalPanelHost, Palette: LiveChromePalette>: View {
        var maximumHeight: CGFloat
        @Environment(Host.self) private var model

        @Environment(\.motionControlCanInteract) private var canInteract
        @State private var scrollHeight: CGFloat = 0
        @State private var canScrollFurther = false

        var body: some View {
            VStack(spacing: 0) {
                header
                    .padding(.horizontal, 14)
                    .padding(.top, 10)
                    .padding(.bottom, 8)

                ScrollView {
                    settings
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .modifier(MotionSettingsBottomReporter())
                }
                .coordinateSpace(name: "motion.settings")
                .scrollIndicators(.hidden)
                .background {
                    GeometryReader { proxy in
                        Color.clear
                            .onAppear { scrollHeight = proxy.size.height }
                            .onChange(of: proxy.size.height) { _, height in scrollHeight = height }
                    }
                }
                .modifier(
                    MotionSettingsOverflowReporter(
                        canScrollFurther: $canScrollFurther, viewportHeight: scrollHeight)
                )
                .mask {
                    VStack(spacing: 0) {
                        Color.black
                        LinearGradient(
                            colors: [.black, canScrollFurther ? .clear : .black],
                            startPoint: .top, endPoint: .bottom
                        )
                        .frame(height: min(24, scrollHeight))
                    }
                }
                .accessibilityIdentifier("motion.editor.scroll")
                .accessibilityValue(canScrollFurther ? "More settings below" : "End of settings")

                if let reason = model.programmedZoomUnavailableReason {
                    Text(reason)
                        .font(MonitorTheme.font(11, weight: .regular))
                        .foregroundStyle(Palette.muted)
                        .padding(.horizontal, 14)
                        .padding(.top, 6)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("motion.zoomUnavailable")
                }

                actions
                    .padding(.horizontal, 14)
                    .padding(.top, 10)
                    .padding(.bottom, 14)
                    .overlay(alignment: .top) {
                        Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1)
                    }
            }
            .frame(height: min(maximumHeight, 420))
            .monitorGlass(in: RoundedRectangle(cornerRadius: 16), density: .expanded)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .contentShape(Rectangle())
        }

        private var header: some View {
            HStack {
                Text(LiveGimbalCopy.programmedMove)
                    .font(MonitorTheme.font(9, weight: .semibold))
                    .textCase(.uppercase).tracking(1.8)
                    .foregroundStyle(Palette.text)
                    .accessibilityIdentifier("motion.editor.title")
                Spacer()
                Button {
                    guard canInteract() else { return }
                    model.liveGimbalPanel = .runPill
                } label: {
                    MonitorIcon.minimize
                        .frame(width: 16, height: 16)
                        .foregroundStyle(Palette.text)
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.monitorTapTarget)
                .accessibilityLabel("Minimize")
                .accessibilityIdentifier("motion.minimize")
                LiveCloseButton<Palette>(
                    action: {
                        guard canInteract() else { return }
                        model.liveGimbalPanel = model.gimbalMoveRunning ? .runPill : .none
                    }, size: 30
                )
                .accessibilityIdentifier("motion.close")
            }
        }

        private var settings: some View {
            VStack(alignment: .leading, spacing: 10) {
                waypointRow(.a, duration: nil, floor: nil)
                waypointRow(
                    .b, duration: model.gimbalProgram.durationAB,
                    floor: GimbalProgram.minTravelDuration(
                        from: model.gimbalProgram.a, to: model.gimbalProgram.b)
                ) { model.setGimbalLegDuration(ab: $0, bc: nil) }
                waypointRow(
                    .c, duration: model.gimbalProgram.durationBC,
                    floor: GimbalProgram.minTravelDuration(
                        from: model.gimbalProgram.b, to: model.gimbalProgram.c)
                ) { model.setGimbalLegDuration(ab: nil, bc: $0) }

                if model.gimbalProgram.b != nil, model.gimbalProgram.c != nil {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Smoothness")
                            Spacer()
                            Text("\(Int((model.gimbalProgram.smoothness * 100).rounded()))%")
                        }
                        Slider(
                            value: Binding(
                                get: { model.gimbalProgram.smoothness },
                                set: { if canInteract() { model.setGimbalSmoothness($0) } }),
                            in: 0...1, step: 0.05
                        )
                        .tint(Palette.accent)
                        .accessibilityLabel("Path smoothness")
                    }
                    .font(MonitorTheme.font(12, weight: .regular))
                    .foregroundStyle(Palette.text)
                }

                MonitorCaptureToggle(
                    "Loop", help: "Repeat back and forth until Stop.",
                    helpColor: MonitorTheme.secondary,
                    isOn: Binding(
                        get: { model.gimbalProgram.loop },
                        set: { if canInteract() { model.setGimbalLoop($0) } })
                )
                .disabled(model.gimbalMoveRunning)
                .accessibilityIdentifier("motion.loop")
            }
        }

        private var actions: some View {
            HStack(spacing: 8) {
                Button {
                    guard canInteract() else { return }
                    if model.gimbalMovePaused {
                        model.restartProgrammedMove()
                    } else {
                        model.clearGimbalProgram()
                    }
                } label: {
                    Text(model.gimbalMovePaused ? "Restart" : LiveGimbalCopy.clear)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.monitorTapTarget)
                .accessibilityIdentifier(model.gimbalMovePaused ? "motion.restart" : "motion.clear")
                .foregroundStyle(Palette.muted)
                .background(Palette.glassBright, in: Capsule())

                if model.gimbalMoveCanPause {
                    Button(model.gimbalMovePaused ? "Resume" : "Pause") {
                        guard canInteract() else { return }
                        model.pauseOrResumeProgrammedMove()
                    }
                    .buttonStyle(.monitorTapTarget)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .foregroundStyle(Palette.background)
                    .background(Palette.accent, in: Capsule())
                    .accessibilityIdentifier("motion.pauseResume")
                }

                Button {
                    guard canInteract() else { return }
                    model.runProgrammedMove()
                } label: {
                    Text(
                        model.gimbalMoveRunning
                            ? (model.gimbalStartCountdown.map { "Stop · \($0)" }
                                ?? LiveGimbalCopy.stopMove) : LiveGimbalCopy.runMove
                    )
                    .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.monitorTapTarget)
                .foregroundStyle(runEnabled ? Palette.background : Palette.muted)
                .background(
                    (model.gimbalMoveRunning
                        ? Palette.rec
                        : runEnabled ? Palette.accent : Palette.glassBright),
                    in: Capsule()
                )
                .accessibilityIdentifier("motion.startStop")
                .disabled(!runEnabled && !model.gimbalMoveRunning)
                .opacity(runEnabled || model.gimbalMoveRunning ? 1 : 0.45)
            }
            .font(MonitorTheme.font(14, weight: .semibold))
        }

        private var runEnabled: Bool {
            model.canRunProgrammedMove || model.gimbalMoveRunning
        }

        private func waypointRow(
            _ slot: GimbalWaypointSlot,
            duration: TimeInterval?,
            floor: TimeInterval?,
            onDuration: ((TimeInterval) -> Void)? = nil
        ) -> some View {
            let point = model.gimbalProgram[slot]
            let set = point != nil
            return VStack(spacing: 5) {
                HStack(spacing: 9) {
                    Text(slot.letter)
                        .font(MonitorTheme.font(10, weight: .bold))
                        .foregroundStyle(set ? Palette.background : Palette.muted)
                        .frame(width: 22, height: 22)
                        .background(set ? Palette.accent : Color.white.opacity(0.1), in: Circle())
                    Text(readout(point))
                        .font(MonitorTheme.font(11)).monospacedDigit()
                        .foregroundStyle(set ? Palette.text : MonitorTheme.secondary)
                        .lineLimit(1).minimumScaleFactor(0.7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("motion.waypoint.\(slot.letter).readout")
                    Button {
                        guard canInteract() else { return }
                        model.setGimbalWaypoint(slot)
                    } label: {
                        Text(set ? "RESET" : "SET")
                            .font(MonitorTheme.font(10, weight: .bold)).tracking(0.6)
                            .foregroundStyle(set ? Palette.text : Palette.background)
                            .padding(.horizontal, 11).padding(.vertical, 7)
                            .background(
                                set ? Palette.glassBright : Palette.accent,
                                in: RoundedRectangle(cornerRadius: 8)
                            )
                            .frame(minWidth: 52, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.monitorTapTarget)
                    .accessibilityIdentifier("motion.waypoint.\(slot.letter)")
                    .accessibilityLabel(
                        "\(set ? LiveGimbalCopy.update : LiveGimbalCopy.set) \(slot.letter)")
                    if set {
                        Button {
                            guard canInteract() else { return }
                            model.clearGimbalWaypoint(slot)
                        } label: {
                            MonitorIcon.x
                                .frame(width: 12, height: 12)
                                .foregroundStyle(Palette.muted)
                                .frame(width: 26, height: 26)
                        }
                        .buttonStyle(.monitorTapTarget)
                        .accessibilityLabel("Clear \(slot.letter)")
                    }
                }
                if set, let duration, let onDuration, let floor {
                    HStack(spacing: 6) {
                        Text(slot == .b ? "A → B duration" : "B → C duration")
                            .font(MonitorTheme.font(8.5)).tracking(0.7)
                            .foregroundStyle(Palette.muted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        durationDial(duration, floor: floor, slot: slot, onChange: onDuration)
                    }
                    .padding(.top, 6)
                    .overlay(alignment: .top) {
                        Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1)
                    }
                }
            }
            .padding(.horizontal, 9).padding(.vertical, 7)
            .background(
                Color.white.opacity(set ? 0.05 : 0.028), in: RoundedRectangle(cornerRadius: 12)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12).strokeBorder(
                    set ? Palette.accent.opacity(0.26) : Color.white.opacity(0.07))
            )
            .foregroundStyle(Palette.text)
        }

        private func durationDial(
            _ value: TimeInterval, floor: TimeInterval, slot: GimbalWaypointSlot,
            onChange: @escaping (TimeInterval) -> Void
        ) -> some View {
            let cameraID = model.connectedCameraID
            let phase = model.connectionPhaseLabel
            return MonitorDurationDial(
                value: value, range: floor...GimbalProgram.maxDuration, step: 0.5,
                format: GimbalProgram.durationLabel,
                enabled: {
                    // Render eligibility must recover on release without waiting
                    // for another render after the tap-suppression deadline.
                    !canInteract.isDragging && model.liveGimbalPanel == .editor
                        && model.canSetGimbalConfiguration
                        && model.connectedCameraID == cameraID
                        && model.connectionPhaseLabel == phase
                },
                haptics: model.hapticsEnabled,
                interactionIdentity: {
                    AnyHashable(model.connectedCameraID)
                },
                onChange: { next in
                    guard canInteract(), model.liveGimbalPanel == .editor,
                        model.canSetGimbalConfiguration,
                        model.connectedCameraID == cameraID,
                        model.connectionPhaseLabel == phase
                    else { return }
                    onChange(next)
                }
            )
            .accessibilityLabel(slot == .b ? "A to B duration" : "B to C duration")
            .accessibilityIdentifier("motion.duration.\(slot.letter)")
        }

        private func readout(_ point: GimbalWaypoint?) -> String {
            guard let point else { return "Not set" }
            return String(
                format: "PAN %+.0f°  TILT %+.0f°  %.1f×", point.yawDeg, point.pitchDeg, point.zoom)
        }

    }

    private struct LiveGimbalRunPill<Host: GimbalPanelHost, Palette: LiveChromePalette>: View {
        @Environment(Host.self) private var model

        @Environment(\.motionControlCanInteract) private var canInteract

        var body: some View {
            HStack(spacing: 0) {
                if model.gimbalMoveCanPause {
                    Button(model.gimbalMovePaused ? "Resume" : "Pause") {
                        guard canInteract() else { return }
                        model.pauseOrResumeProgrammedMove()
                    }
                    .font(MonitorTheme.font(13, weight: .bold))
                    .foregroundStyle(Palette.text)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .buttonStyle(.monitorTapTarget)
                    .accessibilityIdentifier("motion.pauseResume")
                }
                Button {
                    guard canInteract() else { return }
                    model.runProgrammedMove()
                } label: {
                    Text(
                        model.gimbalMoveRunning
                            ? (model.gimbalStartCountdown.map { "Stop · \($0)" }
                                ?? LiveGimbalCopy.stopMove) : LiveGimbalCopy.runMove
                    )
                    .font(MonitorTheme.font(13, weight: .bold))
                    .textCase(.uppercase)
                    .kerning(0.6)
                    .foregroundStyle(Palette.text)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                }
                .buttonStyle(.monitorTapTarget)
                .accessibilityIdentifier("motion.startStop")
                .disabled(
                    !model.canRunProgrammedMove && !model.gimbalMoveRunning
                )
                .opacity(
                    model.canRunProgrammedMove || model.gimbalMoveRunning ? 1 : 0.45)

                Button {
                    guard canInteract() else { return }
                    model.liveGimbalPanel = .editor
                } label: {
                    MonitorIcon.maximize
                        .frame(width: 16, height: 16)
                        .foregroundStyle(Palette.text)
                        .frame(width: 44, height: 40)
                }
                .buttonStyle(.monitorTapTarget)
                .accessibilityLabel("Expand motion control")
                .accessibilityIdentifier("motion.expand")
            }
            .frame(minWidth: 172)
            .liveChromeGlass(in: Capsule())
        }
    }

    struct LiveGimbalWaypointMarks<Host: GimbalPanelHost, Palette: LiveChromePalette>: View {
        @Environment(Host.self) private var model
        var feed: CGRect

        var body: some View {
            TimelineView(.periodic(from: .now, by: GimbalStick.streamInterval)) { _ in
                let live = model.overlayGimbalWaypoint
                let aspect = feed.width > 1 ? Double(feed.width / max(feed.height, 1)) : 16 / 9
                ZStack(alignment: .topLeading) {
                    if let live {
                        if let curve = GimbalProgramCurve(program: model.gimbalProgram) {
                            Path { path in
                                var connected = false
                                for pose in curve.samples() {
                                    let mark = GimbalWaypointOverlay.project(
                                        waypoint: pose, slot: .b,
                                        live: live, aspect: aspect,
                                        wideHFovDeg: model.waypointOverlayHFovDeg)
                                    guard mark.onScreen else {
                                        connected = false
                                        continue
                                    }
                                    let point = CGPoint(
                                        x: feed.minX + CGFloat(
                                            GimbalWaypointPresentation.normalizedX(
                                                mark.nx,
                                                poseInvertPan: model.gimbalPoseInvertPan,
                                                assistMirror: model.assistMirrorsHorizontally))
                                            * feed.width,
                                        y: feed.minY + CGFloat(mark.ny) * feed.height)
                                    if connected {
                                        path.addLine(to: point)
                                    } else {
                                        path.move(to: point)
                                    }
                                    connected = true
                                }
                            }
                            .stroke(
                                Palette.text.opacity(0.4),
                                style: StrokeStyle(lineWidth: 1, dash: [4, 5]))
                        }
                        ForEach(
                            GimbalWaypointOverlay.marks(
                                program: model.gimbalProgram, live: live, aspect: aspect,
                                wideHFovDeg: model.waypointOverlayHFovDeg),
                            id: \.slot
                        ) { mark in
                            Text(mark.slot.letter)
                                .font(MonitorTheme.font(13, weight: .bold))
                                .foregroundStyle(Palette.onAccent)
                                .frame(width: 26, height: 26)
                                .background(
                                    Palette.accent.opacity(mark.onScreen ? 0.92 : 0.45),
                                    in: Circle()
                                )
                                .shadow(color: .black.opacity(0.45), radius: 2)
                                .position(
                                    x: feed.minX + CGFloat(
                                        GimbalWaypointPresentation.normalizedX(
                                            mark.nx,
                                            poseInvertPan: model.gimbalPoseInvertPan,
                                            assistMirror: model.assistMirrorsHorizontally))
                                        * feed.width,
                                    y: feed.minY + CGFloat(mark.ny) * feed.height
                                )
                                .opacity(mark.onScreen ? 1 : 0.7)
                        }
                    }
                }
            }
            .allowsHitTesting(false)
        }
    }
#endif
