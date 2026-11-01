#if os(iOS)
import MetalKit
import MonitorPresentation
import MonitorUI
import OpenCineAppKit
import OpenCineMedia
import SwiftUI

extension MonitorAssistSelection {
    /// The view assists a still offers, in the playback bar's order. Geometry (DE-SQ, MIRROR,
    /// GUIDES, GRID, CROSS) is drawn by the page, the scopes read the still itself and the picture
    /// assists (PEAK, FALSE, ZEBRA) paint it. LUT stays off: the assist cubes convert a camera's
    /// log curve and a still is a display-referred Rec.709 picture. ND, AUDIO, LEVEL and the EV
    /// meter have nothing to read in a still.
    public static var photoToolbarCases: [MonitorAssistSelection] {
        let still: Set<MonitorAssistSelection> = [.peaking, .falseColor, .zebra, .waveform, .parade,
            .histogram, .vectorscope, .trafficLights, .guides, .grid, .crosshair, .desqueeze, .mirror]
        return playbackToolbarCases.filter(still.contains)
    }

    /// The media pages' scopes; each needs the app's panel stores and a sample to read.
    static let mediaScopes: Set<MonitorAssistSelection> = [.waveform, .parade, .histogram,
        .vectorscope, .trafficLights, .ndMeter]
}

/// Which tools of a media page open options: the same rule for clip playback and stills.
enum MonitorMediaAssistOptions {
    static func hasOptions(_ tool: MonitorAssistSelection, stores: Bool,
        signalOptions: MonitorOperatorSignalOptions) -> Bool {
        let stored: Set<MonitorAssistSelection> = [.zebra, .waveform, .parade, .histogram,
            .vectorscope, .trafficLights, .ndMeter, .audioMeters]
        return tool.hasConfiguration && (stores || !stored.contains(tool)
            || (tool == .zebra && signalOptions.zebra != nil))
    }
}

/// The view assist bar of the media pages, clip playback and stills alike: the field monitor
/// palette at the field monitor's place. A tap toggles a tool for playback; a hold opens its
/// options. `onFrame` reports the bar's global frame, the anchor of option popups.
struct MonitorMediaAssistBar<Looks: MonitorLookProvider>: View {
    let assist: MonitorAssistState<Looks>
    let tools: [MonitorAssistSelection]
    let hasOptions: (MonitorAssistSelection) -> Bool
    @Binding var usage: MonitorToolUsage
    let presentation: FieldMonitorLayout
    let safeTop: CGFloat
    let expanded: Binding<Bool>
    let onFrame: (CGRect) -> Void
    let onOptions: (MonitorAssistSelection) -> Void

    var body: some View {
        let (metrics, placed) = MonitorAssistPaletteLayout.fieldMonitor(presentation,
            toolCount: tools.count, safeTop: safeTop)
        MonitorAssistPalette(tools: tools.map { .init(id: $0.rawValue, title: $0.rawValue,
                enabled: assist.isPlaybackVisible($0), hasOptions: hasOptions($0), accessibilityLabel: $0.title) },
            layout: metrics, usageSeed: MonitorToolUsage.fieldMonitorSeed, usage: $usage,
            expanded: expanded, onToggle: { if let tool = MonitorAssistSelection(rawValue: $0) { assist.togglePlayback(tool) } },
            onOptions: { if let tool = MonitorAssistSelection(rawValue: $0) { onOptions(tool) } }) { id in
                if let tool = MonitorAssistSelection(rawValue: id), let glyph = tool.sharedTool { MonitorAssistToolGlyph(tool: glyph, size: nil) }
            }
            .background { GeometryReader { proxy in
                Color.clear.onAppear { onFrame(proxy.frame(in: .global)) }
                    .onChange(of: proxy.frame(in: .global)) { _, value in onFrame(value) }
            } }
            .position(x: placed.midX, y: placed.midY)
            .frame(width: presentation.viewport.width, height: presentation.viewport.height, alignment: .topLeading)
            .onAppear { onFrame(placed.cgRect) }
    }
}

/// Guides, grid, crosshair and the LUT split marks over a media page's picture frame.
struct MonitorMediaFeedMarks<Looks: MonitorLookProvider>: View {
    let assist: MonitorAssistState<Looks>?
    let rect: CGRect

    var body: some View {
        ZStack {
            if let assist {
                if assist.isPlaybackVisible(.guides) { GuidesAssist.overlay(feed: rect, assist: assist, fallback: assist.guideAspect) }
                if assist.isPlaybackVisible(.grid) { MonitorFeedGrid(feed: rect, thirds: assist.gridThirds, phi: assist.gridPhi, diagonal: assist.gridDiagonal) }
                if assist.isPlaybackVisible(.crosshair) { MonitorFeedCrosshair(feed: rect) }
                if assist.splitComparison, assist.isPlaybackVisible(.lut) { MonitorFeedComparisonMarks(vertical: assist.splitVertical, feed: rect) }
            }
        }.allowsHitTesting(false)
    }
}
/// The scopes and the false colour key over a media page's canvas, clip playback and stills alike.
struct MonitorMediaSignalOverlays<Looks: MonitorLookProvider>: View {
    /// Room the page chrome keeps clear of the scope panels.
    static var clearance: EdgeInsets { EdgeInsets(top: 56, leading: 56, bottom: 110, trailing: 56) }
    let assist: MonitorAssistState<Looks>
    let stores: AssistPanelStores
    let looks: FalseColorLooks
    let haptics: OperatorHaptics
    let canvas: CGRect
    let feed: CGRect
    let tools: [MonitorAssistSelection]
    let readScopes: (() -> ScopeAssistBundle)?
    let configureDisplay: @MainActor (MTKView) -> MonitorScopeDisplayOptions
    let paradeIntensityScale: Double
    /// The picture's curve; nil keeps the false colour key away.
    let transfer: MonitorTransfer?
    let clipByte: Int
    let signalOptions: MonitorOperatorSignalOptions
    let onConfigure: (MonitorAssistSelection) -> Void

    var body: some View {
        if let readScopes {
            MonitorScopeOverlays(assist: assist, stores: stores, haptics: haptics, canvas: canvas,
                feed: feed, chromeClearance: Self.clearance, readBundle: readScopes,
                configureDisplay: configureDisplay, playback: true, available: Set(tools),
                paradeIntensityScale: paradeIntensityScale)
        }
        if assist.isPlaybackVisible(.falseColor), tools.contains(.falseColor), assist.falseColorReference,
            signalOptions.referenceAvailable != false, let transfer {
            FalseColorReferenceOverlay(stores: stores, looks: looks, scale: assist.falseColorScale,
                transfer: transfer, rec709: assist.falseColorRec709, clipByte: clipByte, bounds: canvas,
                chromeClearance: Self.clearance, hapticsEnabled: haptics.isEnabled(),
                onConfigure: { onConfigure(.falseColor) }, referenceValues: signalOptions.reference)
        }
    }
}
#endif
