#if os(iOS)
import MonitorPresentation
import MonitorUI
import SwiftUI

/// The recording-category, capture drawer and held-readout preview share one live placement.
/// Frequent camera reports are read here, below the stable native picture and monitor chrome.
public struct MonitorOperatorCaptureOverlays<Host: LiveChromeHost>: View {
    @Environment(Host.self) private var host
    private let layout: LiveMonitorLayout
    private let interaction: MonitorOperatorInteraction
    private let topFrames: [LiveTopMenu: CGRect]
    private let captureFrames: [CaptureSheet: CGRect]

    public init(layout: LiveMonitorLayout, interaction: MonitorOperatorInteraction,
        topFrames: [LiveTopMenu: CGRect], captureFrames: [CaptureSheet: CGRect]) {
        self.layout = layout; self.interaction = interaction
        self.topFrames = topFrames; self.captureFrames = captureFrames
    }

    private var interactive: Bool { !host.isEditingChrome && !host.operatorSession.locked }
    private var captureCeiling: CGFloat {
        max(layout.safeArea.top + LivePopupPlacement.assistTopInset, LivePopupPlacement.edgeMargin)
    }
    private var captureBottom: CGFloat {
        layout.presentation?.portrait == true ? layout.rail.minY - 12 : layout.viewport.height
    }
    private var topFloor: CGFloat? {
        layout.showsBottomBars ? min(layout.assist.minY, layout.capture.minY) - LiveChromeMetrics.popupGap : nil
    }
    private var navigation: [CGRect] {
        guard layout.presentation?.portrait == true, host.captureDrum == nil else { return [] }
        var frames: [CGRect] = []
        if host.chromeSectionMounts(.railSettings) || host.cameraStatus.isRecording { frames.append(layout.settings) }
        if host.chromeSectionMounts(.railMedia), !host.multiviewBorrowed { frames.append(layout.media) }
        return frames
    }

    public var body: some View {
        if interactive {
            if host.chromeSectionMounts(.statusBar), interaction.topMenu != nil {
                LiveTopSheetHost<Host>(menu: Bindable(interaction).topMenu, frames: topFrames,
                    viewport: layout.viewport, topDeck: layout.topDeck, safeArea: layout.safeArea,
                    floorY: topFloor)
            }
            CaptureSheetPickerHost<Host>(sheet: Bindable(host).captureSheet,
                frames: captureFrames, passthroughFrames: navigation, bar: layout.capture,
                viewport: layout.viewport, safeArea: layout.safeArea, ceilingY: captureCeiling,
                bottomY: captureBottom, topDeckMaxY: layout.topDeck.maxY)
            if host.captureDrum != nil {
                CaptureSheetDrumHost<Host>(viewport: layout.viewport, safeArea: layout.safeArea,
                    ceilingY: captureCeiling, bottomY: captureBottom, topDeckMaxY: layout.topDeck.maxY)
            }
        }
    }
}

/// Camera supplied range, optical landmarks and wording; the common dial owns the edit origin.
@MainActor public struct MonitorOperatorZoomPresentation {
    public let maximum: Double
    public let opticalStops: [Double]
    public let caption: String
    public let readValue: () -> Double
    public let readOrigin: () -> Double
    public let label: (Double) -> String

    public init(maximum: Double, opticalStops: [Double], caption: String,
        readValue: @escaping () -> Double, readOrigin: @escaping () -> Double,
        label: @escaping (Double) -> String) {
        self.maximum = maximum; self.opticalStops = opticalStops; self.caption = caption
        self.readValue = readValue; self.readOrigin = readOrigin; self.label = label
    }
}

public struct MonitorOperatorZoomDial<Host: LiveChromeHost>: View {
    @Environment(Host.self) private var host
    private let layout: LiveMonitorLayout
    private let interaction: MonitorOperatorInteraction
    private let source: MonitorOperatorZoomPresentation
    private let onClose: () -> Void
    @State private var gestureOrigin = 1.0
    @State private var presets = MonitorZoomPresets()
    @State private var ramp: Task<Void, Never>?
    /// A preset ramp holds the host's continuous zoom edit until it ends or is overridden.
    @State private var rampHoldsEdit = false

    public init(layout: LiveMonitorLayout, interaction: MonitorOperatorInteraction,
        source: MonitorOperatorZoomPresentation, onClose: @escaping () -> Void) {
        self.layout = layout; self.interaction = interaction; self.source = source; self.onClose = onClose
    }

    public var body: some View {
        MonitorZoomDial(viewport: layout.viewport, safeArea: layout.safeArea,
            bottomClearance: clearance.bottom, topClearance: clearance.top,
            isPresented: interaction.zoomVisible,
            scale: MonitorZoomScale(minimum: 1, maximum: source.maximum),
            opticalStops: source.opticalStops, caption: source.caption,
            value: Binding(get: { source.readValue() }, set: {
                host.updateZoomPinch(magnification: $0 / max(1, gestureOrigin))
            }), label: source.label, onEditing: { editing in
                if editing {
                    stopRamp()
                    host.zoomPinchWillBegin()
                    gestureOrigin = source.readOrigin()
                } else { host.endZoomPinch() }
            }, onClose: onClose, haptics: host.hapticsEnabled,
            presets: MonitorZoomPresetControls(presets: presets, onSelect: select, onSave: { index in
                var next = presets
                next.save(source.readValue(), at: index)
                store(next)
            }, onRamp: { seconds in
                var next = presets
                next.setRamp(seconds)
                store(next)
            }))
            .frame(width: layout.viewport.width, height: layout.viewport.height, alignment: .topLeading)
            .onAppear { presets = host.zoomPresetStore.presets }
            .onDisappear { stopRamp() }
    }

    /// Portrait: from under the status row to above the capture bar. Landscape: edge to edge
    /// inside the safe area.
    private var clearance: (top: CGFloat, bottom: CGFloat) {
        let portrait = layout.presentation?.portrait ?? (layout.viewport.height > layout.viewport.width)
        let edge: CGFloat = 12
        guard portrait else {
            return (max(layout.safeArea.top, edge), max(layout.safeArea.bottom, edge))
        }
        let top = layout.topDeck.height > 1 ? layout.topDeck.maxY + 8 : layout.safeArea.top + edge
        let floors = [layout.capture, layout.rail].filter { $0.height > 1 }.map(\.minY)
        let bottom = layout.showsBottomBars && !floors.isEmpty
            ? layout.viewport.height - (floors.min()! - edge) : layout.safeArea.bottom + edge
        return (top, bottom)
    }

    private func store(_ next: MonitorZoomPresets) {
        presets = next
        host.zoomPresetStore.presets = next
    }

    /// Moves to a preset through the same continuous zoom edit as the dial, sampled from
    /// Motion Control's linear ramp. Touching the dial or closing it stops the ramp there.
    private func select(_ index: Int) {
        guard let target = presets.target(at: index, maximum: source.maximum) else { return }
        stopRamp()
        let plan = MonitorZoomPresetRamp(from: source.readValue(), to: target, duration: presets.rampSeconds)
        host.zoomPinchWillBegin()
        let origin = max(1, source.readOrigin())
        rampHoldsEdit = true
        ramp = Task { @MainActor in
            let clock = ContinuousClock()
            let start = clock.now
            while !Task.isCancelled {
                let elapsed = clock.now - start
                let seconds = Double(elapsed.components.seconds)
                    + Double(elapsed.components.attoseconds) / 1e18
                host.updateZoomPinch(magnification: plan.factor(at: seconds) / origin)
                if plan.isFinished(at: seconds) { break }
                try? await Task.sleep(for: .seconds(MonitorZoomPresetRamp.interval))
            }
            guard !Task.isCancelled else { return }
            ramp = nil
            releaseRampEdit()
        }
    }

    private func stopRamp() {
        ramp?.cancel()
        ramp = nil
        releaseRampEdit()
    }

    private func releaseRampEdit() {
        guard rampHoldsEdit else { return }
        rampHoldsEdit = false
        host.endZoomPinch()
    }
}
#endif
