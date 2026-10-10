#if os(iOS)
import MonitorPresentation
import MonitorUI
import OpenCineAppKit
import OpenCineMedia
import SwiftUI

public typealias MonitorWatcherTapAction = @MainActor (CGPoint) -> MonitorWatcherFocus?

/// Complete shared watcher assembly. Native picture, inspector bitmap and look catalogue are leaves.
public struct MonitorOperatorWatcherScreen<Host: LiveChromeHost, Picture: View, Preview: View,
    LookMenu: View>: View {
    private let host: Host
    private let value: MonitorWatcherPresentation
    private let pictureSize: CGSize
    private let mirrored: Bool
    private let confirmRecording: Bool
    private let assists: MonitorOperatorLiveAssistSource
    private let action: (MonitorWatcherAction) -> Void
    private let readTapSource: @MainActor () -> MonitorWatcherTapSource
    private let capturedTapAction: @MainActor (CGSize) -> MonitorWatcherTapAction
    private let onGeometry: (MonitorWatcherPictureGeometry) -> Void
    private let picture: (MonitorFrameEffects) -> Picture
    private let preview: (MonitorAssistSelection) -> Preview
    private let lookMenu: () -> LookMenu
    @State private var clean = false
    @State private var interaction = MonitorWatcherInteraction()

    public init(host: Host, value: MonitorWatcherPresentation, pictureSize: CGSize, mirrored: Bool,
        confirmRecording: Bool, assists: MonitorOperatorLiveAssistSource,
        action: @escaping (MonitorWatcherAction) -> Void,
        readTapSource: @escaping @MainActor () -> MonitorWatcherTapSource,
        capturedTapAction: @escaping @MainActor (CGSize) -> MonitorWatcherTapAction,
        onGeometry: @escaping (MonitorWatcherPictureGeometry) -> Void,
        @ViewBuilder picture: @escaping (MonitorFrameEffects) -> Picture,
        @ViewBuilder preview: @escaping (MonitorAssistSelection) -> Preview,
        @ViewBuilder lookMenu: @escaping () -> LookMenu) {
        self.host = host; self.value = value; self.pictureSize = pictureSize; self.mirrored = mirrored
        self.confirmRecording = confirmRecording; self.assists = assists; self.action = action
        self.readTapSource = readTapSource; self.capturedTapAction = capturedTapAction
        self.onGeometry = onGeometry; self.picture = picture; self.preview = preview; self.lookMenu = lookMenu
    }

    public var body: some View {
        GeometryReader { proxy in
            let viewport = CGRect(origin: .zero, size: proxy.size)
            let raster = pictureSize.width > 0 ? pictureSize : CGSize(width: 1280, height: 720)
            let feed = DesqueezeAssist.presentationRect(sourceSize: raster, in: viewport, effects: host.assist.effects)
            let bottom = max(proxy.safeAreaInsets.bottom, 10)
            let source = value.context.tapSource
            let tap = capturedTapAction(feed.size)
            let geometry = MonitorWatcherPictureGeometry(source: source,
                viewport: .init(x: 0, y: 0, width: Double(viewport.width), height: Double(viewport.height)),
                feed: .init(x: Double(feed.minX), y: Double(feed.minY), width: Double(feed.width), height: Double(feed.height)),
                bottomClearance: Double(bottom), mirrored: mirrored)
            ZStack {
                Color.black.ignoresSafeArea()
                picture(host.assist.effects)
                    .frame(width: feed.width, height: feed.height)
                    .contentShape(Rectangle())
                    .overlay {
                        Color.clear.contentShape(Rectangle())
                            .gesture(SpatialTapGesture().onEnded { location in
                                if let focus = tap(location.location) {
                                    interaction.applyFocus(focus, current: readTapSource())
                                }
                            })
                            .id(source)
                    }
                    .position(x: feed.midX, y: feed.midY)
                marks(feed: feed)
                if !clean {
                    MonitorScopeOverlays(assist: host.assist, stores: assists.stores, haptics: assists.haptics,
                        canvas: viewport, feed: feed,
                        chromeClearance: .init(top: 100, leading: 14, bottom: bottom + 104, trailing: 14),
                        readBundle: assists.readBundle, configureDisplay: assists.configureDisplay)
                }
                MonitorWatcherChrome(value: value, clean: Binding(get: { clean }, set: {
                    host.assist.configureTool = nil; clean = $0
                }), confirmRecording: confirmRecording, palette: Host.Palette.self, action: action) {
                    MonitorWatcherToolStrip(assist: host.assist, palette: Host.Palette.self,
                        haptics: assists.haptics, showsAudio: false)
                }
                .padding(.horizontal, 14).padding(.top, max(proxy.safeAreaInsets.top, 10)).padding(.bottom, bottom)
                if !clean, let tool = host.assist.configureTool, tool != .audioMeters {
                    inspector(tool: tool, viewport: proxy.size, safeArea: proxy.safeAreaInsets)
                }
            }
            .coordinateSpace(name: LiveCanvasSpace.name)
            .onChange(of: geometry, initial: true) { _, measured in onGeometry(measured) }
        }
        .environment(host)
        .ignoresSafeArea().preferredColorScheme(.dark).statusBarHidden(true)
        .onChange(of: value.context.tapSource) { _, _ in interaction.retireFocus(current: readTapSource()) }
        .onDisappear { host.assist.configureTool = nil; interaction.cancel() }
    }

    private func marks(feed: CGRect) -> some View {
        let point = interaction.focus.map { CGPoint(x: $0.x, y: $0.y) }
        return FeedAssistMarks<Host>(grid: host.assist.isVisible(.grid), crosshair: host.assist.isVisible(.crosshair),
            guides: host.assist.isVisible(.guides), guideAspect: host.assist.guideAspect,
            focusPoint: point ?? .init(x: 0.5, y: 0.5), showFocusChrome: point != nil && value.context.canControl,
            feed: feed, pictureMirrored: mirrored)
    }
    private func inspector(tool: MonitorAssistSelection, viewport: CGSize, safeArea: EdgeInsets) -> some View {
        let transfer = assists.readTransfer()
        return MonitorOperatorAssistInspector(tool: tool, assist: host.assist, stores: assists.stores,
            looks: assists.looks, palette: Host.Palette.self, haptics: assists.haptics,
            transfer: transfer, clipByte: assists.readClipByte(transfer), viewport: viewport, safeArea: safeArea,
            onDismiss: { host.assist.configureTool = nil }, preview: preview, lookMenu: lookMenu)
    }
}
#endif
