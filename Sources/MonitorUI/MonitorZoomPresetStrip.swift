#if os(iOS)
    import MonitorPresentation
    import SwiftUI

    /// The zoom dial's preset slots and ramp choice. Values and actions only: the host
    /// saves, stores and moves the camera. Twin of Android `MonitorZoomPresetStrip`.
    public struct MonitorZoomPresetControls {
        public var presets: MonitorZoomPresets
        public var onSelect: (Int) -> Void
        public var onSave: (Int) -> Void
        public var onRamp: (Double) -> Void

        public init(
            presets: MonitorZoomPresets, onSelect: @escaping (Int) -> Void,
            onSave: @escaping (Int) -> Void, onRamp: @escaping (Double) -> Void
        ) {
            self.presets = presets
            self.onSelect = onSelect
            self.onSave = onSave
            self.onRamp = onRamp
        }
    }

    /// Tap a saved slot to go there; tap an empty slot or hold any slot to save the current zoom.
    /// The ramp key opens the ramp popup (`onRampTap`), styled like the other camera popups.
    struct MonitorZoomPresetStrip: View {
        static let slotShape = RoundedRectangle(cornerRadius: 10, style: .continuous)

        let controls: MonitorZoomPresetControls
        let maximum: Double
        let vertical: Bool
        let label: (Double) -> String
        let haptics: Bool
        var onRampTap: () -> Void = {}
        @State private var savedTick = 0

        var body: some View {
            let layout = vertical
                ? AnyLayout(VStackLayout(spacing: 10)) : AnyLayout(HStackLayout(spacing: 10))
            layout {
                ForEach(0..<MonitorZoomPresets.slotCount, id: \.self) { index in slot(index) }
                ramp
            }
            .sensoryFeedback(.impact(weight: .medium), trigger: savedTick) { _, _ in haptics }
        }

        private func slot(_ index: Int) -> some View {
            let saved = controls.presets.slots[index]
            let target = controls.presets.target(at: index, maximum: maximum)
            return Text(saved.map(label) ?? "+")
                .font(MonitorTheme.font(saved == nil ? 18 : 13, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(saved == nil ? MonitorTheme.secondary : MonitorTheme.text)
                .lineLimit(1).minimumScaleFactor(0.7)
                .frame(width: 44, height: 44)
                .background(.white.opacity(0.08), in: Self.slotShape)
                .overlay(Self.slotShape.stroke(.white.opacity(0.14), lineWidth: 1))
                .opacity(saved != nil && target == nil ? 0.4 : 1)
                .contentShape(Self.slotShape)
                .gesture(
                    LongPressGesture(minimumDuration: 0.5).exclusively(before: TapGesture())
                        .onEnded { gesture in
                            switch gesture {
                            case .first: save(index)
                            case .second:
                                if saved == nil { save(index) } else { controls.onSelect(index) }
                            }
                        }
                )
                // A Mac's right-click saves the current zoom here, as the long press does.
                .monitorSecondaryClick { save(index) }
                .accessibilityElement(children: .ignore)
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel("Zoom preset \(index + 1)")
                .accessibilityValue(saved.map(label) ?? "Empty")
                .accessibilityHint(
                    saved == nil
                        ? "Saves the current zoom."
                        : target == nil
                            ? "Past this format's zoom limit. Hold saves the current zoom."
                            : "Goes to this zoom. Hold saves the current zoom.")
                .accessibilityAction {
                    if saved == nil { save(index) } else { controls.onSelect(index) }
                }
                .accessibilityAction(named: "Save current zoom") { save(index) }
                .accessibilityIdentifier("monitor.zoom.preset.\(index + 1)")
        }

        private var ramp: some View {
            Button(action: onRampTap) {
                VStack(spacing: 1) {
                    Text("RAMP").font(MonitorTheme.font(8, weight: .semibold)).tracking(0.6)
                        .foregroundStyle(MonitorTheme.secondary)
                    Text(MonitorZoomPresets.rampLabel(controls.presets.rampSeconds))
                        .font(MonitorTheme.font(11, weight: .bold)).monospacedDigit()
                        .foregroundStyle(MonitorTheme.text)
                }
                .lineLimit(1).minimumScaleFactor(0.7)
                .frame(width: 44, height: 44)
                .background(.white.opacity(0.08), in: Self.slotShape)
                .overlay(Self.slotShape.stroke(.white.opacity(0.14), lineWidth: 1))
                .contentShape(Self.slotShape)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Preset zoom ramp")
            .accessibilityValue(MonitorZoomPresets.rampLabel(controls.presets.rampSeconds))
            .accessibilityHint("Opens the ramp choices.")
            .accessibilityIdentifier("monitor.zoom.preset.ramp")
        }

        private func save(_ index: Int) {
            controls.onSave(index)
            savedTick += 1
        }
    }
#endif
