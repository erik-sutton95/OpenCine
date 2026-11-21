#if os(iOS)
    import MonitorPresentation
    import SwiftUI

    /// The zoom control: one panel on the trailing edge holding the current zoom, the presets, the
    /// ramp key and a vertical ruler. The ruler behaves like the other setting dials: the scale
    /// slides under a fixed center line, a drag moves it from the current zoom smoothly (ticks and
    /// a light haptic every 0.1x; the camera zooms live), and a tap goes to the step under the
    /// finger. The ramp key opens a popup styled like the camera value popups. Camera adapters own continuous write coalescing and final
    /// settlement; opening the ruler and drawing it never issue commands.
    /// Kotlin twin: `MonitorZoomRuler` (monitor-ui).
    public struct MonitorZoomDial: View {
        /// The ticks' strip inside the ruler.
        static let rulerWidth: CGFloat = 40
        static let edgeMargin: CGFloat = 12
        /// Room left of the ticks for the whole-step labels.
        static let labelGutter: CGFloat = 30
        /// Keeps the end ticks off the ruler's ends.
        static let endInset: CGFloat = 14
        /// The column holding the readout, presets and ramp key.
        static let columnWidth: CGFloat = 56
        static let panelPadding: CGFloat = 8
        static let panelGap: CGFloat = 6
        static let panelShape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        static let rulerShape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        /// A press that moves less than this is a tap.
        static let tapTravel: CGFloat = 10

        private let viewport: CGSize
        private let safeArea: EdgeInsets
        private let attachment: MonitorZoomAttachment
        private let topClearance: CGFloat
        private let bottomClearance: CGFloat
        private let isPresented: Bool
        private let scale: MonitorZoomScale
        private let opticalStops: [Double]
        private let caption: String
        private let label: (Double) -> String
        private let onEditing: (Bool) -> Void
        private let onClose: () -> Void
        private let haptics: Bool
        private let presets: MonitorZoomPresetControls?
        private let rampPlacement: MonitorCapturePopupLayout?
        @Binding private var value: Double
        @State private var rampOpen = false
        @State private var drag = MonitorZoomDrag()
        @GestureState private var pointerActive = false
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @Environment(\.scenePhase) private var scenePhase
        @Environment(\.monitorHDRChromeGain) private var hdrGain
        @State private var appeared = false
        @State private var stepTick = 0
        /// The value the scale shows while a finger is down; the reported zoom otherwise.
        @State private var scrub: Double?
        @State private var origin: Double?

        /// `attachment` and `marks` are kept for source compatibility: the ruler always sits on
        /// the trailing edge and draws its own 0.1x, 0.5x and 1x ticks.
        public init(
            viewport: CGSize, safeArea: EdgeInsets = EdgeInsets(),
            attachment: MonitorZoomAttachment = .trailing, bottomClearance: CGFloat = 0,
            topClearance: CGFloat = 0,
            isPresented: Bool = true,
            scale: MonitorZoomScale,
            marks: [Double] = [], opticalStops: [Double] = [1], caption: String = "",
            value: Binding<Double>, label: @escaping (Double) -> String,
            onEditing: @escaping (Bool) -> Void, onClose: @escaping () -> Void,
            haptics: Bool = true, presets: MonitorZoomPresetControls? = nil,
            rampPlacement: MonitorCapturePopupLayout? = nil
        ) {
            _ = marks
            self.viewport = viewport
            self.safeArea = safeArea
            self.attachment = attachment
            self.topClearance = max(0, topClearance)
            self.bottomClearance = max(0, bottomClearance)
            self.isPresented = isPresented
            self.scale = scale
            self.opticalStops = opticalStops
            self.caption = caption
            self._value = value
            self.label = label
            self.onEditing = onEditing
            self.onClose = onClose
            self.haptics = haptics
            self.presets = presets
            self.rampPlacement = rampPlacement
        }

        static var panelWidth: CGFloat {
            panelPadding + columnWidth + panelGap + labelGutter + rulerWidth + panelPadding / 2
        }

        /// The whole zoom panel in viewport coordinates.
        var panelFrame: CGRect {
            let trailing = viewport.width - max(0, safeArea.trailing) - Self.edgeMargin
            let top = max(topClearance, safeArea.top + Self.edgeMargin)
            let bottom = viewport.height - max(bottomClearance, safeArea.bottom + Self.edgeMargin)
            return CGRect(
                x: trailing - Self.panelWidth, y: top,
                width: Self.panelWidth, height: max(0, bottom - top))
        }

        /// The ruler's height inside the panel.
        var rulerHeight: CGFloat { max(0, panelFrame.height - Self.panelPadding * 2) }

        /// The ramp popup's place: the caller's (the camera popups' own), else a bottom sheet.
        private var rampPlace: MonitorCapturePopupLayout {
            rampPlacement ?? MonitorCapturePopupLayout(
                viewportWidth: viewport.width, viewportHeight: viewport.height,
                tablet: min(viewport.width, viewport.height) >= 600,
                safeArea: MonitorSafeArea(top: safeArea.top, leading: safeArea.leading,
                    bottom: safeArea.bottom, trailing: safeArea.trailing))
        }

        var ruler: MonitorZoomRulerScale {
            MonitorZoomRulerScale(minimum: scale.minimum, maximum: scale.maximum)
        }

        /// The value under the center line.
        private var shown: Double { scrub ?? value }

        private var ink: Color {
            opticalStops.contains { abs($0 - value) < 0.05 }
                ? MonitorTheme.edrAccent(gain: hdrGain) : MonitorTheme.digitalCrop
        }

        private var visible: Bool { appeared && isPresented }
        private var acceptsInput: Bool { visible && scenePhase == .active }

        public var body: some View {
            let frame = panelFrame
            ZStack(alignment: .topLeading) {
                Button(action: onClose) {
                    Color.clear.contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close zoom dial")
                .frame(width: viewport.width, height: viewport.height)

                panel
                    .frame(width: frame.width, height: frame.height)
                    .monitorGlass(in: Self.panelShape, density: .zoom)
                    .offset(x: frame.minX, y: frame.minY)
                    .offset(x: visible || reduceMotion ? 0 : 24)
                    .opacity(visible ? 1 : 0)
                    .animation(
                        visible ? MonitorMotion.discIn(reduceMotion) : MonitorMotion.discOut(reduceMotion),
                        value: visible)

                if rampOpen, let presets { rampPopup(presets) }
            }
            .frame(width: viewport.width, height: viewport.height, alignment: .topLeading)
            .allowsHitTesting(acceptsInput)
            .accessibilityHidden(!acceptsInput)
            .onAppear { appeared = true }
            .onChange(of: acceptsInput) { _, active in if !active { cancelPointer() } }
            .onChange(of: viewport) { _, _ in cancelPointer() }
            .onChange(of: topClearance) { _, _ in cancelPointer() }
            .onChange(of: bottomClearance) { _, _ in cancelPointer() }
            .onChange(of: safeArea) { _, _ in cancelPointer() }
            .onChange(of: scale) { _, _ in cancelPointer() }
            .onChange(of: pointerActive) { _, active in if !active { finishEditing() } }
            .onChange(of: isPresented) { _, presented in if !presented { rampOpen = false } }
            .sensoryFeedback(.impact(weight: .light), trigger: stepTick) { _, _ in
                haptics && acceptsInput && stepTick > 0
            }
            .onDisappear {
                cancelPointer()
                appeared = false
            }
        }

        /// The current zoom over the presets and the ramp key, beside the ruler, in one panel.
        private var panel: some View {
            HStack(spacing: Self.panelGap) {
                VStack(spacing: 12) {
                    VStack(spacing: 2) {
                        Text(MonitorZoomRulerScale.readout(shown))
                            .font(MonitorTheme.font(17, weight: .bold)).monospacedDigit()
                            .foregroundStyle(MonitorTheme.edrText(gain: hdrGain))
                        if !caption.isEmpty {
                            Text(caption).font(MonitorTheme.font(9, weight: .semibold)).tracking(1)
                                .foregroundStyle(ink)
                        }
                    }
                    .lineLimit(1).minimumScaleFactor(0.6)
                    .padding(.top, 4)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                    Spacer(minLength: 0)
                    if let presets {
                        MonitorZoomPresetStrip(
                            controls: presets, maximum: scale.maximum, vertical: true,
                            label: label, haptics: haptics, onRampTap: { rampOpen = true })
                    }
                    Spacer(minLength: 0)
                }
                .frame(width: Self.columnWidth)
                rulerBody
                    .frame(width: Self.labelGutter + Self.rulerWidth, height: rulerHeight)
            }
            .padding(.leading, Self.panelPadding)
            .padding(.trailing, Self.panelPadding / 2)
            .padding(.vertical, Self.panelPadding)
        }

        /// The ramp choices on a drum inside the camera popups' own panel.
        private func rampPopup(_ presets: MonitorZoomPresetControls) -> some View {
            let place = rampPlace
            let current = MonitorZoomPresets.rampLabel(presets.presets.rampSeconds)
            let options = MonitorZoomPresets.rampChoices.map(MonitorZoomPresets.rampLabel)
            return ZStack(alignment: .topLeading) {
                Color.black.opacity(0.001)
                    .frame(width: viewport.width, height: viewport.height)
                    .onTapGesture { rampOpen = false }
                    .accessibilityHidden(true)
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    MonitorCapturePanel(
                        title: "Preset ramp", subtitle: current,
                        maximumHeight: CGFloat(place.maximumHeight),
                        bottomPadding: CGFloat(place.bottomPadding), topPadding: CGFloat(place.topPadding),
                        topCornerRadius: CGFloat(place.topCornerRadius),
                        bottomCornerRadius: CGFloat(place.bottomCornerRadius),
                        edge: .bottom, close: { rampOpen = false }
                    ) {
                        MonitorValueDrum(
                            options: options,
                            selection: Binding(get: { current }, set: { label in
                                guard let index = options.firstIndex(of: label) else { return }
                                presets.onRamp(MonitorZoomPresets.rampChoices[index])
                            }), haptics: haptics)
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("monitor.zoom.ramp.panel")
                }
                .frame(width: CGFloat(place.width), height: CGFloat(place.bottom), alignment: .bottom)
                .offset(x: CGFloat(place.centerX - place.width / 2))
            }
            .frame(width: viewport.width, height: viewport.height, alignment: .topLeading)
        }

        private var rulerBody: some View {
            ZStack(alignment: .topTrailing) {
                Self.rulerShape.fill(.white.opacity(0.06))
                    .frame(width: Self.rulerWidth)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                Self.canvas(canvasSnapshot)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($pointerActive) { _, active, _ in active = true }
                    .onChanged { gesture in
                        guard acceptsInput else {
                            cancelPointer()
                            return
                        }
                        if drag.begin(at: value) {
                            origin = value
                            onEditing(true)
                        }
                        guard drag.anchor != nil, let origin else { return }
                        // Below the tap threshold the scale stays put, as on the other dials.
                        guard hypot(gesture.translation.width, gesture.translation.height) >= Self.tapTravel
                            || scrub != nil
                        else { return }
                        move(to: ruler.dragged(from: origin, translation: Double(gesture.translation.height)))
                    }
                    .onEnded { gesture in
                        if acceptsInput, drag.anchor != nil, scrub == nil,
                            hypot(gesture.translation.width, gesture.translation.height) < Self.tapTravel
                        {
                            let center = rulerHeight / 2
                            move(to: ruler.tapped(
                                atOffset: Double(gesture.startLocation.y - center), center: shown))
                        }
                        finishEditing()
                    }
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Zoom")
            .accessibilityValue(
                [MonitorZoomRulerScale.readout(shown), caption].filter { !$0.isEmpty }
                    .joined(separator: ", "))
            .accessibilityAdjustableAction { direction in
                guard acceptsInput else { return }
                let step = direction == .increment ? MonitorZoomRulerScale.step : -MonitorZoomRulerScale.step
                onEditing(true)
                value = ruler.quantized(value + step)
                onEditing(false)
            }
            .accessibilityIdentifier("monitor.zoom.dial")
        }

        /// Shows `next` under the center line and sends it live, with a tick per new step.
        private func move(to next: Double) {
            guard next != shown || scrub == nil else { return }
            if MonitorZoomRulerScale.tick(next) != MonitorZoomRulerScale.tick(shown) { stepTick += 1 }
            scrub = next
            value = next
        }

        private func finishEditing() {
            scrub = nil
            origin = nil
            if drag.end() { onEditing(false) }
        }

        private func cancelPointer() {
            guard pointerActive || drag.anchor != nil else { return }
            scrub = nil
            origin = nil
            if drag.cancel() { onEditing(false) }
        }

        /// Freeze native value and label projections before SwiftUI dispatches the Canvas
        /// renderer. The drawing snapshot contains no session callbacks.
        var canvasSnapshot: MonitorZoomCanvasSnapshot {
            let center = shown
            let halfSpan = max(0, Double(rulerHeight / 2 - Self.endInset))
            let ticks = ruler.ticks(center: center, halfSpan: halfSpan)
            let opticalMaximum = opticalStops.max() ?? scale.minimum
            return MonitorZoomCanvasSnapshot(
                width: Self.rulerWidth, gutter: Self.labelGutter, inset: Self.endInset,
                ticks: ticks,
                labels: ticks.filter { $0.kind == .major }.map {
                    MonitorZoomCanvasMark(value: $0.value, offset: $0.offset, label: label($0.value))
                },
                center: center, halfSpan: halfSpan, opticalMaximum: opticalMaximum,
                opticalStops: opticalStops, ink: ink, digitalInk: MonitorTheme.digitalCrop,
                secondaryInk: MonitorTheme.secondary,
                labelFont: MonitorTheme.font(12, weight: .semibold))
        }

        nonisolated static func canvas(_ snapshot: MonitorZoomCanvasSnapshot) -> Canvas<EmptyView> {
            Canvas { context, size in
                let left = size.width - snapshot.width
                let mid = size.height / 2
                func y(_ offset: Double) -> CGFloat { mid + CGFloat(offset) }
                /// Ticks fade over the last 40 pt before the capsule's ends.
                func fade(_ offset: Double) -> Double {
                    guard snapshot.halfSpan > 0 else { return 1 }
                    return min(1, max(0, (snapshot.halfSpan - abs(offset)) / 40))
                }
                for tick in snapshot.ticks {
                    let (from, to, weight, alpha): (CGFloat, CGFloat, CGFloat, Double) =
                        switch tick.kind {
                        case .major: (0.30, 0.88, 2, 0.9)
                        case .mid: (0.45, 0.88, 1.5, 0.6)
                        case .minor: (0.62, 0.88, 1, 0.32)
                        }
                    let optical = snapshot.opticalStops.contains { abs($0 - tick.value) < 0.001 }
                    let digital = tick.value > snapshot.opticalMaximum + 0.02
                    let color: Color = optical ? snapshot.ink : digital ? snapshot.digitalInk : .white
                    var path = Path()
                    path.move(to: CGPoint(x: left + snapshot.width * from, y: y(tick.offset)))
                    path.addLine(to: CGPoint(x: left + snapshot.width * to, y: y(tick.offset)))
                    context.stroke(
                        path, with: .color(color.opacity((optical ? 1 : alpha) * fade(tick.offset))),
                        lineWidth: weight)
                }
                for mark in snapshot.labels {
                    let color =
                        mark.value > snapshot.opticalMaximum + 0.02
                        ? snapshot.digitalInk : snapshot.secondaryInk
                    context.draw(
                        Text(mark.label).font(snapshot.labelFont)
                            .foregroundStyle(color.opacity(fade(mark.offset))),
                        at: CGPoint(x: left - 6, y: y(mark.offset)), anchor: .trailing)
                }
                // The fixed center line the scale slides under.
                var marker = Path()
                marker.move(to: CGPoint(x: left + 4, y: mid))
                marker.addLine(to: CGPoint(x: left + snapshot.width - 4, y: mid))
                context.stroke(
                    marker, with: .color(snapshot.ink),
                    style: StrokeStyle(lineWidth: 3, lineCap: .round))
            }
        }
    }

    struct MonitorZoomCanvasMark: Sendable {
        let value: Double
        let offset: Double
        let label: String
    }

    struct MonitorZoomCanvasSnapshot: Sendable {
        let width: CGFloat
        let gutter: CGFloat
        let inset: CGFloat
        let ticks: [MonitorZoomRulerTick]
        let labels: [MonitorZoomCanvasMark]
        /// The value under the center line.
        let center: Double
        /// Points from the center line to the last drawn tick.
        let halfSpan: Double
        let opticalMaximum: Double
        let opticalStops: [Double]
        let ink: Color
        let digitalInk: Color
        let secondaryInk: Color
        let labelFont: Font
    }
#endif
