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

    public init(layout: LiveMonitorLayout, interaction: MonitorOperatorInteraction,
        source: MonitorOperatorZoomPresentation, onClose: @escaping () -> Void) {
        self.layout = layout; self.interaction = interaction; self.source = source; self.onClose = onClose
    }

    public var body: some View {
        MonitorZoomDial(viewport: layout.viewport, safeArea: layout.safeArea,
            attachment: (layout.presentation?.portrait ?? (layout.viewport.height > layout.viewport.width)) ? .bottom : .trailing,
            bottomClearance: 0, isPresented: interaction.zoomVisible,
            scale: MonitorZoomScale(minimum: 1, maximum: source.maximum),
            marks: Array(Set([1, 1.5, 2, 4, 6, 9] + host.zoomStops)).sorted(),
            opticalStops: source.opticalStops, caption: source.caption,
            value: Binding(get: { source.readValue() }, set: {
                host.updateZoomPinch(magnification: $0 / max(1, gestureOrigin))
            }), label: source.label, onEditing: { editing in
                if editing {
                    host.zoomPinchWillBegin()
                    gestureOrigin = source.readOrigin()
                } else { host.endZoomPinch() }
            }, onClose: onClose, haptics: host.hapticsEnabled)
            .frame(width: layout.viewport.width, height: layout.viewport.height, alignment: .topLeading)
    }
}
#endif
