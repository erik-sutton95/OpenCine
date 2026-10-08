#if os(iOS)
import MetalKit
import MonitorPresentation
import MonitorUI
import OpenCineAppKit
import OpenCineAppKitApple
import OpenCineCameraVocabulary
import OpenCineCore
import OpenCineMedia
import SwiftUI

/// Stable source facts used to lay out the operator surface. Unknown capabilities stay absent.
public struct MonitorOperatorLivePresentation {
    public let pictureAspect: Double
    public let pictureWaiting: Bool
    public let verticalPicture: Bool
    public let recovering: Bool
    public let zoom: Bool?
    public let gimbal: Bool?
    public let headTracking: Bool?
    public let watching: Bool

    public init(pictureAspect: Double, pictureWaiting: Bool, verticalPicture: Bool,
        recovering: Bool, zoom: Bool?, gimbal: Bool?, headTracking: Bool?, watching: Bool) {
        self.pictureAspect = pictureAspect; self.pictureWaiting = pictureWaiting
        self.verticalPicture = verticalPicture; self.recovering = recovering
        self.zoom = zoom; self.gimbal = gimbal; self.headTracking = headTracking; self.watching = watching
    }
}

/// Camera-coordinate focus observations. The surface owns projection, admission and cancel placement.
public struct MonitorOperatorFocusObservation {
    public let point: CGPoint
    public let overlay: FocusOverlay
    public let faces: [TrackingBox]
    public let resetAvailable: Bool
    public let supportsTapFocus: Bool?
    public let tracking: Bool
    public let search: TrackingBox?
    public let subject: TrackingBox?

    public init(point: CGPoint, overlay: FocusOverlay, faces: [TrackingBox], resetAvailable: Bool,
        supportsTapFocus: Bool?, tracking: Bool, search: TrackingBox?, subject: TrackingBox?) {
        self.point = point; self.overlay = overlay; self.faces = faces; self.resetAvailable = resetAvailable
        self.supportsTapFocus = supportsTapFocus; self.tracking = tracking; self.search = search; self.subject = subject
    }

    public var trackedSubject: TrackingBox? {
        if case .subject(let box) = FocusOverlayPolicy.resolve(tracking: tracking, search: search, subject: subject) { return box }
        return nil
    }
}

@MainActor public struct MonitorOperatorFocusSource {
    public let read: () -> MonitorOperatorFocusObservation
    public let cancelTracking: () -> Void
    public init(read: @escaping () -> MonitorOperatorFocusObservation, cancelTracking: @escaping () -> Void) {
        self.read = read; self.cancelTracking = cancelTracking
    }
}

/// One source supplies immutable samples and display facts; all scope and inspector UI is shared.
@MainActor public struct MonitorOperatorLiveAssistSource {
    public let stores: AssistPanelStores
    public let looks: FalseColorLooks
    public let haptics: OperatorHaptics
    public let readBundle: () -> ScopeAssistBundle
    public let readTransfer: () -> MonitorTransfer
    public let readClipByte: (MonitorTransfer) -> Int
    public let configureDisplay: @MainActor (MTKView) -> MonitorScopeDisplayOptions
    public let audioAvailable: Bool?
    public let configurableTools: Set<MonitorAssistSelection>?
    public let optionsUnavailableNotice: String?
    public let paradeIntensityScale: Double

    public init(stores: AssistPanelStores, looks: FalseColorLooks, haptics: OperatorHaptics,
        readBundle: @escaping () -> ScopeAssistBundle, readTransfer: @escaping () -> MonitorTransfer,
        readClipByte: @escaping (MonitorTransfer) -> Int,
        configureDisplay: @escaping @MainActor (MTKView) -> MonitorScopeDisplayOptions = { _ in .sdr },
        audioAvailable: Bool? = nil, configurableTools: Set<MonitorAssistSelection>? = nil,
        optionsUnavailableNotice: String? = nil, paradeIntensityScale: Double = 1) {
        self.stores = stores; self.looks = looks; self.haptics = haptics
        self.readBundle = readBundle; self.readTransfer = readTransfer; self.readClipByte = readClipByte
        self.configureDisplay = configureDisplay
        self.audioAvailable = audioAvailable; self.configurableTools = configurableTools
        self.optionsUnavailableNotice = optionsUnavailableNotice
        self.paradeIntensityScale = paradeIntensityScale
    }
}

/// Only the optional native photo operation varies; record confirmation and mode UI stay shared.
@MainActor public struct MonitorOperatorLiveCaptureSource {
    public let confirmRecording: Bool
    public let busy: () -> Bool
    public let takePhoto: () -> Void
    public init(confirmRecording: Bool, busy: @escaping () -> Bool, takePhoto: @escaping () -> Void) {
        self.confirmRecording = confirmRecording; self.busy = busy; self.takePhoto = takePhoto
    }
}

/// Optional motion input adapter. The common surface owns the button and diagnostic presentation.
@MainActor public struct MonitorOperatorHeadTrackingSource {
    public let enabled: Bool
    public let title: String
    public let readPose: () -> HeadTrackAxisPose?
    public let readIMU: () -> String
    public let calibrate: () -> Void
    public init(enabled: Bool, title: String, readPose: @escaping () -> HeadTrackAxisPose?,
        readIMU: @escaping () -> String, calibrate: @escaping () -> Void) {
        self.enabled = enabled; self.title = title; self.readPose = readPose
        self.readIMU = readIMU; self.calibrate = calibrate
    }
}

/// Full live chrome, camera drawers, assist/scopes, focus and optional motion assembly.
/// Native picture/inspector images and the coherent look catalogue are the only view seams.
public struct MonitorOperatorLiveSurface<Host: LiveChromeHost & GimbalPanelHost & GimbalStickHost,
    Picture: View, Preview: View, LookMenu: View>: View {
    private let host: Host
    private let layout: LiveMonitorLayout
    private let interaction: MonitorOperatorInteraction
    private let source: MonitorOperatorLivePresentation
    private let capture: MonitorOperatorLiveCaptureSource
    private let zoom: MonitorOperatorZoomPresentation
    private let focus: MonitorOperatorFocusSource
    private let assists: MonitorOperatorLiveAssistSource
    private let headTracking: MonitorOperatorHeadTrackingSource?
    private let readLevel: ((TimeInterval, Bool) -> MonitorLevelDisplay)?
    private let controlNote: Binding<String?>
    private let orientation: MonitorDeviceOrientation
    private let picture: () -> Picture
    private let preview: (MonitorAssistSelection) -> Preview
    private let lookMenu: () -> LookMenu
    @Binding private var portraitAspect: PortraitFeedAspect
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var topFrames: [LiveTopMenu: CGRect] = [:]
    @State private var captureFrames: [CaptureSheet: CGRect] = [:]

    public init(host: Host, layout: LiveMonitorLayout, interaction: MonitorOperatorInteraction,
        source: MonitorOperatorLivePresentation, capture: MonitorOperatorLiveCaptureSource,
        zoom: MonitorOperatorZoomPresentation, focus: MonitorOperatorFocusSource,
        assists: MonitorOperatorLiveAssistSource, portraitAspect: Binding<PortraitFeedAspect>,
        orientation: MonitorDeviceOrientation, controlNote: Binding<String?>,
        headTracking: MonitorOperatorHeadTrackingSource? = nil,
        readLevel: ((TimeInterval, Bool) -> MonitorLevelDisplay)? = nil,
        @ViewBuilder picture: @escaping () -> Picture,
        @ViewBuilder preview: @escaping (MonitorAssistSelection) -> Preview,
        @ViewBuilder lookMenu: @escaping () -> LookMenu) {
        self.host = host; self.layout = layout; self.interaction = interaction; self.source = source
        self.capture = capture; self.zoom = zoom; self.focus = focus; self.assists = assists
        _portraitAspect = portraitAspect; self.orientation = orientation; self.controlNote = controlNote
        self.headTracking = headTracking; self.readLevel = readLevel
        self.picture = picture; self.preview = preview; self.lookMenu = lookMenu
    }

    private var editing: MonitorDisplayMode? { host.chromeEditorMode }
    private var interactive: Bool { !host.isEditingChrome }
    private var visible: Bool { !host.coverOpen || host.isEditingChrome }
    private var capturePresented: Bool { host.captureSheet != nil || host.captureDrum != nil }
    private var showsStatus: Bool { host.chromeSectionMounts(.statusBar) }
    private var showsGimbal: Bool { source.gimbal == true && host.chromeSectionMounts(.gimbalStick) }
    private var cluster: GimbalCluster { layout.gimbalCluster(showGimbalButton: showsGimbal) }
    private var geometry: FieldMonitorLayout {
        layout.presentation ?? FieldMonitorLayout(width: layout.viewport.width, height: layout.viewport.height)
    }
    private var popupInteractive: Bool {
        guard interactive, !interaction.locked else { return false }
        return (showsStatus && interaction.topMenu != nil)
            || (!host.coverOpen && !host.assist.gradesClip && host.assist.configureTool != nil)
            || (showsGimbal && host.liveGimbalPanel == .sheet)
            || host.captureSheet != nil || interaction.zoomMounted
    }
    private var presentation: MonitorScreenPresentation {
        MonitorScreenPresentation(visible: visible, interactive: interactive && host.liveChromeInteractive,
            dimmed: interaction.zoomVisible, transientControlsHidden: interaction.zoomMounted,
            pictureWaiting: source.pictureWaiting, statusMounted: showsStatus,
            powerMounted: host.chromeSectionMounts(.batteries), captureMounted: host.chromeSectionMounts(.cameraValues),
            captureHidden: CaptureReadoutAdmission.hidesLowerCaptureValues(sheet: host.captureSheet, drum: host.captureDrum?.sheet),
            captureInteractive: host.captureSheet == nil || host.captureSheet?.isTopAnchored == true,
            locked: interaction.locked,
            popupInteractive: popupInteractive || host.liveGimbalPanel == .editor || host.liveGimbalPanel == .runPill,
            capturePresented: capturePresented && interactive, panelsRaised: interaction.zoomMounted,
            recovering: host.sessionRecovery.isRecovering)
    }

    public var body: some View {
        MonitorScreen(control: host.control, layout: geometry, sourceAspect: source.pictureAspect,
            presentation: presentation) {
            picture().opacity(source.pictureWaiting ? 0 : 1).transaction { $0.animation = nil }
        } assists: {
            MonitorOperatorLiveMarks(host: host, focus: focus, aspect: source.pictureAspect)
                .opacity(source.pictureWaiting ? 0 : 1)
        } signal: {
            MonitorOperatorWaitingPicture<Host.Palette>(waiting: source.pictureWaiting, camera: host.control.snapshot?.session)
        } status: {
            LiveStatusChrome<Host>(menu: Bindable(interaction).topMenu, layout: layout)
                .chromeEditable(.statusBar, editing: editing, in: Host.self)
        } power: {
            LiveTelemetryGauges<Host>(horizontal: geometry.portrait && !geometry.tablet,
                showsLink: !geometry.portrait || geometry.tablet)
                .chromeEditable(.batteries, editing: editing, in: Host.self)
        } capture: {
            CaptureControlBar<Host, EmptyView>(columns: layout.capture.height > 60 ? 3 : 6)
                .chromeEditable(.cameraValues, editing: editing, in: Host.self)
        } system: {
            LiveSystemRail<Host, MonitorOperatorLiveRecord<Host>, MonitorOperatorLiveDisplay<Host>>(
                locked: Bindable(interaction).locked, layout: geometry, capturePresented: capturePresented && interactive,
                visible: visible && !interaction.zoomMounted, interactive: interactive && host.liveChromeInteractive
            ) { diameter in
                MonitorOperatorLiveRecord(host: host, source: capture, diameter: diameter)
            } display: { size in
                MonitorOperatorLiveDisplay(host: host, size: size)
            }
        } tools: { tools
        } panels: { panels
        } cover: { EmptyView()
        } recovery: { EmptyView() }
        .environment(host).environment(\.interfaceLocked, interaction.locked)
        .coordinateSpace(name: LiveCanvasSpace.name)
        .onPreferenceChange(LiveTopPickerFramesKey.self) { topFrames = $0 }
        .onPreferenceChange(LiveCaptureTileFramesKey.self) { captureFrames = $0 }
        .overlayPreferenceValue(ChromeEditBoundsKey.self) { boxes in
            if let editing {
                ChromeEditBadges<Host>(mode: editing, boxes: boxes, viewport: layout.viewport)
                    .frame(width: layout.viewport.width, height: layout.viewport.height, alignment: .topLeading)
            }
        }.overlay {
            if let editing {
                ChromeEditDoneBanner<Host>(mode: editing).position(x: layout.feed.midX, y: editBannerY)
                    .transition(.move(edge: .bottom).combined(with: .opacity)).zIndex(40)
            }
        }.environment(\.colorScheme, .dark).ignoresSafeArea()
    }

    private var editBannerY: CGFloat {
        (layout.showsBottomBars ? min(layout.assist.minY, layout.capture.minY) : layout.feed.maxY) - 28
    }
    private var meterFeed: CGRect {
        host.assist.isVisible(.desqueeze)
            ? DesqueezeAssist.presentationRect(sourceSize: CGSize(width: source.pictureAspect, height: 1),
                in: layout.onFeed, effects: host.assist.effects).intersection(layout.onFeed) : layout.onFeed
    }
    private var clearance: EdgeInsets {
        let portrait = layout.presentation?.portrait == true
        let floor = portrait ? (layout.presentation?.system.y ?? layout.rail.minY) : layout.viewport.height
        let right = portrait ? layout.viewport.width - layout.safeArea.trailing : layout.settings.minX - 6
        return EdgeInsets(top: layout.safeArea.top, leading: layout.safeArea.leading,
            bottom: max(0, layout.viewport.height - floor), trailing: max(0, layout.viewport.width - right))
    }

    @ViewBuilder private var tools: some View {
        ZStack(alignment: .topLeading) {
            Color.clear.allowsHitTesting(false)
            MonitorOperatorFeedGestures(host: host, focus: focus, layout: layout, cluster: cluster,
                source: source, enabled: !interaction.locked && !host.coverOpen && interactive,
                headTracking: headTracking?.enabled == true)
            MonitorOperatorLiveScopes(host: host, source: source, assists: assists,
                layout: layout, clearance: clearance)
            if host.assist.isVisible(.evMeter) {
                MonitorOperatorLiveExposure(host: host, feed: meterFeed, layout: layout,
                    interaction: interaction, recovering: source.recovering)
                    .accessibilityHidden(!visible || interaction.zoomMounted)
            }
            if host.assist.isVisible(.level), let readLevel {
                TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                    MonitorLevelOverlay(display: readLevel(ProcessInfo.processInfo.systemUptime,
                        host.livePictureViewFlip != host.assist.flipsVertically),
                        feed: meterFeed, viewport: CGRect(origin: .zero, size: layout.viewport),
                        portrait: layout.viewport.height > layout.viewport.width)
                }.allowsHitTesting(false).accessibilityHidden(!visible || interaction.zoomMounted)
            }
            if interaction.assistsExpanded, host.chromeSectionMounts(.toolBar), !interaction.locked, interactive {
                Color.clear.frame(width: layout.viewport.width, height: layout.viewport.height)
                    .contentShape(Rectangle()).onTapGesture { interaction.assistsExpanded = false }.accessibilityHidden(true)
            }
            if let p = layout.presentation, p.portrait, !source.verticalPicture, editing == nil,
                !host.assist.isVisible(.desqueeze) {
                PortraitAspectToggle<Host.Palette>(aspect: $portraitAspect)
                    .accessibilityHidden(!visible || interaction.zoomMounted).liveModuleFrame(p.aspectToggle.cgRect)
                    .allowsHitTesting(!interaction.locked)
            }
            motionControls
            MonitorOperatorFocusControls(host: host, focus: focus, layout: layout,
                interactive: interactive && !interaction.locked).zIndex(4)
            MonitorOperatorLiveBanners(host: host, layout: layout, source: source,
                headTracking: headTracking, note: controlNote, showsStatus: showsStatus)
        }.frame(width: layout.viewport.width, height: layout.viewport.height)
            .environment(\.colorScheme, .dark).preferredColorScheme(.dark).ignoresSafeArea()
        if host.chromeSectionMounts(.toolBar) {
            LiveAssistPalette<Host, MonitorOperatorLiveToolIcon>(layout: layout, isLocked: interaction.locked,
                otherOverlayPresented: interaction.topMenu != nil || interaction.zoomVisible,
                expanded: Bindable(interaction).assistsExpanded,
                onExpansionActivityChange: { interaction.assistsRevealing = $0 }
            ) { MonitorOperatorLiveToolIcon(tool: $0) }
                .opacity(interaction.locked ? 0.4 : 1).allowsHitTesting(!interaction.locked)
                .environment(\.colorScheme, .dark).ignoresSafeArea().zIndex(6)
        }
    }

    @ViewBuilder private var motionControls: some View {
        if source.zoom == true && host.chromeSectionMounts(.zoomChip) {
            ZoomChip<Host>(onOpenDial: openZoom)
                .chromeEditable(.zoomChip, editing: editing, in: Host.self).liveModuleFrame(rect(cluster.zoom))
                .opacity(capturePresented ? 0 : 1).allowsHitTesting(!interaction.locked && !capturePresented)
                .accessibilityHidden(capturePresented || !visible || interaction.zoomMounted).zIndex(2)
        }
        if showsGimbal {
            LiveGimbalButton<Host, Host.Palette>().liveModuleFrame(rect(cluster.controls))
                .opacity(capturePresented ? 0 : 1).allowsHitTesting(!interaction.locked && !capturePresented)
                .accessibilityHidden(capturePresented || !visible || interaction.zoomMounted).zIndex(2)
            LiveGimbalStick<Host, Host.Palette>(enabled: !interaction.locked && !host.coverOpen && interactive && !capturePresented,
                frame: rect(cluster.stick), feed: layout.feed)
                .id("live-gimbal-stick").transaction(value: orientation) { $0.animation = nil }
                .chromeEditable(.gimbalStick, editing: editing, in: Host.self).liveModuleFrame(rect(cluster.stick))
                .opacity(capturePresented ? 0 : 1)
                .accessibilityHidden(capturePresented || !visible || interaction.zoomMounted).zIndex(3)
        }
        if source.headTracking == true, let headTracking, headTracking.enabled,
            !interaction.locked, interactive, !host.coverOpen {
            HeadTrackCalibrateButton<Host.Palette>(title: headTracking.title, onTap: headTracking.calibrate)
                .liveModuleFrame(layout.gimbalCalibrate).opacity(capturePresented ? 0 : 1)
                .allowsHitTesting(!capturePresented && !interaction.zoomMounted)
                .accessibilityHidden(capturePresented || !visible || interaction.zoomMounted).zIndex(3)
        }
    }

    @ViewBuilder private var panels: some View {
        Group {
            MonitorOperatorCaptureOverlays<Host>(layout: layout, interaction: interaction,
                topFrames: topFrames, captureFrames: captureFrames)
            if interactive, !host.coverOpen, !host.assist.gradesClip,
                let tool = host.assist.configureTool, !interaction.locked {
                MonitorOperatorLiveInspector(host: host, tool: tool, assists: assists,
                    layout: layout, preview: preview, lookMenu: lookMenu)
            }
            if interactive, showsGimbal, host.liveGimbalPanel == .sheet, !interaction.locked {
                LiveGimbalSheetHost<Host>(layout: layout, cluster: cluster)
            }
            if interaction.zoomMounted, interactive, !interaction.locked {
                MonitorOperatorZoomDial<Host>(layout: layout, interaction: interaction, source: zoom, onClose: closeZoom)
            }
        }.allowsHitTesting(popupInteractive)
        if showsGimbal, interactive, !interaction.locked, !host.coverOpen {
            LiveGimbalOverlay<Host, Host.Palette>(layout: layout, feed: layout.onFeed,
                joystickBounds: host.chromeSectionMounts(.gimbalStick) && !capturePresented ? rect(cluster.stick) : .zero,
                zoomBounds: source.zoom == true && host.chromeSectionMounts(.zoomChip) && !capturePresented ? rect(cluster.zoom) : .zero,
                coveredByZoom: interaction.zoomMounted)
                .opacity(interaction.zoomVisible ? 0.16 : 1)
                .animation(MonitorMotion.dim(reduceMotion), value: interaction.zoomVisible)
                .allowsHitTesting(host.liveChromeInteractive && !interaction.zoomMounted).zIndex(15)
        }
    }
    private func openZoom() { interaction.openZoom(host: host, motion: Bindable(host).liveGimbalPanel) }
    private func closeZoom() { interaction.closeZoom(host: host, reduceMotion: reduceMotion) }
    private func rect(_ region: MonitorLayoutRegion) -> CGRect {
        CGRect(x: region.x, y: region.y, width: region.width, height: region.height)
    }
}

private struct MonitorOperatorLiveToolIcon: View {
    let tool: MonitorAssistSelection
    var body: some View {
        if let shared = tool.sharedTool { MonitorAssistToolGlyph(tool: shared, size: nil) }
    }
}

private struct MonitorOperatorLiveRecord<Host: LiveChromeHost>: View {
    let host: Host
    let source: MonitorOperatorLiveCaptureSource
    let diameter: CGFloat
    @Environment(\.interfaceLocked) private var locked
    var body: some View {
        MonitorCaptureButton(control: host.control, diameter: diameter,
            enabled: !locked && !host.sessionLocked && !source.busy(), photo: host.cameraStatus.isPhoto,
            confirm: source.confirmRecording, haptics: host.hapticsEnabled, takePhoto: source.takePhoto,
            openMode: { host.captureSheet = .mode })
    }
}

private struct MonitorOperatorLiveDisplay<Host: LiveChromeHost>: View {
    let host: Host
    let size: CGSize
    @Environment(\.interfaceLocked) private var locked
    var body: some View {
        MonitorDisplayButton(clean: host.assist.clean, size: size, enabled: !locked) {
            guard !locked else { return }
            host.setDisplayMode(clean: !host.assist.clean)
            if host.assist.clean { host.captureSheet = nil }
        }
    }
}

private struct MonitorOperatorLiveInspector<Host: LiveChromeHost, Preview: View, LookMenu: View>: View {
    let host: Host
    let tool: MonitorAssistSelection
    let assists: MonitorOperatorLiveAssistSource
    let layout: LiveMonitorLayout
    let preview: (MonitorAssistSelection) -> Preview
    let lookMenu: () -> LookMenu
    var body: some View {
        let transfer = assists.readTransfer()
        MonitorOperatorAssistInspector(tool: tool, assist: host.assist, stores: assists.stores,
            looks: assists.looks, palette: Host.Palette.self, haptics: assists.haptics,
            transfer: transfer, clipByte: assists.readClipByte(transfer), viewport: layout.viewport,
            safeArea: layout.safeArea, onDismiss: { host.assist.configureTool = nil }, preview: preview, lookMenu: lookMenu)
    }
}

private struct MonitorOperatorLiveMarks<Host: LiveChromeHost>: View {
    let host: Host
    let focus: MonitorOperatorFocusSource
    let aspect: Double
    var body: some View {
        let value = focus.read()
        let show = host.chromeSectionMounts(.focusBox)
        ZStack {
            FeedAssistMarks<Host>(grid: host.assist.isVisible(.grid), crosshair: host.assist.isVisible(.crosshair),
                guides: host.assist.isVisible(.guides), guideAspect: host.assist.guideAspect,
                focusPoint: value.point, overlay: value.overlay, sceneFaces: show ? value.faces : [],
                showFocusChrome: show, showTapFocusBox: value.supportsTapFocus == true,
                aeLocked: host.autoExposureLocked, focusLocked: host.focusBoxLocked, sourceAspect: CGFloat(aspect),
                pictureAspect: CGFloat(host.cameraStatus.videoFormat?.resolution.ratio ?? host.cameraStatus.videoResolution?.ratio ?? aspect),
                pictureMirrored: host.livePictureViewFlip)
                .opacity(host.chromeEditorMode.map { host.chrome(for: $0).focusBox ? 1 : 0.3 } ?? 1)
                .animation(.easeOut(duration: 0.20), value: value.resetAvailable)
            if let editing = host.chromeEditorMode {
                GeometryReader { proxy in
                    let feed = DesqueezeAssist.presentationRect(sourceSize: CGSize(width: aspect, height: 1),
                        in: CGRect(origin: .zero, size: proxy.size), effects: host.assist.effects)
                    let rect = LiveChromeEditGeometry.focusEditRect(overlay: value.overlay, faces: value.faces,
                        focusPoint: value.point, mirrored: host.livePictureViewFlip,
                        flippedVertically: host.assist.flipsVertically, in: feed)
                    Color.clear.frame(width: rect.width, height: rect.height)
                        .chromeEditable(.focusBox, editing: editing, in: Host.self).position(x: rect.midX, y: rect.midY)
                }
            }
        }
    }
}

private struct MonitorOperatorFeedGestures<Host: LiveChromeHost>: View {
    let host: Host
    let focus: MonitorOperatorFocusSource
    let layout: LiveMonitorLayout
    let cluster: GimbalCluster
    let source: MonitorOperatorLivePresentation
    let enabled: Bool
    let headTracking: Bool
    var body: some View {
        let value = focus.read()
        let feed = host.assist.isVisible(.desqueeze)
            ? DesqueezeAssist.presentationRect(sourceSize: CGSize(width: source.pictureAspect, height: 1),
                in: layout.onFeed, effects: host.assist.effects) : layout.onFeed
        FeedGestureWell<Host>(feed: feed, chip: rect(cluster.zoom), stick: rect(cluster.stick),
            gimbalButton: rect(cluster.controls), reset: value.resetAvailable ? layout.focusReset : .zero,
            aeUnlock: host.autoExposureLocked ? layout.aeUnlock : .zero, cancel: cancelRect(value.trackedSubject),
            calibrate: headTracking && source.headTracking == true ? layout.gimbalCalibrate : .zero,
            enabled: enabled)
            .animation(.easeOut(duration: 0.20), value: value.resetAvailable)
    }
    private func rect(_ region: MonitorLayoutRegion) -> CGRect {
        CGRect(x: region.x, y: region.y, width: region.width, height: region.height)
    }
    private func cancelRect(_ subject: TrackingBox?) -> CGRect {
        guard let subject else { return .zero }
        return MonitorTrackingGeometry.cancelRect(box: subject, feed: layout.onFeed,
            mirrored: host.livePictureViewFlip, flippedVertically: host.assist.flipsVertically)
    }
}

private struct MonitorOperatorFocusControls<Host: LiveChromeHost>: View {
    let host: Host
    let focus: MonitorOperatorFocusSource
    let layout: LiveMonitorLayout
    let interactive: Bool
    var body: some View {
        let value = focus.read()
        Group {
            if interactive, value.resetAvailable {
                FocusResetButton<Host>().liveModuleFrame(layout.focusReset)
                    .transition(.scale(scale: 0.6).combined(with: .opacity)).zIndex(3)
            }
            if interactive, host.autoExposureLocked {
                AutoExposureUnlockButton<Host>().liveModuleFrame(layout.aeUnlock)
                    .transition(.scale(scale: 0.6).combined(with: .opacity)).zIndex(3)
            }
            if interactive, let subject = value.trackedSubject {
                Button(action: focus.cancelTracking) {
                    MonitorIcon.x.frame(width: 11, height: 11).foregroundStyle(Host.Palette.background)
                        .frame(width: MonitorTrackingGeometry.cancelSize, height: MonitorTrackingGeometry.cancelSize)
                        .background(Host.Palette.good, in: Circle())
                }.buttonStyle(.monitorTapTarget).accessibilityLabel("Stop subject tracking")
                    .accessibilityIdentifier("monitor.system.trackCancel")
                    .liveModuleFrame(MonitorTrackingGeometry.cancelRect(box: subject, feed: layout.onFeed,
                        mirrored: host.livePictureViewFlip, flippedVertically: host.assist.flipsVertically))
                    .zIndex(4)
            }
        }.animation(.easeOut(duration: 0.20), value: value.resetAvailable)
    }
}

private struct MonitorOperatorLiveScopes<Host: LiveChromeHost>: View {
    let host: Host
    let source: MonitorOperatorLivePresentation
    let assists: MonitorOperatorLiveAssistSource
    let layout: LiveMonitorLayout
    let clearance: EdgeInsets
    var body: some View {
        let canvas = CGRect(origin: .zero, size: layout.viewport)
        MonitorScopeOverlays(assist: host.assist, stores: assists.stores, haptics: assists.haptics,
            canvas: canvas, feed: layout.onFeed, chromeClearance: clearance,
            readBundle: assists.readBundle, configureDisplay: assists.configureDisplay)
        if !source.watching, host.captureCapabilities.audio, host.assist.isVisible(.audioMeters) {
            MonitorOperatorLiveAudio(host: host, stores: assists.stores, canvas: canvas, clearance: clearance)
        }
        if host.assist.isVisible(.falseColor), host.assist.falseColorReference {
            let transfer = assists.readTransfer()
            FalseColorReferenceOverlay(stores: assists.stores, looks: assists.looks,
                scale: host.assist.falseColorScale, transfer: transfer, rec709: host.assist.falseColorRec709,
                clipByte: assists.readClipByte(transfer), bounds: canvas, chromeClearance: clearance,
                hapticsEnabled: host.hapticsEnabled, onConfigure: { host.assist.configureTool = .falseColor })
        }
    }
}

private struct MonitorOperatorLiveAudio<Host: LiveChromeHost>: View {
    let host: Host
    let stores: AssistPanelStores
    let canvas: CGRect
    let clearance: EdgeInsets
    var body: some View {
        if !host.cameraStatus.isPhoto {
            AudioMeterOverlay(stores: stores, levels: host.cameraStatus.audioMeters ?? .silent,
                sensitivity: host.cameraStatus.audioChannel?.label, bounds: canvas, chromeClearance: clearance,
                hapticsEnabled: host.hapticsEnabled, onConfigure: { host.assist.configureTool = .audioMeters })
        }
    }
}

private struct MonitorOperatorLiveExposure<Host: LiveChromeHost>: View {
    let host: Host
    let feed: CGRect
    let layout: LiveMonitorLayout
    let interaction: MonitorOperatorInteraction
    let recovering: Bool
    var body: some View {
        let obstacle = host.chromeSectionMounts(.toolBar)
            ? LiveAssistPalette<Host, MonitorOperatorLiveToolIcon>.visibleFrame(in: layout,
                toolCount: MonitorAssistSelection.toolbarCases.count + (host.cameraStatus.isPhoto ? 0 : 1),
                expanded: interaction.assistsExpanded || interaction.assistsRevealing) : nil
        let frame = MonitorOperatorExposureGeometry.frame(in: feed, avoiding: obstacle)
        let reading = ExposureMeterReading(cameraValue: host.sessionRecovery.isRecovering || recovering ? nil : host.cameraStatus.meteredEv)
        MonitorExposureGauge(value: reading.label, needleFraction: reading.needleFraction)
            .frame(width: frame.width, height: frame.height).position(x: frame.midX, y: frame.midY)
            .accessibilityElement(children: .ignore).accessibilityLabel("EV meter")
            .accessibilityValue(reading.accessibilityValue).accessibilityIdentifier("monitor.ev.meter")
            .accessibilityHidden(frame.isEmpty).opacity(frame.isEmpty ? 0 : 1).allowsHitTesting(false)
    }
}

private struct MonitorOperatorLiveBanners<Host: LiveChromeHost>: View {
    let host: Host
    let layout: LiveMonitorLayout
    let source: MonitorOperatorLivePresentation
    let headTracking: MonitorOperatorHeadTrackingSource?
    @Binding var note: String?
    let showsStatus: Bool
    private struct Context: Equatable {
        let source: CameraSessionID?
        let note: String?
        let recovering: Bool
    }
    var body: some View {
        let chromeBottom = showsStatus && layout.topDeck.height > 1 ? Double(layout.topDeck.maxY) : nil
        let y = CGFloat(ControlHud.toastCenterY(feedMinY: Double(layout.onFeed.minY), chromeBottomY: chromeBottom))
        Group {
            if source.recovering { capsule("Reconnecting", size: 11).position(x: layout.onFeed.midX, y: y) }
            if let note, !note.isEmpty, !source.recovering {
                capsule(note, size: 12).opacity(ControlHud.toastOpacity).position(x: layout.onFeed.midX, y: y)
                    .transition(.opacity)
            }
            if let headTracking, headTracking.enabled, let pose = headTracking.readPose() {
                VStack(alignment: .leading, spacing: 6) {
                    LiveHeadTrackAxisDials<Host.Palette>(pose: pose)
                    if !headTracking.readIMU().isEmpty {
                        Text(headTracking.readIMU()).font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(Host.Palette.text).multilineTextAlignment(.leading)
                            .frame(maxWidth: 220, alignment: .leading).padding(.horizontal, 8).padding(.vertical, 6)
                            .liveChromeGlass(in: Capsule())
                    }
                }.position(x: layout.onFeed.minX + 118, y: layout.onFeed.minY + 118)
                    .zIndex(5).allowsHitTesting(false).transaction { $0.animation = nil }
            }
        }.animation(.easeOut(duration: 0.18), value: note).animation(.easeOut(duration: 0.18), value: y)
            .task(id: Context(source: host.control.snapshot?.session, note: note, recovering: source.recovering)) {
                let owner = host.control.snapshot?.session
                let captured = note
                guard captured?.isEmpty == false, !source.recovering else { return }
                try? await Task.sleep(for: .seconds(ControlHud.toastHoldSeconds))
                guard !Task.isCancelled, host.control.snapshot?.session == owner, note == captured else { return }
                note = nil
            }
    }
    private func capsule(_ text: String, size: CGFloat) -> some View {
        Text(text).font(MonitorTheme.font(size, weight: .semibold)).foregroundStyle(Host.Palette.text.opacity(0.92))
            .padding(.horizontal, size == 11 ? 10 : 12).padding(.vertical, size == 11 ? 4 : 6)
            .liveChromeGlass(in: Capsule()).zIndex(3).allowsHitTesting(false)
    }
}

private struct MonitorOperatorWaitingPicture<Palette: LiveChromePalette>: View {
    let waiting: Bool
    let camera: CameraSessionID?
    @State private var showVPNHint = false
    private struct Context: Equatable { let camera: CameraSessionID?; let waiting: Bool }
    var body: some View {
        ZStack {
            Color.black
            VStack(spacing: 12) {
                if waiting { ProgressView().controlSize(.large).tint(Palette.text.opacity(0.72)) }
                Text("WAITING FOR LIVE VIEW").font(.system(size: 15, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Palette.text.opacity(0.72))
                if showVPNHint {
                    Text(LocalVPNFilter.liveHint).font(MonitorTheme.font(12)).foregroundStyle(Palette.muted)
                        .multilineTextAlignment(.center).padding(.horizontal, 28)
                }
            }
        }.allowsHitTesting(false).accessibilityElement(children: .combine)
            .accessibilityLabel(showVPNHint ? "Waiting for live view. \(LocalVPNFilter.liveHint)" : "Waiting for live view")
            .task(id: Context(camera: camera, waiting: waiting)) {
                showVPNHint = false
                guard waiting else { return }
                try? await Task.sleep(for: .seconds(LocalVPNFilter.liveHintDelaySeconds))
                guard !Task.isCancelled else { return }
                showVPNHint = LocalVPNFilter.shouldHintOnLiveWait(vpnActive: LocalVPNProbe.isActive(),
                    hadVideo: !waiting, secondsWithoutVideo: LocalVPNFilter.liveHintDelaySeconds)
            }
    }
}

/// Original point-space exposure placement, shared by real live callers and their numeric goldens.
public enum MonitorOperatorExposureGeometry {
    public static func frame(in feed: CGRect, avoiding obstacle: CGRect? = nil) -> CGRect {
        let width: CGFloat = 28
        let minimumHeight: CGFloat = 72
        guard feed.width >= width + 12, feed.height >= minimumHeight + 12 else { return .zero }
        let x = feed.minX + 6
        let top = feed.minY + 6
        let bottom = feed.maxY - 6
        let preferredY = feed.midY - 16 - min(180, bottom - top) / 2
        func fitting(top: CGFloat, bottom: CGFloat) -> CGRect {
            let height = min(180, bottom - top)
            guard height >= minimumHeight else { return .zero }
            return CGRect(x: x, y: min(max(preferredY, top), bottom - height), width: width, height: height)
        }
        let preferred = fitting(top: top, bottom: bottom)
        guard let obstacle, !obstacle.isEmpty, obstacle.minX < preferred.maxX, obstacle.maxX > preferred.minX,
            obstacle.minY - 12 < preferred.maxY, obstacle.maxY + 12 > preferred.minY else { return preferred }
        let above = fitting(top: top, bottom: min(bottom, obstacle.minY - 12))
        if !above.isEmpty { return above }
        return fitting(top: max(top, obstacle.maxY + 12), bottom: bottom)
    }
}
#endif
