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

    public var body: some View {
        @Bindable var host = host
        let identity = MonitorOperatorLiveIdentity(monitor: nil, camera: host.control.snapshot?.session,
            epoch: host.control.snapshot?.epoch, picture: "live")
        let captureInputs = MonitorOperatorCaptureInputs<CaptureSheet, Host.ChromeSection,
            MonitorOperatorLegacyCaptureIdentity>.captureSheetHost(host, section: .cameraValues,
                columns: layout.capture.height > 60 ? 3 : 6,
                presentedSheet: {
                    host.captureSheet ?? interaction.topMenu.map { $0 == .color ? .color : .resolution }
                }, open: { sheet in
                    if sheet == .resolution { interaction.topMenu = interaction.topMenu == .recFormat ? nil : .recFormat }
                    else if sheet == .color { interaction.topMenu = interaction.topMenu == .color ? nil : .color }
                    else { host.captureSheet = CaptureReadoutAdmission.replacing(host.captureSheet,
                        with: CaptureReadoutAdmission.opening(sheet, isPhoto: host.cameraStatus.isPhoto)) }
                }, dismiss: { host.captureSheet = nil; interaction.topMenu = nil })
        let tools = MonitorAssistSelection.toolbarCases + (host.cameraStatus.isPhoto || !host.captureCapabilities.audio ? [] : [.audioMeters])
        let percent = host.cameraStatus.batteryPercent
        let native = MonitorOperatorLegacyAccessories(host: host, layout: layout, interaction: interaction,
            source: source, capture: capture, zoom: zoom, focus: focus, assists: assists,
            headTracking: headTracking, readLevel: readLevel, controlNote: controlNote,
            portraitAspect: $portraitAspect, orientation: orientation, reduceMotion: reduceMotion)
        MonitorOperatorLiveBody(host: host, control: host.control, identity: identity,
            current: { value in host.control.snapshot?.session == value.camera && host.control.snapshot?.epoch == value.epoch },
            layout: layout.presentation ?? FieldMonitorLayout(width: layout.viewport.width, height: layout.viewport.height),
            safeArea: .init(top: layout.safeArea.top, leading: layout.safeArea.leading,
                bottom: layout.safeArea.bottom, trailing: layout.safeArea.trailing), sourceAspect: source.pictureAspect,
            sections: .init(status: .statusBar, power: .batteries, capture: .cameraValues,
                assists: .toolBar, lock: .lockButton, settings: .railSettings, media: .railMedia, record: .railRecord),
            mounted: Set(host.chromeEditSections.filter(host.chromeSectionMounts)), editing: host.chromeEditorMode,
            locked: Bindable(interaction).locked, covered: host.coverOpen,
            clean: host.assist.clean, command: false, readOnly: host.sessionLocked,
            recovering: source.recovering, status: statusProjection,
            power: [.init(id: "camera", title: "Camera battery", camera: true,
                percent: (0...100).contains(percent) ? percent : nil)],
            captureInputs: captureInputs, settings: host.openSettings, media: host.openMedia,
            cycleDisplay: { host.setDisplayMode(clean: !host.assist.clean); if host.assist.clean { host.captureSheet = nil } },
            displayTitle: host.assist.clean ? "DISP 2 clean" : "DISP 1 live", displayIndex: host.assist.clean ? 1 : 0, displayCount: 2,
            photo: host.cameraStatus.isPhoto, confirmRecord: capture.confirmRecording,
            assist: host.assist, tools: tools, usage: $host.assistToolUsage,
            toggleTool: host.assist.toggle, assistSource: assists,
            readAudio: { !source.watching && host.captureCapabilities.audio && !host.cameraStatus.isPhoto ? host.cameraStatus.audioMeters : nil },
            cameraViews: native.views, retireEditor: host.endChromeEditing, returnToStage: host.multiviewExit,
            automaticPhoneBattery: true, borrowed: host.multiviewBorrowed, pictureWaiting: source.pictureWaiting,
            recordEnabled: !capture.busy(), openMode: { host.captureSheet = .mode },
            recordConfirmationPolicy: .unchangedRecording, audioCaption: host.cameraStatus.audioChannel?.label,
            interactionEnabled: host.liveChromeInteractive, dimmed: interaction.zoomVisible,
            transientControlsHidden: interaction.zoomMounted, panelsRaised: interaction.zoomMounted,
            expanded: Bindable(interaction).assistsExpanded,
            picture: picture, cameraPanel: { key, popup in
                CaptureSheetPanel<Host>(sheet: key, maximumHeight: popup.maximumHeight,
                    isPresented: { host.control.snapshot?.session == identity.camera && host.control.snapshot?.epoch == identity.epoch
                        && (host.captureSheet == key || interaction.topMenu.map { $0 == .color ? CaptureSheet.color : .resolution } == key) },
                    onSelectRecordingCategory: [.resolution, .color, .mode].contains(key) ? { host.captureSheet = $0 } : nil,
                    showsRecordingCategories: layout.viewport.height > layout.viewport.width,
                    controlsEnabled: !host.sessionLocked, chromeless: true) { host.captureSheet = nil }
            }, photoRelease: { diameter in
                MonitorCaptureButton(control: host.control, diameter: diameter,
                    enabled: !interaction.locked && !host.sessionLocked && !capture.busy(), photo: true,
                    confirm: capture.confirmRecording, haptics: host.hapticsEnabled, takePhoto: capture.takePhoto,
                    openMode: { host.captureSheet = .mode })
            }, preview: preview, lookMenu: lookMenu)
            .onChange(of: host.cameraStatus.isPhoto) { _, photo in
                host.captureSheet = CaptureReadoutAdmission.retained(host.captureSheet, isPhoto: photo)
                if CaptureReadoutAdmission.retainedDrum(host.captureDrum?.sheet, isPhoto: photo) == nil {
                    host.captureDrum = nil
                }
                if photo { interaction.topMenu = nil }
                if photo, host.assist.configureTool == .audioMeters { host.assist.configureTool = nil }
            }
    }

    private var statusProjection: MonitorOperatorLiveStatus<CaptureSheet, Host.ChromeSection> {
        let value = host.cameraStatus
        let photo = value.isPhoto
        func row(_ key: CaptureSheet, _ title: String, _ text: String,
            _ section: Host.ChromeSection? = nil, _ identifier: String) -> MonitorOperatorLiveReadout<CaptureSheet, Host.ChromeSection> {
            .init(id: key, title: title, value: text, section: section, accessibilityIdentifier: identifier)
        }
        let free = value.storageFreeMb > 0 ? value.storageFreeMb : value.sdFreeMb
        let total = value.storageTotalMb > 0 ? value.storageTotalMb : value.sdTotalMb
        let storage = host.chromeSectionMounts(.storage)
            ? row(.resolution, "Storage remaining", free > 0 ? "\(free / 1024) GB" : "\u{2014}", .storage, "monitor.storage") : nil
        let format = host.chromeSectionMounts(.format) ? [row(photo ? .mode : .resolution,
            photo ? "Shooting mode" : "Recording format",
            photo ? host.currentShootingMode?.label(for: host.connectedBody) ?? "Photo" : value.videoFormat?.chipLabel ?? "\u{2014}",
            .format, photo ? "monitor.capture.mode" : "monitor.capture.format")] : []
        let setup = row(photo ? .mode : .resolution, photo ? "Shooting mode" : "Recording options",
            photo ? "MODE" : value.videoFormat.map { "\($0.resolution.tabTitle)\($0.frameRate.drumLabel)" } ?? "REC SETUP",
            .format, photo ? "monitor.capture.mode" : "monitor.capture.format")
        let color = !photo && host.chromeSectionMounts(.color)
            ? row(.color, "Color mode", value.colorMode?.label(in: host.labelProfile) ?? "\u{2014}", .color, "monitor.capture.color") : nil
        let mode = !photo ? row(.mode, "Shooting mode", host.currentShootingMode?.label(for: host.connectedBody) ?? "Video",
            nil, "monitor.capture.mode") : nil
        return .init(recording: host.liveStatus, showsTimecode: host.chromeSectionMounts(.timecode) && !photo && host.timecodeAvailable,
            showsRecording: host.chromeSectionMounts(.recReadout) && !photo, storage: storage, format: format,
            fps: host.chromeSectionMounts(.batteries) ? host.liveFPS : nil,
            signalBars: host.chromeSectionMounts(.batteries) ? host.liveSignalBars : nil, fpsSection: .batteries,
            portraitFormat: setup, portraitCaption: photo ? nil : value.colorMode?.label(for: host.bodyFamily, in: host.labelProfile),
            color: color, mode: mode, storageAlternative: total > 0 ? "\(Int((Double(max(0, free)) / Double(total) * 100).rounded()))%" : nil)
    }
}

/// Coherent native focus and motion content, borrowed by the common live owner. This adapter
/// produces no status, system rail, assist palette, inspector or camera-popup chrome.
@MainActor private struct MonitorOperatorLegacyAccessories<Host: LiveChromeHost & GimbalPanelHost & GimbalStickHost> {
    let host: Host
    let layout: LiveMonitorLayout
    let interaction: MonitorOperatorInteraction
    let source: MonitorOperatorLivePresentation
    let capture: MonitorOperatorLiveCaptureSource
    let zoom: MonitorOperatorZoomPresentation
    let focus: MonitorOperatorFocusSource
    let assists: MonitorOperatorLiveAssistSource
    let headTracking: MonitorOperatorHeadTrackingSource?
    let readLevel: ((TimeInterval, Bool) -> MonitorLevelDisplay)?
    let controlNote: Binding<String?>
    @Binding var portraitAspect: PortraitFeedAspect
    let orientation: MonitorDeviceOrientation
    let reduceMotion: Bool

    private var editing: MonitorDisplayMode? { host.chromeEditorMode }
    private var interactive: Bool { !host.isEditingChrome }
    private var visible: Bool { !host.coverOpen || host.isEditingChrome }
    private var capturePresented: Bool { host.captureSheet != nil || host.captureDrum != nil }
    private var showsStatus: Bool { host.chromeSectionMounts(.statusBar) }
    private var showsGimbal: Bool { source.gimbal == true && host.chromeSectionMounts(.gimbalStick) }
    private var cluster: GimbalCluster { layout.gimbalCluster(showGimbalButton: showsGimbal) }

    var views: MonitorOperatorBodyViews {
        .init(feedMarks: AnyView(MonitorOperatorLiveMarks(host: host, focus: focus, aspect: source.pictureAspect)),
            feedGestures: AnyView(MonitorOperatorFeedGestures(host: host, focus: focus, layout: layout, cluster: cluster,
                source: source, enabled: !interaction.locked && !host.coverOpen && interactive,
                headTracking: headTracking?.enabled == true)),
            focusControls: AnyView(focusContent),
            motion: .init(controls: AnyView(motionControls), editor: AnyView(editor), feedback: AnyView(feedback)))
    }
    private var meterFeed: CGRect {
        host.assist.isVisible(.desqueeze)
            ? DesqueezeAssist.presentationRect(sourceSize: CGSize(width: source.pictureAspect, height: 1),
                in: layout.onFeed, effects: host.assist.effects).intersection(layout.onFeed) : layout.onFeed
    }
    @ViewBuilder private var focusContent: some View {
        MonitorOperatorFocusControls(host: host, focus: focus, layout: layout, interactive: interactive && !interaction.locked)
        if host.assist.isVisible(.evMeter) {
            MonitorOperatorLiveExposure(host: host, feed: meterFeed, layout: layout,
                interaction: interaction, recovering: source.recovering)
                .accessibilityHidden(!visible || interaction.zoomMounted)
        }
        if host.assist.isVisible(.level), let readLevel {
            TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                MonitorLevelOverlay(display: readLevel(ProcessInfo.processInfo.systemUptime,
                    host.livePictureViewFlip != host.assist.flipsVertically), feed: meterFeed,
                    viewport: CGRect(origin: .zero, size: layout.viewport), portrait: layout.viewport.height > layout.viewport.width)
            }.allowsHitTesting(false).accessibilityHidden(!visible || interaction.zoomMounted)
        }
        if let p = layout.presentation, p.portrait, !source.verticalPicture, editing == nil, !host.assist.isVisible(.desqueeze) {
            PortraitAspectToggle<Host.Palette>(aspect: $portraitAspect)
                .accessibilityHidden(!visible || interaction.zoomMounted).liveModuleFrame(p.aspectToggle.cgRect)
                .allowsHitTesting(!interaction.locked)
        }
        MonitorOperatorLiveBanners(host: host, layout: layout, source: source, headTracking: headTracking,
            note: controlNote, showsStatus: showsStatus)
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

    @ViewBuilder private var editor: some View {
        if interactive, showsGimbal, host.liveGimbalPanel == .sheet, !interaction.locked {
            LiveGimbalSheetHost<Host>(layout: layout, cluster: cluster)
        }
        if interaction.zoomMounted, interactive, !interaction.locked {
            MonitorOperatorZoomDial<Host>(layout: layout, interaction: interaction, source: zoom, onClose: closeZoom)
        }
    }
    @ViewBuilder private var feedback: some View {
        if showsGimbal, interactive, !interaction.locked, !host.coverOpen {
            LiveGimbalOverlay<Host, Host.Palette>(layout: layout, feed: layout.onFeed,
                joystickBounds: host.chromeSectionMounts(.gimbalStick) && !capturePresented ? rect(cluster.stick) : .zero,
                zoomBounds: source.zoom == true && host.chromeSectionMounts(.zoomChip) && !capturePresented ? rect(cluster.zoom) : .zero,
                coveredByZoom: interaction.zoomMounted)
                .opacity(interaction.zoomVisible ? 0.16 : 1)
                .animation(MonitorMotion.dim(reduceMotion), value: interaction.zoomVisible)
                .allowsHitTesting(host.liveChromeInteractive && !interaction.zoomMounted)
        }
    }
    private func openZoom() { interaction.openZoom(host: host, motion: Bindable(host).liveGimbalPanel) }
    private func closeZoom() { interaction.closeZoom(host: host, reduceMotion: reduceMotion) }
    private func rect(_ region: MonitorLayoutRegion) -> CGRect {
        CGRect(x: region.x, y: region.y, width: region.width, height: region.height)
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

private struct MonitorOperatorLiveExposure<Host: LiveChromeHost>: View {
    let host: Host
    let feed: CGRect
    let layout: LiveMonitorLayout
    let interaction: MonitorOperatorInteraction
    let recovering: Bool
    var body: some View {
        let geometry = layout.presentation ?? FieldMonitorLayout(width: layout.viewport.width, height: layout.viewport.height)
        let palette = MonitorAssistPaletteLayout.fieldMonitor(geometry,
            toolCount: MonitorAssistSelection.toolbarCases.count + (host.cameraStatus.isPhoto ? 0 : 1), safeTop: layout.safeArea.top)
        let footprint = palette.layout.resolving(expanded: interaction.assistsExpanded || interaction.assistsRevealing)
            .anchored(leading: palette.frame.x, bottom: palette.frame.maxY)
        let obstacle = host.chromeSectionMounts(.toolBar) ? footprint.cgRect : nil
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
