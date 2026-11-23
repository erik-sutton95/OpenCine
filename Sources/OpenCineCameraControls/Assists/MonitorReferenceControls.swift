#if os(iOS)
    import MonitorPresentation
    import MonitorUI
    import OpenCineAppKitApple
    import OpenCineMedia
    import SwiftUI

    func referenceAspect(_ source: Double, effects: MonitorFrameEffects) -> Double {
        let factor = DesqueezeAssist.snap(effects.desqueezeFactor)
        return effects.desqueezeHorizontal ? source * factor : source / factor
    }

    /// Live continuity settings, with an explicit action to replace the saved image.
    public struct MonitorReferenceControls: View {
        @Bindable private var store: MonitorReferenceStore
        private let canCapture: Bool
        private let displayAspect: Double?
        private let capture: @MainActor () async -> MonitorReferenceStill?
        static let toolID = "REF"

        public init(
            store: MonitorReferenceStore, canCapture: Bool, displayAspect: Double?,
            capture: @escaping @MainActor () async -> MonitorReferenceStill?
        ) {
            self.store = store
            self.canCapture = canCapture
            self.displayAspect = displayAspect
            self.capture = capture
        }

        private var matches: Bool {
            guard let displayAspect, let saved = store.saved else { return false }
            return MonitorReferenceLayout.matches(saved: saved.displayAspect, live: displayAspect)
        }

        var isActive: Bool { store.visible && matches }
        var hasSavedReference: Bool { store.saved != nil }
        var allowsDividerInteraction: Bool { isActive && store.mode == .split }

        /// A configured reference toggles from the tray. First use and mismatched framing open its options.
        func toggleIfReady() -> Bool {
            guard matches else { return false }
            store.visible.toggle()
            return true
        }

        public var body: some View {
            MonitorInspectorCard {
                VStack(alignment: .leading, spacing: 0) {
                    if let saved = store.saved {
                        Image(decorative: saved.image, scale: 1)
                            .resizable().aspectRatio(saved.displayAspect, contentMode: .fit)
                            .frame(maxWidth: .infinity, maxHeight: 100)
                            .clipShape(.rect(cornerRadius: 6))
                            .accessibilityLabel("Saved reference")
                        MonitorSettingsSwitchInlineRow(
                            title: "Show Reference", showTopDivider: false, isOn: store.visible,
                            identifier: "monitor.reference.visible"
                        ) {
                            store.visible.toggle()
                        }
                        MonitorSettingsInlineRow(
                            title: "Comparison", showTopDivider: false, stacked: true
                        ) {
                            MonitorSegmentedControl(
                                options: MonitorReferenceStore.Mode.allCases,
                                selection: $store.mode, title: \.rawValue
                            )
                            .buttonStyle(MonitorSettingsButtonStyle())
                        }
                        if store.mode == .split {
                            MonitorSettingsInlineRow(title: "Reference side", stacked: true) {
                                MonitorSegmentedControl(
                                    options: [false, true],
                                    selection: $store.referenceOnRight,
                                    title: { $0 ? "Right" : "Left" }
                                )
                                .buttonStyle(MonitorSettingsButtonStyle())
                            }
                        }
                        MonitorSettingsInlineRow(title: "Reference opacity", stacked: true) {
                            let opacity = store.mode == .blend ? $store.blend : $store.splitOpacity
                            MonitorSettingsPercentSlider(
                                value: Binding(
                                    get: { Int((opacity.wrappedValue * 100).rounded()) },
                                    set: { opacity.wrappedValue = Double($0) / 100 }),
                                range: 0...100
                            )
                            .accessibilityLabel("Reference opacity")
                        }
                        if store.visible, canCapture, !matches {
                            Text(
                                "Reference framing differs. Match the source aspect and desqueeze, or replace the reference."
                            )
                            .font(MonitorTheme.font(12)).foregroundStyle(MonitorTheme.secondary)
                            .padding(.bottom, 8)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("No reference saved")
                                .font(MonitorTheme.font(13, weight: .semibold))
                                .foregroundStyle(MonitorTheme.text)
                            Text("Save a live frame or use a paused clip frame from Playback.")
                                .font(MonitorTheme.font(12))
                                .foregroundStyle(MonitorTheme.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    MonitorReferenceSaveButton(
                        store: store,
                        title: store.saved == nil ? "Save Live Frame" : "Replace Reference",
                        enabled: canCapture, inInspector: true, capture: capture
                    )
                    .padding(.top, 8)
                }
                .padding(.vertical, 12)
                .tint(MonitorTheme.accent)
                .environment(\.monitorSegmentedAppearance, .inspector)
            }
        }
    }

    /// A capture action for either a live source or a ready, paused clip.
    public struct MonitorReferenceSaveButton: View {
        private let store: MonitorReferenceStore
        private let title: String
        private let enabled: Bool
        private let inInspector: Bool
        private let capture: @MainActor () async -> MonitorReferenceStill?
        @State private var confirmReplacement = false

        public init(
            store: MonitorReferenceStore, title: String, enabled: Bool,
            capture: @escaping @MainActor () async -> MonitorReferenceStill?
        ) {
            self.init(store: store, title: title, enabled: enabled, inInspector: false, capture: capture)
        }

        init(
            store: MonitorReferenceStore, title: String, enabled: Bool, inInspector: Bool,
            capture: @escaping @MainActor () async -> MonitorReferenceStill?
        ) {
            self.store = store
            self.title = title
            self.enabled = enabled
            self.inInspector = inInspector
            self.capture = capture
        }

        public var body: some View {
            actionButton
            .disabled(!enabled || store.saving)
            .accessibilityLabel(title)
            .accessibilityIdentifier("monitor.reference.capture")
            .accessibilityValue(
                store.saving
                    ? "Saving reference"
                    : store.saved == nil ? "No saved reference" : "Reference saved"
            )
            .confirmationDialog(
                "Replace the saved reference?", isPresented: $confirmReplacement,
                titleVisibility: .visible
            ) {
                Button("Replace Reference", action: save)
                Button("Cancel", role: .cancel) {}
            }
            .alert(
                "Reference",
                isPresented: Binding(
                    get: { store.notice != nil },
                    set: { presented in
                        if !presented { store.dismissNotice() }
                    })
            ) {
                Button("OK", action: store.dismissNotice)
            } message: {
                Text(store.notice ?? "")
            }
        }

        @ViewBuilder private var actionButton: some View {
            if inInspector {
                MonitorSettingsActionPill(title: title, action: requestSave)
            } else {
                Button(title, action: requestSave)
            }
        }

        private func requestSave() {
            if store.saved == nil { save() } else { confirmReplacement = true }
        }

        private func save() {
            Task { await store.save(capture) }
        }
    }

    /// A display-only layer. Its image and drag handle are laid out in the current picture's coordinates.
    public struct MonitorReferenceOverlay: View {
        @Bindable private var store: MonitorReferenceStore
        private let imageRect: CGRect
        private let viewport: CGRect?
        private let displayAspect: Double
        private let mirrorHorizontal: Bool
        private let mirrorVertical: Bool
        private let clockwiseTurns: Int
        private let interactive: Bool

        public init(
            store: MonitorReferenceStore, imageRect: CGRect, viewport: CGRect? = nil,
            displayAspect: Double,
            mirrorHorizontal: Bool, mirrorVertical: Bool, clockwiseTurns: Int = 0,
            interactive: Bool = true
        ) {
            self.store = store
            self.imageRect = imageRect
            self.viewport = viewport
            self.displayAspect = displayAspect
            self.mirrorHorizontal = mirrorHorizontal
            self.mirrorVertical = mirrorVertical
            self.clockwiseTurns = clockwiseTurns
            self.interactive = interactive
        }

        public var body: some View {
            if store.visible, let saved = store.saved,
                MonitorReferenceLayout.matches(saved: saved.displayAspect, live: displayAspect)
            {
                GeometryReader { reader in
                    let visible = imageRect.intersection(
                        viewport ?? CGRect(origin: .zero, size: reader.size))
                    if !visible.isNull && !visible.isEmpty {
                        let split = MonitorReferenceLayout.splitRect(
                            in: visible, fraction: store.divider, clockwiseTurns: clockwiseTurns)
                        ZStack(alignment: .topLeading) {
                            raster(saved.image)
                                .opacity(store.mode == .blend ? store.blend : store.splitOpacity)
                                .mask {
                                    let mask =
                                        store.mode == .blend
                                        ? visible
                                        : MonitorReferenceLayout.splitRect(
                                            in: visible, fraction: store.divider,
                                            clockwiseTurns: clockwiseTurns,
                                            referenceOnRight: store.referenceOnRight)
                                    Rectangle().frame(width: mask.width, height: mask.height)
                                        .position(x: mask.midX, y: mask.midY)
                                }
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                            if store.mode == .split { divider(visible: visible, split: split) }
                        }
                        .frame(width: reader.size.width, height: reader.size.height)
                        .coordinateSpace(name: "monitor-reference-divider")
                        .clipped()
                    }
                }
            }
        }

        private func raster(_ image: CGImage) -> some View {
            let swapsAxes = !clockwiseTurns.isMultiple(of: 2)
            return Image(decorative: image, scale: 1).resizable()
                .frame(
                    width: swapsAxes ? imageRect.height : imageRect.width,
                    height: swapsAxes ? imageRect.width : imageRect.height
                )
                .rotationEffect(.degrees(-90 * Double(clockwiseTurns)))
                .scaleEffect(x: mirrorHorizontal ? -1 : 1, y: mirrorVertical ? -1 : 1)
                .position(x: imageRect.midX, y: imageRect.midY)
        }

        private func divider(visible: CGRect, split: CGRect) -> some View {
            let turn = ((clockwiseTurns % 4) + 4) % 4
            let vertical = turn.isMultiple(of: 2)
            let position = CGPoint(
                x: vertical ? (turn == 0 ? split.maxX : split.minX) : visible.midX,
                y: vertical ? visible.midY : (turn == 1 ? split.minY : split.maxY))
            return Rectangle().fill(.white)
                .frame(width: vertical ? 2 : visible.width, height: vertical ? visible.height : 2)
                .shadow(color: .black, radius: 1)
                .overlay {
                    if interactive {
                        Capsule().fill(.black.opacity(0.72))
                            .overlay {
                                Capsule().strokeBorder(.white, lineWidth: 1)
                                MonitorIcon.chevronsUpDown.frame(width: 14, height: 14)
                                    .foregroundStyle(.white)
                                    .rotationEffect(.degrees(90))
                            }
                            .frame(width: 28, height: 22)
                            .rotationEffect(vertical ? .zero : .degrees(90))
                    }
                }
                .frame(width: vertical ? 44 : visible.width, height: vertical ? visible.height : 44)
                .background {
                    if interactive {
                        GeometryReader { geometry in
                            Color.clear.preference(
                                key: MonitorReferenceDividerHitRectKey.self,
                                value: geometry.frame(in: .named(LiveCanvasSpace.name)))
                        }
                        .allowsHitTesting(false)
                    }
                }
                .contentShape(Rectangle())
                .highPriorityGesture(
                    DragGesture(
                        minimumDistance: 4, coordinateSpace: .named("monitor-reference-divider")
                    )
                    .onChanged { value in
                        store.divider = MonitorReferenceLayout.fraction(
                            at: value.location, in: visible, clockwiseTurns: clockwiseTurns)
                    }
                )
                .allowsHitTesting(interactive)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Reference divider")
                .accessibilityIdentifier("monitor.reference.divider")
                .accessibilityValue("\(Int((store.divider * 100).rounded())) percent")
                .accessibilityHidden(!interactive)
                .accessibilityAdjustableAction { direction in
                    guard interactive else { return }
                    switch direction {
                    case .increment: store.divider = min(1, store.divider + 0.05)
                    case .decrement: store.divider = max(0, store.divider - 0.05)
                    @unknown default: break
                    }
                }
                .position(position)
        }
    }

    struct MonitorReferenceDividerHitRectKey: PreferenceKey {
        static let defaultValue: CGRect? = nil

        static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) {
            value = nextValue() ?? value
        }
    }

    private struct MonitorReferenceDividerHitRectEnvironmentKey: EnvironmentKey {
        static let defaultValue: CGRect? = nil
    }

    extension EnvironmentValues {
        var monitorReferenceDividerHitRect: CGRect? {
            get { self[MonitorReferenceDividerHitRectEnvironmentKey.self] }
            set { self[MonitorReferenceDividerHitRectEnvironmentKey.self] = newValue }
        }
    }
#endif
