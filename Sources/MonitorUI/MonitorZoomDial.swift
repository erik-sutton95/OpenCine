#if os(iOS)
    import MonitorPresentation
    import SwiftUI

    /// The zoom control: a slim vertical ruler on the trailing edge with the presets beside it.
    /// Drag anywhere on the ruler to move in 0.1x steps. Camera adapters own continuous write
    /// coalescing and final settlement; opening the ruler and drawing it never issue commands.
    /// Kotlin twin: `MonitorZoomRuler` (monitor-ui).
    public struct MonitorZoomDial: View {
        static let rulerWidth: CGFloat = 44
        static let edgeMargin: CGFloat = 12
        /// Room left of the ruler for the whole-step labels.
        static let labelGutter: CGFloat = 34
        /// Keeps the end ticks off the capsule's rounded ends.
        static let endInset: CGFloat = 16

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
        @Binding private var value: Double
        @State private var drag = MonitorZoomDrag()
        @GestureState private var pointerActive = false
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @Environment(\.scenePhase) private var scenePhase
        @Environment(\.monitorHDRChromeGain) private var hdrGain
        @State private var appeared = false
        @State private var stepTick = 0

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
            haptics: Bool = true, presets: MonitorZoomPresetControls? = nil
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
        }

        /// The ruler's capsule in viewport coordinates.
        var rulerFrame: CGRect {
            let trailing = viewport.width - max(0, safeArea.trailing) - Self.edgeMargin
            let top = max(topClearance, safeArea.top + Self.edgeMargin)
            let bottom = viewport.height - max(bottomClearance, safeArea.bottom + Self.edgeMargin)
            return CGRect(
                x: trailing - Self.rulerWidth, y: top,
                width: Self.rulerWidth, height: max(0, bottom - top))
        }

        var ruler: MonitorZoomRulerScale {
            MonitorZoomRulerScale(
                minimum: scale.minimum, maximum: scale.maximum,
                length: Double(max(0, rulerFrame.height - Self.endInset * 2)))
        }

        private var ink: Color {
            opticalStops.contains { abs($0 - value) < 0.05 }
                ? MonitorTheme.edrAccent(gain: hdrGain) : MonitorTheme.digitalCrop
        }

        private var visible: Bool { appeared && isPresented }
        private var acceptsInput: Bool { visible && scenePhase == .active }

        public var body: some View {
            let frame = rulerFrame
            ZStack(alignment: .topLeading) {
                Button(action: onClose) {
                    Color.clear.contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close zoom")
                .frame(width: viewport.width, height: viewport.height)

                rulerBody
                    .frame(width: frame.width + Self.labelGutter, height: frame.height)
                    .offset(x: frame.minX - Self.labelGutter, y: frame.minY)
                    .offset(x: visible || reduceMotion ? 0 : 24)
                    .opacity(visible ? 1 : 0)
                    .animation(
                        visible ? MonitorMotion.discIn(reduceMotion) : MonitorMotion.discOut(reduceMotion),
                        value: visible)

                side
                    .frame(width: max(0, frame.minX - Self.labelGutter - 10), height: frame.height, alignment: .trailing)
                    .offset(y: frame.minY)
                    .opacity(visible ? 1 : 0)
                    .animation(MonitorMotion.dim(reduceMotion), value: visible)
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
            .sensoryFeedback(.impact(weight: .light), trigger: stepTick) { _, _ in
                haptics && acceptsInput && stepTick > 0
            }
            .onDisappear {
                cancelPointer()
                appeared = false
            }
        }

        /// The value readout over the preset column, both left of the ruler and centered on it.
        private var side: some View {
            VStack(alignment: .trailing, spacing: 14) {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(MonitorZoomRulerScale.readout(value))
                        .font(MonitorTheme.font(22, weight: .bold)).monospacedDigit()
                        .foregroundStyle(MonitorTheme.edrText(gain: hdrGain))
                    if !caption.isEmpty {
                        Text(caption).font(MonitorTheme.font(10, weight: .semibold)).tracking(1.2)
                            .foregroundStyle(ink)
                    }
                }
                .lineLimit(1).minimumScaleFactor(0.7)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                if let presets {
                    MonitorZoomPresetStrip(
                        controls: presets, maximum: scale.maximum, vertical: true,
                        label: label, haptics: haptics)
                }
            }
        }

        private var rulerBody: some View {
            ZStack(alignment: .topTrailing) {
                Color.clear
                    .frame(width: Self.rulerWidth)
                    .monitorGlass(in: Capsule(), density: .zoom)
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
                        if drag.begin(at: value) { onEditing(true) }
                        guard drag.anchor != nil else { return }
                        let next = ruler.value(atOffset: Double(gesture.location.y - Self.endInset))
                        guard next != value else { return }
                        if ruler.quantized(next) != ruler.quantized(value) { stepTick += 1 }
                        value = next
                    }
                    .onEnded { _ in finishEditing() }
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Zoom")
            .accessibilityValue(
                [MonitorZoomRulerScale.readout(value), caption].filter { !$0.isEmpty }
                    .joined(separator: ", "))
            .accessibilityAdjustableAction { direction in
                guard acceptsInput else { return }
                let step = direction == .increment ? MonitorZoomRulerScale.step : -MonitorZoomRulerScale.step
                onEditing(true)
                value = ruler.quantized(ruler.quantized(value) + step)
                onEditing(false)
            }
            .accessibilityIdentifier("monitor.zoom.dial")
        }

        private func finishEditing() {
            if drag.end() { onEditing(false) }
        }

        private func cancelPointer() {
            guard pointerActive || drag.anchor != nil else { return }
            if drag.cancel() { onEditing(false) }
        }

        /// Freeze native value and label projections before SwiftUI dispatches the Canvas
        /// renderer. The drawing snapshot contains no session callbacks.
        var canvasSnapshot: MonitorZoomCanvasSnapshot {
            let ruler = ruler
            let ticks = ruler.ticks
            let opticalMaximum = opticalStops.max() ?? scale.minimum
            return MonitorZoomCanvasSnapshot(
                width: Self.rulerWidth, gutter: Self.labelGutter, inset: Self.endInset,
                ticks: ticks,
                labels: ticks.filter { $0.kind == .major }.map {
                    MonitorZoomCanvasMark(value: $0.value, offset: $0.offset, label: label($0.value))
                },
                current: ruler.offset(for: value), opticalMaximum: opticalMaximum,
                opticalStops: opticalStops, ink: ink, digitalInk: MonitorTheme.digitalCrop,
                secondaryInk: MonitorTheme.secondary,
                labelFont: MonitorTheme.font(12, weight: .semibold))
        }

        nonisolated static func canvas(_ snapshot: MonitorZoomCanvasSnapshot) -> Canvas<EmptyView> {
            Canvas { context, size in
                let left = size.width - snapshot.width
                func y(_ offset: Double) -> CGFloat { snapshot.inset + CGFloat(offset) }
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
                        path, with: .color(color.opacity(optical ? 1 : alpha)), lineWidth: weight)
                }
                for mark in snapshot.labels {
                    let color =
                        mark.value > snapshot.opticalMaximum + 0.02
                        ? snapshot.digitalInk : snapshot.secondaryInk
                    context.draw(
                        Text(mark.label).font(snapshot.labelFont).foregroundStyle(color),
                        at: CGPoint(x: left - 6, y: y(mark.offset)), anchor: .trailing)
                }
                var marker = Path()
                marker.move(to: CGPoint(x: left + 6, y: y(snapshot.current)))
                marker.addLine(to: CGPoint(x: left + snapshot.width - 6, y: y(snapshot.current)))
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
        let current: Double
        let opticalMaximum: Double
        let opticalStops: [Double]
        let ink: Color
        let digitalInk: Color
        let secondaryInk: Color
        let labelFont: Font
    }
#endif
