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

extension MonitorOperatorLivePresentation {
    /// Zoom, gimbal and head tracking from the one capability model, laid out over the host's
    /// `base` sections while a family is still unknown (as `MonitorLayoutCapabilities(controls:base:)`).
    public init(pictureAspect: Double, pictureWaiting: Bool, verticalPicture: Bool, recovering: Bool,
        controls: ControlCapabilities, base: MonitorLayoutCapabilities = .init(), watching: Bool) {
        let layout = MonitorLayoutCapabilities(controls: controls, base: base)
        self.init(pictureAspect: pictureAspect, pictureWaiting: pictureWaiting,
            verticalPicture: verticalPicture, recovering: recovering, zoom: layout.zoom,
            gimbal: layout.gimbal, headTracking: layout.headTracking, watching: watching)
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

/// The camera-vocabulary source: projects `CameraStatus`, the capture sheets,
/// focus, zoom, gimbal and head tracking into the one surface. It holds no behavior.
extension MonitorOperatorLiveSurface where Host: LiveChromeHost & GimbalPanelHost & GimbalStickHost,
    Key == CaptureSheet, NativeIdentity == MonitorOperatorLegacyCaptureIdentity, Looks == MonitorLUTLooks,
    CameraPanel == CaptureSheetPanel<Host>, PhotoRelease == MonitorCaptureButton {
    public init(host: Host, layout: LiveMonitorLayout, interaction: MonitorOperatorInteraction,
        source: MonitorOperatorLivePresentation, capture: MonitorOperatorLiveCaptureSource,
        zoom: MonitorOperatorZoomPresentation, focus: MonitorOperatorFocusSource,
        assists: MonitorOperatorLiveAssistSource, portraitAspect: Binding<PortraitFeedAspect>,
        orientation: MonitorDeviceOrientation, controlNote: Binding<String?>,
        headTracking: MonitorOperatorHeadTrackingSource? = nil,
        readLevel: ((TimeInterval, Bool) -> MonitorLevelDisplay)? = nil,
        pictureEV: (() -> EvComp?)? = nil,
        @ViewBuilder picture: @escaping () -> Picture,
        @ViewBuilder preview: @escaping (MonitorAssistSelection) -> Preview,
        @ViewBuilder lookMenu: @escaping () -> LookMenu) {
        let accessories = MonitorOperatorLegacyAccessories(host: host, layout: layout, interaction: interaction,
            source: source, zoom: zoom, focus: focus, headTracking: headTracking, orientation: orientation)
        let presented = { host.captureSheet ?? interaction.topMenu.map { $0 == .color ? CaptureSheet.color : .resolution } }
        self.init(host: host, control: host.control, session: host.operatorSession, layout: layout,
            source: .init(
                identity: { .init(monitor: nil, camera: host.control.snapshot?.session,
                    epoch: host.control.snapshot?.epoch, picture: "live") },
                available: { Set(MonitorDisplayChrome.Section.allCases) },
                picture: { .init(aspect: source.pictureAspect, waiting: source.pictureWaiting,
                    vertical: source.verticalPicture, flipped: host.livePictureViewFlip, recovering: source.recovering) },
                status: { Self.status(host, portrait: layout.viewport.height > layout.viewport.width) },
                cameraBattery: {
                    host.control.snapshot.flatMap { MonitorOperatorPowerReading.camera($0.power) }
                },
                capture: {
                    .captureSheetHost(host, section: .cameraValues, presentedSheet: presented,
                        open: { sheet in
                            if sheet == .resolution { interaction.topMenu = interaction.topMenu == .recFormat ? nil : .recFormat }
                            else if sheet == .color { interaction.topMenu = interaction.topMenu == .color ? nil : .color }
                            else { host.captureSheet = CaptureReadoutAdmission.replacing(host.captureSheet,
                                with: CaptureReadoutAdmission.opening(sheet, isPhoto: host.cameraStatus.isPhoto)) }
                        }, dismiss: { host.captureSheet = nil; interaction.topMenu = nil })
                },
                record: {
                    .init(photo: host.cameraStatus.isPhoto, confirm: capture.confirmRecording, busy: capture.busy(),
                        openMode: { host.captureSheet = .mode }, external: nil)
                },
                exposure: {
                    if host.sessionRecovery.isRecovering { return ExposureMeterReading(cameraValue: nil) }
                    if let metered = host.cameraStatus.meteredEv { return ExposureMeterReading(cameraValue: metered) }
                    return ExposureMeterReading(cameraValue: pictureEV?(), imageEstimated: true)
                },
                level: readLevel,
                audio: {
                    guard !source.watching, host.controlCapabilities.liveAudioLevels.isShown, !host.cameraStatus.isPhoto,
                        let levels = host.cameraStatus.audioMeters else { return nil }
                    return .init(levels: levels, caption: host.cameraStatus.audioChannel?.label)
                },
                readOnly: { host.sessionLocked }, borrowed: { host.multiviewBorrowed },
                returnToStage: host.multiviewExit, coverOpen: { host.coverOpen }, note: controlNote,
                settings: host.openSettings, media: host.openMedia),
            assists: .init(scopes: assists,
                tools: {
                    MonitorAssistSelection.toolbarCases
                        + (host.cameraStatus.isPhoto || !host.controlCapabilities.liveAudioLevels.isShown ? [] : [.audioMeters])
                }, rendered: { nil }, fitted: { [] }, signalOptions: .init(),
                usage: Binding(get: { host.assistToolUsage }, set: { host.assistToolUsage = $0 }),
                usageSeed: MonitorToolUsage.fieldMonitorSeed, toggle: host.assist.toggle),
            views: accessories.views, portraitAspect: portraitAspect, picture: picture,
            cameraPanel: { key, popup in
                let camera = host.control.snapshot?.session, epoch = host.control.snapshot?.epoch
                CaptureSheetPanel<Host>(sheet: key, maximumHeight: popup.maximumHeight,
                    isPresented: {
                        host.control.snapshot?.session == camera && host.control.snapshot?.epoch == epoch && presented() == key
                    },
                    onSelectRecordingCategory: [.resolution, .color, .mode].contains(key) ? { host.captureSheet = $0 } : nil,
                    showsRecordingCategories: layout.viewport.height > layout.viewport.width,
                    controlsEnabled: !host.sessionLocked, chromeless: true) { host.captureSheet = nil }
            }, photoRelease: { diameter in
                MonitorCaptureButton(control: host.control, diameter: diameter,
                    enabled: !host.operatorSession.locked && !host.sessionLocked, busy: capture.busy(), photo: true,
                    confirm: capture.confirmRecording, haptics: host.hapticsEnabled, takePhoto: capture.takePhoto,
                    openMode: { host.captureSheet = .mode })
            }, preview: preview, lookMenu: lookMenu)
    }

    private static func status(_ host: Host, portrait: Bool) -> MonitorOperatorLiveStatus<CaptureSheet, MonitorDisplayChrome.Section> {
        let value = host.cameraStatus
        let photo = value.isPhoto
        let recordingFormat = host.control.snapshot.map(MonitorCapturePresentation.recordingFormat)
        let formatLabel = recordingFormat.flatMap(MonitorCapturePresentation.recordingLabel)
        func row(_ key: CaptureSheet, _ title: String, _ text: String,
            _ section: MonitorDisplayChrome.Section? = nil, _ identifier: String) -> MonitorOperatorLiveReadout<CaptureSheet, MonitorDisplayChrome.Section> {
            .init(id: key, title: title, value: text, section: section, accessibilityIdentifier: identifier)
        }
        // The one shared storage cycle (A5-11): free space, percentage, then estimated time.
        let storageForms = StorageReadoutCycle.forms(host.control.snapshot?.storage, photo: photo)
        let storageText = storageForms[0]
        let storage = host.chromeSectionMounts(.storage)
            ? row(.resolution, "Storage remaining", storageText, .storage, "monitor.storage") : nil
        let format = host.chromeSectionMounts(.format) ? [row(photo ? .mode : .resolution,
            photo ? "Shooting mode" : "Recording format",
            photo ? host.currentShootingMode?.label(for: host.connectedBody) ?? "Photo" : formatLabel ?? "--",
            .format, photo ? "monitor.capture.mode" : "monitor.capture.format")] : []
        let setup = row(photo ? .mode : .resolution, photo ? "Shooting mode" : "Recording options",
            photo ? "MODE" : formatLabel ?? "REC SETUP",
            .format, photo ? "monitor.capture.mode" : "monitor.capture.format")
        let color = !photo && host.chromeSectionMounts(.color)
            ? row(.color, "Color mode", recordingFormat?.profile ?? "--", .color, "monitor.capture.color") : nil
        let mode = !photo ? row(.mode, "Shooting mode", host.currentShootingMode?.label(for: host.connectedBody) ?? "Video",
            nil, "monitor.capture.mode") : nil
        // The single-camera clock slot follows the DISP section (placeholder by declared precision
        // when the body has no timecode, as main showed it); Multi View tiles follow the declaration.
        return .init(recording: host.liveStatus, showsTimecode: host.chromeSectionMounts(.timecode) && !photo,
            showsRecording: host.chromeSectionMounts(.recReadout) && !photo, storage: storage, format: format,
            fps: host.chromeSectionMounts(.batteries) ? host.liveFPS : nil,
            signalBars: host.chromeSectionMounts(.batteries) ? host.liveSignalBars : nil, fpsSection: .batteries,
            portraitFormat: setup, portraitCaption: photo ? nil : recordingFormat?.profile,
            color: color, mode: mode,
            storageAlternatives: Array(storageForms.dropFirst()),
            headerAccent: host.controlCapabilities.headerAccent)
    }
}

/// Coherent native focus and motion content, borrowed by the common live owner. This adapter
/// produces no status, system rail, assist palette, inspector or camera-popup chrome. Each
/// view reads its host state in its own body.
@MainActor private struct MonitorOperatorLegacyAccessories<Host: LiveChromeHost & GimbalPanelHost & GimbalStickHost> {
    let host: Host
    let layout: LiveMonitorLayout
    let interaction: MonitorOperatorInteraction
    let source: MonitorOperatorLivePresentation
    let zoom: MonitorOperatorZoomPresentation
    let focus: MonitorOperatorFocusSource
    let headTracking: MonitorOperatorHeadTrackingSource?
    let orientation: MonitorDeviceOrientation

    var views: MonitorOperatorBodyViews {
        .init(feedMarks: AnyView(MonitorOperatorLiveMarks(host: host, focus: focus, aspect: source.pictureAspect)),
            feedGestures: AnyView(MonitorOperatorFeedGestures(accessories: self)),
            focusControls: AnyView(MonitorOperatorFocusContent(accessories: self)),
            motion: .init(controls: AnyView(MonitorOperatorMotionContent(accessories: self, part: .controls)),
                editor: AnyView(MonitorOperatorMotionContent(accessories: self, part: .editor)),
                feedback: AnyView(MonitorOperatorMotionContent(accessories: self, part: .feedback)),
                dimmed: interaction.zoomVisible, covering: interaction.zoomMounted))
    }

    var editing: MonitorDisplayMode? { host.chromeEditorMode }
    var locked: Bool { host.operatorSession.locked }
    var interactive: Bool { !host.isEditingChrome }
    var visible: Bool { !host.coverOpen || host.isEditingChrome }
    /// Every picker, top or bottom, hides the zoom chip and the gimbal stick (Compose counts its
    /// format and color sheets the same way).
    var capturePresented: Bool { host.captureSheet != nil || host.captureDrum != nil || interaction.topMenu != nil }
    var showsGimbal: Bool { source.gimbal == true && host.chromeSectionMounts(.gimbalStick) }
    var cluster: GimbalCluster { layout.gimbalCluster(showGimbalButton: showsGimbal) }
    func rect(_ region: MonitorLayoutRegion) -> CGRect {
        CGRect(x: region.x, y: region.y, width: region.width, height: region.height)
    }
}

private struct MonitorOperatorFocusContent<Host: LiveChromeHost & GimbalPanelHost & GimbalStickHost>: View {
    let accessories: MonitorOperatorLegacyAccessories<Host>
    var body: some View {
        let a = accessories
        MonitorOperatorFocusControls(host: a.host, focus: a.focus, layout: a.layout, interactive: a.interactive && !a.locked)
        if let headTracking = a.headTracking, headTracking.enabled, let pose = headTracking.readPose() {
            VStack(alignment: .leading, spacing: 6) {
                LiveHeadTrackAxisDials<Host.Palette>(pose: pose)
                if !headTracking.readIMU().isEmpty {
                    Text(headTracking.readIMU()).font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(Host.Palette.text).multilineTextAlignment(.leading)
                        .frame(maxWidth: 220, alignment: .leading).padding(.horizontal, 8).padding(.vertical, 6)
                        .liveChromeGlass(in: Capsule())
                }
            }.position(x: a.layout.onFeed.minX + 118, y: a.layout.onFeed.minY + 118)
                .zIndex(5).allowsHitTesting(false).transaction { $0.animation = nil }
        }
    }
}

private struct MonitorOperatorMotionContent<Host: LiveChromeHost & GimbalPanelHost & GimbalStickHost>: View {
    enum Part { case controls, editor, feedback }
    let accessories: MonitorOperatorLegacyAccessories<Host>
    let part: Part
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        switch part {
        case .controls: controls
        case .editor: editor
        case .feedback: feedback
        }
    }

    @ViewBuilder private var controls: some View {
        let a = accessories, host = a.host, interaction = a.interaction
        if a.source.zoom == true && host.chromeSectionMounts(.zoomChip) {
            ZoomChip<Host>(onOpenDial: openZoom)
                .chromeEditable(.zoomChip, editing: a.editing, in: Host.self).liveModuleFrame(a.rect(a.cluster.zoom))
                .opacity(a.capturePresented ? 0 : 1).allowsHitTesting(!a.locked && !a.capturePresented)
                .accessibilityHidden(a.capturePresented || !a.visible || interaction.zoomMounted).zIndex(2)
        }
        if a.showsGimbal {
            LiveGimbalButton<Host, Host.Palette>().liveModuleFrame(a.rect(a.cluster.controls))
                .opacity(a.capturePresented ? 0 : 1).allowsHitTesting(!a.locked && !a.capturePresented)
                .accessibilityHidden(a.capturePresented || !a.visible || interaction.zoomMounted).zIndex(2)
            LiveGimbalStick<Host, Host.Palette>(enabled: !a.locked && !host.coverOpen && a.interactive && !a.capturePresented,
                frame: a.rect(a.cluster.stick), feed: a.layout.feed)
                .id("live-gimbal-stick").transaction(value: a.orientation) { $0.animation = nil }
                .chromeEditable(.gimbalStick, editing: a.editing, in: Host.self).liveModuleFrame(a.rect(a.cluster.stick))
                .opacity(a.capturePresented ? 0 : 1)
                .accessibilityHidden(a.capturePresented || !a.visible || interaction.zoomMounted).zIndex(3)
        }
        if a.source.headTracking == true, let headTracking = a.headTracking, headTracking.enabled,
            !a.locked, a.interactive, !host.coverOpen {
            HeadTrackCalibrateButton<Host.Palette>(title: headTracking.title, onTap: headTracking.calibrate)
                .liveModuleFrame(a.layout.gimbalCalibrate).opacity(a.capturePresented ? 0 : 1)
                .allowsHitTesting(!a.capturePresented && !interaction.zoomMounted)
                .accessibilityHidden(a.capturePresented || !a.visible || interaction.zoomMounted).zIndex(3)
        }
    }

    @ViewBuilder private var editor: some View {
        let a = accessories
        if a.interactive, a.showsGimbal, a.host.liveGimbalPanel == .sheet, !a.locked {
            LiveGimbalSheetHost<Host>(layout: a.layout, cluster: a.cluster)
        }
        if a.interaction.zoomMounted, a.interactive, !a.locked {
            MonitorOperatorZoomDial<Host>(layout: a.layout, interaction: a.interaction, source: a.zoom, onClose: closeZoom)
        }
    }

    @ViewBuilder private var feedback: some View {
        let a = accessories, host = a.host, interaction = a.interaction
        if a.showsGimbal, a.interactive, !a.locked, !host.coverOpen {
            LiveGimbalOverlay<Host, Host.Palette>(layout: a.layout, feed: a.layout.onFeed,
                joystickBounds: host.chromeSectionMounts(.gimbalStick) && !a.capturePresented ? a.rect(a.cluster.stick) : .zero,
                zoomBounds: a.source.zoom == true && host.chromeSectionMounts(.zoomChip) && !a.capturePresented ? a.rect(a.cluster.zoom) : .zero,
                coveredByZoom: interaction.zoomMounted)
                .opacity(interaction.zoomVisible ? 0.16 : 1)
                .animation(MonitorMotion.dim(reduceMotion), value: interaction.zoomVisible)
                .allowsHitTesting(host.liveChromeInteractive && !interaction.zoomMounted)
        }
    }

    private func openZoom() { accessories.interaction.openZoom(host: accessories.host, motion: Bindable(accessories.host).liveGimbalPanel) }
    private func closeZoom() { accessories.interaction.closeZoom(host: accessories.host, reduceMotion: reduceMotion) }
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

private struct MonitorOperatorFeedGestures<Host: LiveChromeHost & GimbalPanelHost & GimbalStickHost>: View {
    let accessories: MonitorOperatorLegacyAccessories<Host>
    private var host: Host { accessories.host }
    private var layout: LiveMonitorLayout { accessories.layout }
    private var source: MonitorOperatorLivePresentation { accessories.source }
    var body: some View {
        let value = accessories.focus.read()
        let cluster = accessories.cluster
        let headTracking = accessories.headTracking?.enabled == true
        let enabled = !accessories.locked && !host.coverOpen && accessories.interactive
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

#endif
