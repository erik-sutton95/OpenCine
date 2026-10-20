#if os(iOS)
    import MonitorPresentation
    import MonitorUI
    import OpenCineAppKit
    import OpenCineCameraVocabulary
    import OpenCineCore
    import OpenCineMedia
    import SwiftUI
    import UIKit

    public enum CaptureSheet: String, Identifiable, Sendable {
        case iso, shutter, wb, focus, aperture, exposure, audio
        case mode
        case resolution, color
        public var id: String { rawValue }
        /// Format, color and shooting mode open from the top edge in the mockup.
        public var isTopAnchored: Bool {
            switch self {
            case .resolution, .color, .mode: true
            default: false
            }
        }
    }

    /// The live view's coordinate space, which capture backdrops hit-test in.
    public enum LiveCanvasSpace {
        public static let name = "liveCanvas"
    }

    public struct LiveCaptureTileFramesKey: PreferenceKey {
        public static var defaultValue: [CaptureSheet: CGRect] { [:] }
        public static func reduce(
            value: inout [CaptureSheet: CGRect],
            nextValue: () -> [CaptureSheet: CGRect]
        ) {
            value.merge(nextValue(), uniquingKeysWith: { $1 })
        }
    }

    /// Persistent camera drawers use the well of the control that opened them.
    /// The host may keep visible controls touchable; every other outside tap
    /// dismisses the drawer.
    public struct CaptureSheetPickerHost<Host: CaptureSheetHost>: View {
        @Binding public var sheet: CaptureSheet?
        @Environment(\.monitorPresentationIsVisible) private var presentationVisible
        public var frames: [CaptureSheet: CGRect]
        public var passthroughFrames: [CGRect] = []
        public var bar: CGRect
        public var viewport: CGSize
        public var safeArea: EdgeInsets = EdgeInsets()
        public var ceilingY: CGFloat = 0
        public var bottomY: CGFloat? = nil
        public var topDeckMaxY: CGFloat = 0
        public init(
            sheet: Binding<CaptureSheet?>, frames: [CaptureSheet: CGRect],
            passthroughFrames: [CGRect] = [], bar: CGRect, viewport: CGSize,
            safeArea: EdgeInsets = EdgeInsets(), ceilingY: CGFloat = 0, bottomY: CGFloat? = nil,
            topDeckMaxY: CGFloat = 0
        ) {
            _sheet = sheet
            self.frames = frames
            self.passthroughFrames = passthroughFrames
            self.bar = bar
            self.viewport = viewport
            self.safeArea = safeArea
            self.ceilingY = ceilingY
            self.bottomY = bottomY
            self.topDeckMaxY = topDeckMaxY
        }

        public var body: some View {
            let current = sheet
            let edge: MonitorCapturePopupEdge = current?.isTopAnchored == true ? .top : .bottom
            let topY: CGFloat? =
                edge == .top
                ? (viewport.height > viewport.width ? topDeckMaxY + 6 : 0) : nil
            return ZStack(alignment: .topLeading) {
                if sheet != nil {
                    Color.clear
                        .contentShape(
                            CapturePickerBackdrop(frames: Array(frames.values) + passthroughFrames),
                            eoFill: true
                        )
                        .onTapGesture(coordinateSpace: .named(LiveCanvasSpace.name)) { location in
                            handleBackdrop(at: location)
                        }
                }
                CapturePopupContainer(
                    viewport: viewport, safeArea: safeArea, ceilingY: ceilingY, bottomY: bottomY,
                    edge: edge, topY: topY
                ) { place in
                    if let current = sheet {
                        CaptureSheetPanel<Host>(
                            sheet: current, maximumHeight: CGFloat(place.maximumHeight),
                            bottomPadding: CGFloat(place.bottomPadding),
                            topPadding: CGFloat(place.topPadding),
                            topCornerRadius: CGFloat(place.topCornerRadius),
                            bottomCornerRadius: CGFloat(place.bottomCornerRadius),
                            edge: place.edge,
                            isPresented: { sheet == current },
                            onSelectRecordingCategory: [.resolution, .color, .mode].contains(
                                current)
                                ? { sheet = $0 } : nil,
                            showsRecordingCategories: viewport.height > viewport.width
                        ) { sheet = nil }
                        .id(current)
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("monitor.capture.panel")
                        .accessibilityHidden(!presentationVisible)
                        .transition(.identity)
                    }
                }
            }
            .frame(width: viewport.width, height: viewport.height, alignment: .topLeading)
            .allowsHitTesting(sheet != nil)
        }

        private func handleBackdrop(at location: CGPoint) {
            if let hit = frames.first(where: {
                $0.value.insetBy(dx: -10, dy: -8).contains(location)
            })?
            .key {
                sheet = hit == sheet ? nil : hit
            } else {
                sheet = nil
            }
        }
    }

    public struct CaptureSheetModal<Host: CaptureSheetHost>: View {
        public let sheet: CaptureSheet
        public var onClose: (() -> Void)? = nil
        @Environment(Host.self) private var host

        public init(sheet: CaptureSheet, onClose: (() -> Void)? = nil) {
            self.sheet = sheet
            self.onClose = onClose
        }

        public var body: some View {
            CaptureSheetPanel<Host>(sheet: sheet) {
                if let onClose {
                    onClose()
                } else {
                    host.captureSheet = nil
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 10)
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .presentationBackground(Host.Palette.background)
            .preferredColorScheme(.dark)
        }
    }

    public struct CaptureSheetPanel<Host: CaptureSheetHost>: View {
        public let sheet: CaptureSheet
        public var maximumHeight: CGFloat = .infinity
        public var bottomPadding: CGFloat = 12
        public var topPadding: CGFloat = 11
        public var topCornerRadius: CGFloat = 16
        public var bottomCornerRadius: CGFloat = 0
        public var edge: MonitorCapturePopupEdge = .bottom
        public var isPresented: () -> Bool = { true }
        /// Visual state from the readout's existing gesture. The panel is read-only
        /// for its entire lifetime when this is present, including initial seeding.
        public var preview: CaptureDrumPresentation? = nil
        public var onSelectRecordingCategory: ((CaptureSheet) -> Void)? = nil
        public var showsRecordingCategories: Bool = false
        public var prefixContent: AnyView? = nil
        public var subtitleOverride: String? = nil
        public var controlsEnabled = true
        /// Controls only: a host such as Multiview's side panel owns glass, header and scrolling.
        public var chromeless = false
        public var onClose: () -> Void
        @Environment(Host.self) private var host
        @Environment(\.interfaceLocked) private var interfaceLocked
        @Environment(\.scenePhase) private var scenePhase
        @Environment(\.monitorWindowGeometry) private var windowGeometry
        @State private var selectedMode = 0
        @State private var selectedAspect: VideoAspect = .sixteenNine
        @State private var drumSelection = ""
        @State private var lastApplied = ""
        @State private var tintDraft: Double?
        @State private var drumSendTask: Task<Void, Never>?
        @State private var deferredDrum = MonitorDeferredSelection<DrumContext>()
        @State private var appeared = false
        @State private var drumInteractionRevision: UInt64 = 0
        @State private var commonField: MonitorCaptureField?
        @State private var audioSourceID: CaptureAudioSourceID?
        @State private var audioRefusal: String?

        private struct DrumContext: Hashable {
            let cameraID: UUID?
            let phase: String
            let sheet: CaptureSheet
            let mode: Int
            let color: ColorMode?
            let fps: Int
            let shutterDenoms: [Int]
            let snapshotIdentity: CaptureQuickSnapshot.SourceIdentity?
            let focusTrack: FocusTrackMode?
            let options: [String]
        }

        private struct DrumIdentity: Hashable {
            let context: DrumContext
            let revision: UInt64
            let presented: Bool
        }

        private var controls: some View {
            VStack(alignment: .leading, spacing: 8) {
                if let prefixContent { prefixContent }
                Group {
                    if let held = preview {
                        if let field = held.snapshot.commonField {
                            fieldLadder(
                                field, choices: field.choices, enabled: false,
                                previewPosition: held.position, previewSelection: held.selection)
                        } else {
                            CaptureDrumWheel<Host>(
                                options: held.snapshot.options,
                                selection: .constant(held.selection),
                                markedValues: held.snapshot.marked, isInteractive: false)
                        }
                    } else {
                        content
                        if sheet != .resolution, !modeTabs.isEmpty { modeBar }
                        if let onSelectRecordingCategory,
                            recordingCategories.count > 1,
                            MonitorCapturePopupChrome.showsRecordingCategoryTabs(
                                portrait: showsRecordingCategories, kind: .details)
                        {
                            MonitorCaptureTabs(
                                options: recordingCategories, selection: sheet,
                                title: {
                                    $0 == .resolution ? "Format" : $0 == .color ? "Color" : "Mode"
                                }
                            ) { category in
                                guard canApplyDrum else { return }
                                cancelDrumSend()
                                onSelectRecordingCategory(
                                    CaptureReadoutAdmission.opening(
                                        category, isPhoto: isPhoto))
                            }
                        }
                        if sheet == .iso, host.controlCapabilities.nativeISO.hop == true {
                            nativeIsoHopToggle
                        }
                        if isEvSheet { facePriorityToggle }
                    }
                }.disabled(!controlsEnabled)
            }
        }

        private var drumOptions: [String] {
            switch sheet {
            case .iso: isIsoAutoTab ? isoAutoDrumLabels : isoDrumLabels
            case .shutter:
                isEvSheet ? evLabels : (isAngleSheet ? shutterAngleLabels : shutterLabels)
            default: []
            }
        }

        private var drumContext: DrumContext {
            DrumContext(
                cameraID: host.connectedCameraID, phase: host.sessionPhaseLabel,
                sheet: sheet, mode: selectedMode, color: host.cameraStatus.colorMode,
                fps: host.cameraStatus.fps, shutterDenoms: shutterDenoms,
                snapshotIdentity: host.quickSnapshot(sheet)?.sourceIdentity,
                focusTrack: sheet == .focus ? host.cameraStatus.focusTrack : nil,
                options: drumOptions)
        }

        private var canApplyDrum: Bool {
            controlsEnabled && preview == nil && appeared && isPresented() && scenePhase == .active
                && !interfaceLocked && !host.sessionLocked
        }

        public init(
            sheet: CaptureSheet, maximumHeight: CGFloat = .infinity, bottomPadding: CGFloat = 12,
            topPadding: CGFloat = 11, topCornerRadius: CGFloat = 16,
            bottomCornerRadius: CGFloat = 0,
            edge: MonitorCapturePopupEdge = .bottom, isPresented: @escaping () -> Bool = { true },
            preview: CaptureDrumPresentation? = nil,
            onSelectRecordingCategory: ((CaptureSheet) -> Void)? = nil,
            showsRecordingCategories: Bool = false, prefixContent: AnyView? = nil,
            subtitleOverride: String? = nil, controlsEnabled: Bool = true, chromeless: Bool = false,
            onClose: @escaping () -> Void
        ) {
            self.sheet = sheet
            self.maximumHeight = maximumHeight
            self.bottomPadding = bottomPadding
            self.topPadding = topPadding
            self.topCornerRadius = topCornerRadius
            self.bottomCornerRadius = bottomCornerRadius
            self.edge = edge
            self.isPresented = isPresented
            self.preview = preview
            self.onSelectRecordingCategory = onSelectRecordingCategory
            self.showsRecordingCategories = showsRecordingCategories
            self.prefixContent = prefixContent
            self.subtitleOverride = subtitleOverride
            self.controlsEnabled = controlsEnabled
            self.chromeless = chromeless
            self.onClose = onClose
        }

        public var body: some View {
            // Split so the type checker handles the chain in a generic view; same modifier order.
            statusObservers(lifecycle(chrome))
        }

        private var chrome: some View {
            let kind: MonitorCapturePopupKind = preview == nil ? .details : .compact
            return Group {
                if chromeless {
                    controls
                } else {
                    MonitorCapturePanel(
                        title: headerTitle,
                        subtitle: subtitleOverride ?? kind.subtitle ?? headerSubtitle,
                        maximumHeight: maximumHeight, bottomPadding: bottomPadding,
                        topPadding: topPadding, topCornerRadius: topCornerRadius,
                        bottomCornerRadius: bottomCornerRadius, kind: kind, edge: edge,
                        close: onClose
                    ) { controls }
                }
            }
            .environment(
                \.captureDrumInteractionIdentity,
                {
                    AnyHashable(
                        DrumIdentity(
                            context: drumContext, revision: drumInteractionRevision,
                            presented: canApplyDrum))
                }
            )
            .environment(\.captureDrumPreview, preview)
            .allowsHitTesting(preview == nil)
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture().onEnded {})
        }

        private func lifecycle(_ content: some View) -> some View {
            content
                .onAppear {
                    appeared = true
                    captureCommonField()
                    seed()
                }
                .onDisappear {
                    appeared = false
                    cancelDrumSend()
                }
                .onChange(of: canApplyDrum) { _, active in
                    if !active { cancelDrumSend(reseat: true) }
                }
                .onChange(of: drumContext) { _, _ in cancelDrumSend(reseat: true) }
                .onChange(of: windowGeometry) { _, _ in cancelDrumSend(reseat: true) }
                .onReceive(
                    NotificationCenter.default.publisher(
                        for: UIDevice.orientationDidChangeNotification)
                ) { _ in cancelDrumSend(reseat: true) }
                .onReceive(
                    NotificationCenter.default.publisher(
                        for: UIApplication.willResignActiveNotification)
                ) { _ in cancelDrumSend(reseat: true) }
                .onChange(of: sheet) { _, _ in
                    cancelDrumSend()
                    captureCommonField()
                    seed()
                }
        }

        private func statusObservers(_ content: some View) -> some View {
            content
                .onChange(of: host.control.snapshot?.capabilities[.shutter]) { _, _ in
                    // Angle and Speed are two presentations of one shutter descriptor: a mode
                    // switch republishes it, and the drum must follow the new editor.
                    guard sheet == .shutter else { return }
                    captureCommonField()
                }
                .onChange(of: host.cameraStatus.availableShutterDenoms) { _, _ in
                    guard sheet == .shutter, !isEvSheet else { return }
                    reseatShutter()
                }
                .onChange(of: host.cameraStatus.fps) { _, _ in
                    guard sheet == .shutter, !isEvSheet else { return }
                    reseatShutter()
                }
                .onChange(of: host.shutterAngleSettling) { _, _ in
                    // The end of a hold reseats the angle drum on what the camera really makes.
                    guard sheet == .shutter, !isEvSheet, isAngleSheet else { return }
                    reseatShutter()
                }
                .onChange(of: host.cameraStatus.availableIsoIndices) { _, _ in
                    guard sheet == .iso else { return }
                    reseatIso()
                }
                .onChange(of: host.cameraStatus.expoMode) { _, _ in
                    guard sheet == .shutter else { return }
                    cancelDrumSend()
                    if host.cameraStatus.expoMode != .auto {
                        selectedMode =
                            host.shutterUsesAngle && !isPhoto ? 1 : 0
                    }
                    reseatShutterOrEv()
                }
                .onChange(of: host.cameraStatus.evComp) { _, _ in
                    guard isEvSheet else { return }
                    reseatEv()
                }
                .onChange(of: host.facePriorityExposureEnabled) { _, _ in
                    guard isEvSheet else { return }
                    reseatEv()
                }
                .onChange(of: host.cameraStatus.colorMode) { _, _ in
                    if sheet == .color { seed() }
                    guard sheet == .iso else { return }
                    reseatIso()
                }
                .onChange(of: pickerVideoFormats) { _, _ in
                    guard sheet == .resolution else { return }
                    guard !host.formatPinActive else { return }
                    seed()
                }
                .onChange(of: host.cameraStatus.videoFormat) { _, _ in
                    guard sheet == .resolution else { return }
                    guard !host.formatPinActive else { return }
                    seed()
                }
                .onChange(of: isPhoto) { _, photo in
                    if photo, sheet == .resolution || sheet == .color, let onSelectRecordingCategory
                    {
                        onSelectRecordingCategory(.mode)
                    }
                    if photo, sheet == .shutter, !isEvSheet {
                        selectedMode = 0
                        reseatShutterOrEv()
                    }
                }
                .onChange(of: drumSelection) { _, newValue in
                    applyDrum(newValue)
                }
        }

        @ViewBuilder private var content: some View {
            switch sheet {
            case .iso:
                VStack(alignment: .leading, spacing: 12) {
                    if isIsoAutoTab {
                        CaptureDrumWheel<Host>(
                            options: isoAutoDrumLabels, selection: $drumSelection
                        )
                        .id(isoAutoDrumLabels)
                    } else {
                        commonDrum(.iso, marked: isoMarkedLabels)
                    }
                }
            case .shutter:
                if isEvSheet {
                    VStack(alignment: .leading, spacing: 12) {
                        if host.captureRouting.commonExposureCompensation {
                            commonDrum(
                                .exposureCompensation,
                                editingAllowed: !host.facePriorityExposureEnabled)
                        } else {
                            CaptureDrumWheel<Host>(
                                options: evLabels, selection: $drumSelection,
                                isInteractive: !host.facePriorityExposureEnabled
                            )
                            .id(evLabels)
                        }
                    }
                } else if isAngleSheet {
                    CaptureDrumWheel<Host>(options: shutterAngleLabels, selection: $drumSelection)
                        .id(shutterAngleLabels)
                } else {
                    commonDrum(.shutter)
                }
            case .wb:
                if selectedMode == 0 {
                    let awbLocked = host.autoWhiteBalanceLocked
                    choiceDrum(
                        CaptureLists.whiteBalanceModeLabels(
                            offersLock: awbLocked || host.canLockAutoWhiteBalance),
                        selected: CaptureLists.whiteBalanceModeSelection(
                            host.displayStatus.whiteBalance, awbLocked: awbLocked)
                    ) { label in
                        if label == CaptureLists.awbLock {
                            host.commit(.autoWhiteBalanceLock, from: .sheet(commonField))
                        } else if label == WhiteBalanceMode.auto.label {
                            host.commit(.whiteBalanceAuto, from: .sheet(commonField))
                        } else {
                            host.commit(
                                .whiteBalanceCustom(kelvin: currentKelvin, tint: currentTint),
                                from: .sheet(commonField))
                        }
                    }
                } else if selectedMode == 1 {
                    commonDrum(.whiteBalance)
                } else {
                    tintPad
                }
            case .focus:
                if host.controlCapabilities.focus.isOffered {
                    focusRows
                }
            case .aperture:
                if host.controlCapabilities.iris.isOffered {
                    choiceDrum(
                        CaptureLists.apertureStrategies(from: host.cameraStatus).map(\.label),
                        selected: host.cameraStatus.apertureStrategy?.label
                    ) { label in
                        if let strategy = ApertureStrategy.allCases.first(where: {
                            $0.label == label
                        }) {
                            host.commit(.aperture(strategy), from: .sheet(commonField))
                        }
                    }
                }
            case .exposure:
                let aeLocked = host.autoExposureLocked
                choiceDrum(
                    CaptureLists.exposureLabels(aeLocked: aeLocked),
                    selected: CaptureLists.exposureSelection(
                        host.cameraStatus.expoMode, aeLocked: aeLocked)
                ) { label in
                    if let mode = ExpoMode.allCases.first(where: { $0.label == label }) {
                        host.commit(.expoMode(mode), from: .sheet(commonField))
                    }
                }
            case .audio:
                audioBody
            case .mode:
                choiceDrum(
                    CaptureLists.operatorShootingModes(
                        from: host.cameraStatus, model: connectedBody
                    )
                    .map { $0.label(for: connectedBody, in: host.labelProfile) },
                    selected: host.currentShootingMode?.label(
                        for: connectedBody, in: host.labelProfile),
                    isInteractive: !host.cameraStatus.isRecording
                ) { label in
                    guard !host.cameraStatus.isRecording else { return }
                    if let mode = CaptureLists.operatorShootingModes(
                        from: host.cameraStatus, model: connectedBody
                    ).first(where: {
                        $0.label(for: connectedBody, in: host.labelProfile) == label
                    }), mode != .livePhoto {
                        host.commit(.shootingMode(mode), from: .sheet(commonField))
                    }
                }
            case .resolution:
                if let panel = host.nativeCapturePanel(.resolution, enabled: canApplyDrum) {
                    panel
                } else if isPhoto {
                    Text("Photo")
                        .font(MonitorTheme.font(16, weight: .semibold))
                        .foregroundStyle(MonitorTheme.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityLabel("Photo")
                } else {
                    formatPicker
                }
            case .color:
                // One popup for codec and colour: the codec choices the camera offers, then its
                // colour choices. The colour drum keeps each camera's existing behaviour.
                CaptureCodecColorPanel(
                    choices: host.recordingCodecColor,
                    enabled: canApplyDrum && !host.cameraStatus.isRecording,
                    selectCodec: { id in
                        guard canApplyDrum, !host.cameraStatus.isRecording else { return }
                        host.commitRecordingCodec(id)
                    }
                ) {
                    if let panel = host.nativeCapturePanel(.color, enabled: canApplyDrum) { panel }
                    else { CaptureDrumWheel<Host>(options: colorWheelLabels, selection: $drumSelection) }
                }
            }
        }

        private var focusRows: some View {
            let selected =
                preview.map { held in
                    host.focusOptions.first { $0.chip == held.selection }
                } ?? CaptureLists.focusOption(from: host.cameraStatus)
            return VStack(alignment: .leading, spacing: 8) {
                choiceDrum(host.focusOptions.map(\.chip), selected: selected?.chip) { value in
                    guard let option = host.focusOptions.first(where: { $0.chip == value }),
                        canApplyDrum
                    else { return }
                    host.commit(.focus(option, label: value), from: .sheet(commonField))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(CaptureLists.focusTitle(selected))
                        .font(MonitorTheme.font(11.5, weight: .semibold)).foregroundStyle(
                            MonitorTheme.text)
                    Text(CaptureLists.focusHelp(selected))
                        .font(MonitorTheme.font(9.5)).lineSpacing(2).foregroundStyle(
                            MonitorTheme.faint
                        )
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 9)
                .overlay(alignment: .top) { Color.white.opacity(0.08).frame(height: 1) }
            }
        }

        @ViewBuilder private var audioBody: some View {
            if let service = host.audioService, service.fields.indices.contains(selectedMode) {
                let field = service.fields[selectedMode]
                choiceDrum(field.choices.map(\.label), selected: field.observed?.label,
                    isInteractive: field.isEditable && service.sourceID == audioSourceID) { label in
                    guard let current = host.audioService, current.sourceID == audioSourceID,
                        let currentField = current.fields.first(where: { $0.id == field.id }),
                        currentField.isEditable,
                        let value = currentField.choices.first(where: { $0.label == label })
                    else { audioRefusal = "Audio control unavailable"; return }
                    switch current.commit(value) {
                    case .submitted: audioRefusal = nil
                    case .unavailable: audioRefusal = "Audio control unavailable"
                    case .refused: audioRefusal = "Audio control refused"
                    }
                }
            } else {
                Text("Audio controls unavailable").foregroundStyle(MonitorTheme.faint)
            }
            if let audioRefusal {
                Text(audioRefusal).font(MonitorTheme.font(10)).foregroundStyle(MonitorTheme.faint)
            }
        }

        private var tintPad: some View {
            CaptureDrumWheel<Host>(
                options: (-100...100).map(String.init),
                selection: Binding(
                    get: { tintDraft.map { String(Int($0.rounded())) } ?? "" },
                    set: { value in
                        guard let tint = Int(value), (-100...100).contains(tint) else { return }
                        tintDraft = Double(tint)
                        applyTint(tint)
                    })
            )
            .onAppear {
                tintDraft = host.displayStatus.whiteBalanceTint.map(Double.init)
            }
            .onChange(of: host.displayStatus.whiteBalanceTint) { _, tint in
                tintDraft = tint.map(Double.init)
            }
        }

        private var facePriorityToggle: some View {
            MonitorCaptureToggle(
                "Face priority",
                help: "EV follows faces to middle gray. Several faces use the median.",
                isOn: Binding(
                    get: { host.facePriorityExposureEnabled },
                    set: { if canApplyDrum { host.facePriorityExposureEnabled = $0 } }))
        }

        private var nativeIsoHopToggle: some View {
            MonitorCaptureToggle(
                "Auto native ISO",
                help: "Hop to the curve's native ISO when the color mode changes.",
                isOn: Binding(
                    get: { host.nativeISOHopEnabled },
                    set: { if canApplyDrum { host.nativeISOHopEnabled = $0 } }))
        }

        private struct FormatSource: Hashable {
            let camera: UUID?
            let phase: String
            let snapshot: CaptureQuickSnapshot.SourceIdentity?
        }

        private var formatSource: AnyHashable {
            AnyHashable(FormatSource(camera: host.connectedCameraID, phase: host.sessionPhaseLabel,
                snapshot: host.quickSnapshot(.resolution)?.sourceIdentity))
        }

        private var formatPicker: some View {
            let source = formatSource
            return CaptureFormatPicker(
                choices: CaptureVideoFormatChoices.make(available: pickerVideoFormats, current: currentVideoFormat),
                current: currentVideoFormat, enabled: canApplyDrum && !pickerVideoFormats.isEmpty,
                haptics: host.hapticsEnabled, sourceIdentity: source, followsReadback: !host.formatPinActive,
                isCurrent: { canApplyDrum && formatSource == source }
            ) { choice in
                guard canApplyDrum, formatSource == source, pickerVideoFormats.contains(choice.value) else { return }
                applyVideoFormat(resolution: choice.value.resolution, frameRate: choice.value.frameRate)
            }
        }

        private var aspectBar: some View {
            MonitorCaptureTabs(
                options: formatAspects, selection: selectedAspect,
                title: { $0.label }, select: handleAspectChange)
        }

        /// The one capture mode strip every camera's popup draws (`LadderSheet` uses it too).
        private var modeBar: some View {
            ModeBar(tabs: modeTabs, selected: selectedMode, enabled: true) { index in
                guard canApplyDrum else { return }
                selectedMode = index
                handleModeChange(index)
            }
            .environment(\.ladderOperatorHaptics, host.hapticsEnabled)
        }

        private func choiceDrum(
            _ options: [String], selected: String?, isInteractive: Bool = true,
            action: @escaping (String) -> Void
        ) -> some View {
            CaptureChoiceDrum<Host>(
                options: options, cameraValue: selected, isInteractive: isInteractive,
                canApply: canApplyDrum, action: action)
        }

        private var headerTitle: String {
            if isEvSheet { return "EXPOSURE" }
            if sheet == .color { return host.recordingCodecColor.title }
            return sheet.headerLabel
        }

        private var headerSubtitle: String {
            if isEvSheet {
                return "Compensation"
            }
            if sheet == .shutter {
                return isPhoto ? "Speed"
                    : host.shutterPanelSubtitle(selection: host.captureStripShowsPendingEdits ? .pending : .reported)
            }
            if sheet == .resolution, isPhoto {
                return "Photo"
            }
            return sheet.subtitle
        }

        private var isPhoto: Bool { host.cameraStatus.isPhoto }

        private var recordingCategories: [CaptureSheet] {
            CaptureLists.recordingCategories(isPhoto: isPhoto)
        }

        private var modeTabs: [String] {
            switch sheet {
            case .iso where offersIsoAuto: ["Auto", "Manual"]
            case .shutter where !isEvSheet && !isPhoto: ["Speed", "Angle"]
            case .wb: ["Mode", "Kelvin", "Tint"]
            case .audio: host.audioService?.fields.map(\.title) ?? []
            case .resolution where !isPhoto: formatResolutions.map(\.tabTitle)
            default: []
            }
        }

        private var offersIsoAuto: Bool {
            CaptureLists.offersIsoAuto(from: host.cameraStatus)
        }

        private var isIsoAutoTab: Bool {
            sheet == .iso && offersIsoAuto && selectedMode == 0
        }

        private var isEvSheet: Bool {
            sheet == .shutter && host.cameraStatus.expoMode == .auto
        }

        private var isAngleSheet: Bool {
            sheet == .shutter && !isEvSheet && !isPhoto && selectedMode == 1
        }

        private var isoIndices: [IsoIndex] {
            CaptureLists.isoIndices(from: host.cameraStatus)
        }

        private var shutterDenoms: [Int] {
            CaptureLists.shutterDenoms(from: host.cameraStatus)
        }

        private var shutterLabels: [String] {
            CaptureLists.shutterLabels(from: host.cameraStatus)
        }

        private var shutterAngleLabels: [String] {
            ShutterAngle.labels
        }

        private var isoDrumLabels: [String] {
            CaptureLists.isoDrumLabels(from: host.cameraStatus)
        }

        private var colorWheelLabels: [String] {
            CaptureLists.colorDrumLabels(
                offered: host.colorModes, current: host.cameraStatus.colorMode,
                family: host.bodyFamily, profile: host.labelProfile)
        }

        private var connectedBody: CameraModel? { host.connectedBody }

        private var isoAutoDrumLabels: [String] {
            // No settable auto ceiling: a single read-only "Auto" stop, like the WB drum.
            guard host.controlCapabilities.nativeISO.ceiling == true else { return ["Auto"] }
            return CaptureLists.isoAutoLabels(from: host.cameraStatus, model: connectedBody)
        }

        private var evLabels: [String] {
            CaptureLists.evLabels
        }

        /// Reference monitor `AccentDrumWheel.markedValues` - star after the native base only.
        private var isoMarkedLabels: Set<String> {
            CaptureLists.isoMarkedLabels(from: host.cameraStatus)
        }

        private var currentKelvin: Int {
            let k = host.displayStatus.whiteBalanceKelvin
            return (2_000...10_000).contains(k) ? k : 5_600
        }

        private var currentTint: Int {
            min(max(host.displayStatus.whiteBalanceTint ?? 0, -100), 100)
        }

        private func seed() {
            switch sheet {
            case .iso:
                reseatIso()
                guard preview == nil,
                    host.controlCapabilities.nativeISO.ceiling == true,
                    CaptureLists.shouldGetIsoLimit(from: host.cameraStatus)
                else { return }
                Task {
                    await host.refreshIsoLimit()
                    reseatIso()
                }
            case .shutter:
                if !isEvSheet {
                    selectedMode =
                        host.shutterUsesAngle && !isPhoto ? 1 : 0
                }
                reseatShutterOrEv()
            case .wb:
                let wb = host.displayStatus
                let mode = wb.whiteBalance?.mode
                // AWB Lock is a Mode choice, not an active Kelvin.
                let modeTab =
                    mode == nil || mode == .auto || host.autoWhiteBalanceLocked
                selectedMode = modeTab ? 0 : 1
                let k = "\(currentKelvin)K"
                drumSelection = (2_000...10_000).contains(wb.whiteBalanceKelvin) ? k : ""
                lastApplied = drumSelection
                tintDraft = wb.whiteBalanceTint.map(Double.init)
            case .audio:
                selectedMode = 0
                audioRefusal = nil
                let service = host.audioService
                audioSourceID = service?.sourceID
                if preview == nil, let service { Task { await service.refresh() } }
            case .resolution:
                selectedAspect = currentResolution?.aspect ?? formatAspects.first ?? .sixteenNine
                let tabs = formatResolutions
                selectedMode = currentResolution.flatMap { tabs.firstIndex(of: $0) } ?? 0
                drumSelection = currentVideoFormat?.frameRate.drumLabel ?? ""
                lastApplied = drumSelection
            case .color:
                selectedMode = 0
                let family = host.bodyFamily
                let live =
                    host.cameraStatus.colorMode?.label(for: family, in: host.labelProfile)
                    ?? ""
                drumSelection = colorWheelLabels.contains(live) ? live : ""
                lastApplied = drumSelection
            default:
                selectedMode = 0
            }
        }

        private func handleModeChange(_ index: Int) {
            guard canApplyDrum else { return }
            cancelDrumSend()
            switch sheet {
            case .iso where offersIsoAuto:
                if index == 0 {
                    host.commit(.isoAuto, from: .sheet(commonField))
                    reseatIsoAutoDrum()
                } else {
                    reseatIsoDiscrete()
                    // Choosing Manual is an explicit mode action. Preserve its
                    // existing first-legal-ISO fallback when camera ISO is unknown.
                    if drumSelection.isEmpty, let first = isoDrumLabels.first {
                        lastApplied = first
                        drumSelection = first
                    }
                    host.commit(.isoManual(label: drumSelection), from: .sheet(commonField))
                }
            case .shutter:
                host.shutterUsesAngle = index == 1
                // The field captured when the popup opened belongs to the other presentation (an
                // emulated angle editor, or none): Speed must edit the camera's own durations.
                captureCommonField()
                reseatShutter()
            case .wb:
                if index == 0, host.displayStatus.whiteBalance?.mode != .auto {
                    // Mode tab only; write happens on row tap.
                }
            case .resolution:
                guard let res = resolutionForTab(index) else { return }
                let rates = CamCapVideoFormat.frameRates(
                    available: pickerVideoFormats,
                    resolution: res,
                    current: currentFrameRate)
                guard let rate =
                    VideoFrameRate(drumLabel: drumSelection).flatMap({
                        rates.contains($0) ? $0 : nil
                    })
                    ?? rates.first
                    ?? currentFrameRate
                else { return }
                let next = VideoFormat(resolution: res, frameRate: rate)
                guard next != currentVideoFormat else { return }
                applyVideoFormat(resolution: next.resolution, frameRate: next.frameRate)
            default:
                break
            }
        }

        private func captureCommonField() {
            let key: SettingKey? =
                switch sheet {
                case .iso: .iso
                case .shutter:
                    isEvSheet && host.captureRouting.commonExposureCompensation
                        ? .exposureCompensation : .shutter
                case .wb: .whiteBalance
                case .focus: host.captureRouting.commonFocusMode ? .focusMode : nil
                default: nil
                }
            commonField = key.flatMap { host.control.captureField($0) }
        }

        @ViewBuilder private func commonDrum(
            _ key: SettingKey, marked: Set<String> = [], editingAllowed: Bool = true
        ) -> some View {
            if let field = commonField, field.key == key {
                let speedTab = sheet == .shutter && !isAngleSheet
                let choices = field.choices.filter { choice in
                    switch choice.value {
                    case .shutter(.angle): return !speedTab
                    case .iso(.manual), .shutter(.duration),
                        .whiteBalance(.kelvin), .exposureCompensation:
                        return true
                    default: return false
                    }
                }
                fieldLadder(field, choices: choices, marked: marked,
                    enabled: canApplyDrum && editingAllowed)
            } else {
                Text("Setting not available").foregroundStyle(MonitorTheme.muted)
            }
        }

        private func fieldLadder(
            _ field: MonitorCaptureField, choices: [MonitorCaptureChoice],
            marked: Set<String> = [], enabled: Bool,
            previewPosition: Double? = nil, previewSelection: String? = nil
        ) -> some View {
            LadderSheet(
                presentation: LadderSheetPresentation(title: "", subtitle: "", tabs: [
                    LadderTab(label: "", key: field.key,
                        ladder: CaptureLadder(current: field.label,
                            values: choices.map(\.label), marked: marked), applyOnActivate: false)
                ]), enabled: enabled, onWrite: { _ in },
                control: host.control,
                host: LadderSheetHost(selectedTab: 0, selection: previewSelection ?? field.label,
                    drum: .field(field, choices: choices), previewPosition: previewPosition,
                    onSelectTab: { _ in }, onCommitted: host.captureDrumDidCommit)
            ).environment(\.ladderOperatorHaptics, host.hapticsEnabled)
            // The drum keeps the editor it opened with (`MonitorCaptureDrum`). A new editor (the
            // Angle/Speed switch republishes the shutter descriptor) is a new drum; otherwise the
            // Speed drum stayed bound to the angle editor and read as disabled (owner 2026-10-20).
            .id(field.editor)
        }

        private func applyDrum(_ value: String) {
            guard canApplyDrum, !value.isEmpty, value != lastApplied else { return }
            if sheet == .color, host.cameraStatus.isRecording {
                if let mode = ColorMode(label: value, in: host.labelProfile),
                    mode != host.cameraStatus.colorMode
                {
                    host.commit(.colorMode(mode), from: .sheet(commonField))
                }
                return
            }
            lastApplied = value
            switch sheet {
            case .iso:
                if isIsoAutoTab {
                    guard host.controlCapabilities.nativeISO.ceiling == true,
                        let limit = CaptureLists.isoLimit(
                            from: value, status: host.cameraStatus, model: connectedBody)
                    else { return }
                    enqueueDrumSend(value) {
                        host.commit(.isoLimit(limit), from: .sheet(commonField))
                    }
                    return
                }
                // Manual ISO is owned by MonitorCaptureDrum and its captured descriptor editor.
                return
            case .shutter:
                if isEvSheet {
                    guard !host.facePriorityExposureEnabled else { return }
                    guard let ev = EvComp(label: value) else { return }
                    enqueueDrumSend(value) { host.commit(.ev(ev), from: .sheet(commonField)) }
                    return
                }
                if isAngleSheet {
                    guard let degrees = ShutterAngle.parse(value) else { return }
                    enqueueDrumSend(value) {
                        host.commit(.shutterAngle(degrees), from: .sheet(commonField))
                    }
                    return
                }
                // Native duration is owned by MonitorCaptureDrum.
                return
            case .wb:
                // Kelvin is owned by MonitorCaptureDrum; lock/tint remain integration controls.
                return
            case .resolution:
                guard let rate = VideoFrameRate(drumLabel: value),
                    formatRates.contains(rate)
                else { return }
                guard let resolution = resolutionForTab(selectedMode) else { return }
                applyVideoFormat(resolution: resolution, frameRate: rate)
            case .color:
                // The drum's extra entry is the current mode: selecting it sends nothing.
                guard let mode = ColorMode(label: value, in: host.labelProfile),
                    mode != host.cameraStatus.colorMode
                else { return }
                host.commit(.colorMode(mode), from: .sheet(commonField))
            default:
                break
            }
        }

        /// Latest-wins: scrubbing must not enqueue a SET per detent.
        private func enqueueDrumSend(_ value: String, _ send: @escaping () -> Void) {
            drumSendTask?.cancel()
            guard canApplyDrum else {
                cancelDrumSend(reseat: true)
                return
            }
            let request = deferredDrum.schedule(value, context: drumContext)
            drumSendTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(80))
                guard !Task.isCancelled, deferredDrum.pending == request else { return }
                let accepted = deferredDrum.consume(
                    request, context: drumContext, options: drumOptions, isActive: canApplyDrum)
                drumSendTask = nil
                guard accepted != nil else {
                    reseatDrum()
                    return
                }
                send()
            }
        }

        private func cancelDrumSend(reseat: Bool = false) {
            drumInteractionRevision &+= 1
            let hadPending = deferredDrum.pending != nil
            drumSendTask?.cancel()
            drumSendTask = nil
            deferredDrum.cancel()
            if reseat, hadPending { reseatDrum() }
        }

        private func reseatDrum() {
            switch sheet {
            case .iso: reseatIso()
            case .shutter: reseatShutterOrEv()
            default: break
            }
        }

        private var currentResolution: VideoResolution? {
            host.cameraStatus.videoFormat?.resolution ?? host.cameraStatus.videoResolution
        }

        private var currentFrameRate: VideoFrameRate? {
            host.cameraStatus.videoFormat?.frameRate ?? VideoFrameRate.fromFps(host.cameraStatus.fps)
        }

        private var currentVideoFormat: VideoFormat? {
            guard let resolution = currentResolution, let frameRate = currentFrameRate
            else { return nil }
            return VideoFormat(resolution: resolution, frameRate: frameRate)
        }

        private var pickerVideoFormats: [VideoFormat] {
            CamCapVideoFormat.pickerFormats(
                available: host.cameraStatus.availableVideoFormats,
                model: connectedBody, shootingMode: host.cameraStatus.shootingMode)
        }

        private var formatAspects: [VideoAspect] {
            CamCapVideoFormat.aspects(
                available: pickerVideoFormats,
                current: currentResolution?.aspect)
        }

        private var formatResolutions: [VideoResolution] {
            let aspect = formatAspects.count > 1 ? selectedAspect : nil
            return CamCapVideoFormat.resolutions(
                available: pickerVideoFormats,
                aspect: aspect,
                current: currentResolution)
        }

        private var formatRates: [VideoFrameRate] {
            guard let resolution = resolutionForTab(selectedMode) else { return [] }
            return CamCapVideoFormat.frameRates(
                available: pickerVideoFormats,
                resolution: resolution,
                current: currentFrameRate)
        }

        private func resolutionForTab(_ index: Int) -> VideoResolution? {
            let tabs = formatResolutions
            guard tabs.indices.contains(index) else { return currentResolution }
            return tabs[index]
        }

        private func applyVideoFormat(resolution: VideoResolution, frameRate: VideoFrameRate) {
            let format = VideoFormat(resolution: resolution, frameRate: frameRate)
            guard canApplyDrum, pickerVideoFormats.contains(format) else { return }
            host.commit(
                .videoFormat(format),
                from: .sheet(commonField))
        }

        private func handleAspectChange(_ aspect: VideoAspect) {
            guard canApplyDrum, aspect != selectedAspect else { return }
            selectedAspect = aspect
            let sizes = formatResolutions
            guard let match =
                sizes.first(where: { $0.sizeTitle == currentResolution?.sizeTitle })
                ?? sizes.first ?? currentResolution
            else { return }
            selectedMode = sizes.firstIndex(of: match) ?? 0
            let rates = CamCapVideoFormat.frameRates(
                available: pickerVideoFormats,
                resolution: match,
                current: currentFrameRate)
            guard let rate = currentFrameRate.flatMap({ rates.contains($0) ? $0 : nil })
                ?? rates.first else { return }
            drumSelection = rate.drumLabel
            lastApplied = drumSelection
            applyVideoFormat(resolution: match, frameRate: rate)
        }

        /// Auto SET keeps tint (Mimo). Tint pad must not kick Auto into Custom.
        private func applyTint(_ tint: Int) {
            guard canApplyDrum else { return }
            let kelvin = host.displayStatus.whiteBalance?.mode == .custom ? currentKelvin : nil
            host.commit(.whiteBalanceTint(tint, kelvin: kelvin), from: .sheet(commonField))
        }

        private func reseatIso() {
            if offersIsoAuto {
                selectedMode = host.cameraStatus.isoIndex == .auto ? 0 : 1
            } else {
                selectedMode = 0
            }
            if isIsoAutoTab {
                reseatIsoAutoDrum()
            } else {
                reseatIsoDiscrete()
            }
        }

        private func reseatIsoAutoDrum() {
            let labels = isoAutoDrumLabels
            let live =
                host.controlCapabilities.nativeISO.ceiling == true
                ? CaptureLists.isoAutoLabel(from: host.cameraStatus, model: connectedBody) : "Auto"
            let next = labels.contains(live) ? live : ""
            lastApplied = next
            drumSelection = next
        }

        private func reseatIsoDiscrete() {
            let live: String
            if let idx = host.cameraStatus.isoIndex, idx != .auto {
                live = idx.label
            } else if host.cameraStatus.iso > 0 {
                live = "\(host.cameraStatus.iso)"
            } else {
                live = ""
            }
            let next = isoDrumLabels.contains(live) ? live : ""
            lastApplied = next
            drumSelection = next
        }

        private func reseatShutterOrEv() {
            if isEvSheet {
                reseatEv()
            } else {
                reseatShutter()
            }
        }

        private func reseatEv() {
            let labels = evLabels
            let live = host.cameraStatus.evComp?.label ?? ""
            let next = labels.contains(live) ? live : ""
            lastApplied = next
            drumSelection = next
        }

        private func reseatShutter() {
            if isAngleSheet {
                reseatShutterAngle()
                return
            }
            let labels = shutterLabels
            guard host.cameraStatus.shutterDenom > 0 else {
                lastApplied = ""
                drumSelection = ""
                return
            }
            let live =
                host.cameraStatus.shutterDenom > 0
                ? CamCapShutter.label(host.cameraStatus.shutterDenom) : labels.first ?? ""
            let next = labels.contains(live) ? live : nearestShutter(live)
            lastApplied = next
            drumSelection = next
        }

        private func reseatShutterAngle() {
            let fps = host.cameraStatus.fps
            let liveDenom = host.cameraStatus.shutterDenom
            let preferred = ShutterAngle.label(host.shutterAngleDegrees)
            if liveDenom > 0 {
                let mapped = ShutterAngle.denom(
                    degrees: host.shutterAngleDegrees, fps: fps, available: shutterDenoms)
                if mapped == liveDenom || host.shutterAngleSettling, shutterAngleLabels.contains(preferred) {
                    lastApplied = preferred
                    drumSelection = preferred
                    return
                }
                let next = ShutterAngle.nearestLabel(denom: liveDenom, fps: fps) ?? ""
                lastApplied = next
                drumSelection = next
                return
            }
            lastApplied = ""
            drumSelection = ""
        }

        private func nearestShutter(_ label: String) -> String {
            guard let denom = CamCapShutter.denom(from: label),
                let near = CamCapShutter.nearestDenom(denom, in: shutterDenoms)
            else {
                return shutterLabels.first ?? ""
            }
            return CamCapShutter.label(near)
        }
    }

    /// Choice drums must own the displayed value. A get-only binding to live
    /// camera status reseats the wheel on the previous detent before the SET
    /// HUD catches up, so Auto↔Manual (and the other binary drums) bounce.
    private struct CaptureChoiceDrum<Host: CaptureSheetHost>: View {
        let options: [String]
        let cameraValue: String?
        var isInteractive: Bool = true
        let canApply: Bool
        let action: (String) -> Void
        @State private var selection: String

        init(
            options: [String], cameraValue: String?, isInteractive: Bool = true, canApply: Bool,
            action: @escaping (String) -> Void
        ) {
            self.options = options
            self.cameraValue = cameraValue
            self.isInteractive = isInteractive
            self.canApply = canApply
            self.action = action
            _selection = State(initialValue: cameraValue ?? "")
        }

        var body: some View {
            CaptureDrumWheel<Host>(
                options: options,
                selection: Binding(
                    get: { selection },
                    set: { value in
                        guard value != selection else { return }
                        selection = value
                        if canApply, isInteractive { action(value) }
                    }),
                isInteractive: isInteractive
            )
            .onAppear { selection = cameraValue ?? "" }
            .onChange(of: cameraValue) { _, new in
                if let new, new != selection { selection = new }
            }
            .onChange(of: options) { _, _ in
                if selection.isEmpty { selection = cameraValue ?? "" }
            }
        }
    }

    struct CaptureDrumWheel<Host: CaptureSheetHost>: View {
        let options: [String]
        @Binding var selection: String
        var markedValues: Set<String> = []
        var isInteractive: Bool = true
        @Environment(Host.self) private var host
        @Environment(\.captureDrumInteractionIdentity) private var interactionIdentity
        @Environment(\.captureDrumPreview) private var preview

        var body: some View {
            let values = preview?.snapshot.options ?? options
            let shown = preview?.selection ?? selection
            let marked = preview?.snapshot.marked ?? markedValues
            LadderSheet(
                presentation: LadderSheetPresentation(title: "", subtitle: "", tabs: [
                    LadderTab(label: "", key: 0,
                        ladder: CaptureLadder(current: shown.isEmpty ? nil : shown,
                            values: values, marked: marked), applyOnActivate: false)
                ]), enabled: isInteractive, onWrite: { write in
                    guard preview == nil else { return }
                    selection = write.value
                },
                host: LadderSheetHost(selectedTab: 0, selection: shown, drum: .labels,
                    previewPosition: preview?.position, interactionIdentity: interactionIdentity,
                    onSelectTab: { _ in })
            ).environment(\.ladderOperatorHaptics, host.hapticsEnabled)
        }
    }

    private struct CaptureDrumPreviewKey: EnvironmentKey {
        static var defaultValue: CaptureDrumPresentation? { nil }
    }

    private struct CaptureDrumInteractionIdentityKey: EnvironmentKey {
        static var defaultValue: () -> AnyHashable { { AnyHashable(0) } }
    }

    extension EnvironmentValues {
        fileprivate var captureDrumPreview: CaptureDrumPresentation? {
            get { self[CaptureDrumPreviewKey.self] }
            set { self[CaptureDrumPreviewKey.self] = newValue }
        }

        fileprivate var captureDrumInteractionIdentity: () -> AnyHashable {
            get { self[CaptureDrumInteractionIdentityKey.self] }
            set { self[CaptureDrumInteractionIdentityKey.self] = newValue }
        }
    }

    public enum CaptureLists {
        /// Operator MODE drum. Live Photo is current-only when the camera reports `4D`;
        /// it is never offered as a new SET on other modes or bodies.
        public static func operatorShootingModes(
            from status: CameraStatus = CameraStatus(), model: CameraModel? = nil
        ) -> [ShootingMode] {
            (model?.captureProfile?.labels.shootingModes ?? ShootingMode.allCases).filter {
                $0 != .livePhoto || ShootingMode.fromStatus(status.shootingMode) == .livePhoto
            }
        }

        /// The colour drum's labels: the offered modes plus the reported current one when the
        /// offered list lacks it, so the drum opens centred on the value the header shows.
        public static func colorDrumLabels(
            offered: [ColorMode], current: ColorMode?, family: CameraBodyFamily,
            profile: CameraLabelProfile
        ) -> [String] {
            CamCapColorMode.drum(offered: offered, current: current).map {
                $0.label(for: family, in: profile)
            }
        }

        public static func recordingCategories(isPhoto: Bool) -> [CaptureSheet] {
            isPhoto ? [.mode] : [.resolution, .color, .mode]
        }

        /// Photo must not reuse leftover Video color for Auto ISO / fallback wheels.
        public static func isoPresentationColor(from status: CameraStatus) -> ColorMode {
            status.isPhoto ? .normal : (status.colorMode ?? .normal)
        }

        public static func shutterDenoms(from status: CameraStatus) -> [Int] {
            CamCapShutter.wheelDenoms(
                available: status.availableShutterDenoms, current: status.shutterDenom)
        }

        public static func shutterLabels(from status: CameraStatus) -> [String] {
            shutterDenoms(from: status).map(CamCapShutter.label)
        }

        public static func isoIndices(from status: CameraStatus) -> [IsoIndex] {
            CamCapIso.wheelIndices(
                available: status.availableIsoIndices,
                fallback: isoPresentationColor(from: status).isoIndices
            )
        }

        public static func isoDrumLabels(from status: CameraStatus) -> [String] {
            isoIndices(from: status).filter { $0 != .auto }.map(\.label)
        }

        public static func offersIsoAuto(from status: CameraStatus) -> Bool {
            isoPresentationColor(from: status).offersIsoAuto
        }

        public static func isoAutoLabels(from status: CameraStatus, model: CameraModel? = nil)
            -> [String]
        {
            isoPresentationColor(from: status).isoAutoLabels(for: model)
        }

        public static func isoAutoLabel(from status: CameraStatus, model: CameraModel? = nil)
            -> String
        {
            guard let base = isoPresentationColor(from: status).isoAutoBase(for: model),
                let limit = status.isoLimit
            else { return "" }
            return limit.label(base: base)
        }

        public static func isoLimit(
            from label: String, status: CameraStatus, model: CameraModel? = nil
        )
            -> IsoLimit?
        {
            let color = isoPresentationColor(from: status)
            guard let base = color.isoAutoBase(for: model) else { return nil }
            return color.isoAutoLimits.first { $0.label(base: base) == label }
        }

        public static func shouldGetIsoLimit(from status: CameraStatus) -> Bool {
            IsoLimit.shouldGet(colorMode: isoPresentationColor(from: status))
        }

        public static let evLabels = EvComp.allCases.map(\.label)

        /// Star markers only. List stays `camcap_iso`; transfer is `status.monitorTransfer`.
        /// Photo must not inherit video D-Log / D-Log2 native-ISO stars from leftover color.
        public static func isoMarkedLabels(from status: CameraStatus) -> Set<String> {
            if status.isPhoto { return [] }
            return CamCapIso.markedLabels(transfer: status.monitorTransfer)
        }

        /// Camera capability push wins; the captured per-mode set covers the gap before it.
        public static func apertureStrategies(from status: CameraStatus) -> [ApertureStrategy] {
            status.availableApertureStrategies.isEmpty
                ? ApertureStrategy.fallback(
                    expoMode: status.expoMode, shootingMode: status.shootingMode)
                : status.availableApertureStrategies
        }

        public static func focusOption(from status: CameraStatus) -> FocusOption? {
            FocusOption.resolve(mode: status.focusMode, track: status.focusTrack)
        }

        public static func focusTitle(_ option: FocusOption?) -> String {
            switch option {
            case .single: "Single autofocus"
            case .continuousDefault: "Continuous autofocus"
            case .productShowcase: "Product showcase"
            case .subjectLock: "Subject lock tracking"
            case .registeredPriority: "Registered subject priority"
            case nil: "Focus tracking"
            }
        }

        public static func focusHelp(_ option: FocusOption?) -> String {
            switch option {
            case .single: "Set focus once. Tap the picture to choose the focus point."
            case .continuousDefault: "Keep focus adjusting as the subject moves through frame."
            case .productShowcase: "Prioritize a product presented close to the camera."
            case .subjectLock: "Keep focus on the selected subject as it moves through frame."
            case .registeredPriority:
                "Give a subject registered on the camera priority when focusing."
            case nil: "Choose a focus mode supported by the connected camera."
            }
        }

        public static let facePriorityTitle = "Face Priority"
        public static let facePriorityBadgeIcon = MonitorIcon.scan
        public static let facePriorityHelp =
            "On: EV follows faces to middle gray. Several faces use the median. First couple of seconds after a face appears are faster, then about 1 s. Off: put EV back to what it was, or 0.0."

        public static let nativeIsoHopTitle = "Auto Native ISO"

        public static let kelvinValues = WhiteBalance.kelvinLadder
        public static let kelvinLabels = kelvinValues.map { "\($0)K" }
        /// WB Mode drum entry left of Auto: Custom at the live Auto Kelvin. It stays
        /// selected while the lock holds; Auto or Custom releases it.
        public static let awbLock = "AWB Lock"
        /// WB tile while locked; `AWB Lock` would outgrow the tile's `10000K` width.
        public static let awbLockTile = "AWB-L"

        public static func whiteBalanceModeLabels(offersLock: Bool) -> [String] {
            (offersLock ? [awbLock] : []) + WhiteBalanceMode.allCases.map(\.label)
        }

        public static func whiteBalanceModeSelection(_ wb: WhiteBalance?, awbLocked: Bool)
            -> String?
        {
            awbLocked ? awbLock : wb?.mode.label
        }
        /// EXPOSURE tile and drum entry left of Auto while the feed AE lock holds.
        /// Auto or Manual releases it; the entry leaves the drum once released.
        public static let aeLock = "AE-L"

        public static func exposureLabels(aeLocked: Bool) -> [String] {
            (aeLocked ? [aeLock] : []) + ExpoMode.allCases.map(\.label)
        }

        public static func exposureSelection(_ mode: ExpoMode?, aeLocked: Bool) -> String? {
            aeLocked ? aeLock : mode?.label
        }

        public static func kelvin(from label: String) -> Int? {
            Int(label.replacingOccurrences(of: "K", with: ""))
        }
    }

    extension CaptureSheet {
        public var headerLabel: String {
            switch self {
            case .iso: "ISO"
            case .shutter: "SHUTTER"
            case .wb: "WHITE BALANCE"
            case .focus: "FOCUS"
            case .aperture: "APERTURE"
            case .exposure: "EXPOSURE MODE"
            case .audio: "AUDIO"
            case .mode: "SHOOTING MODE"
            case .resolution: "FORMAT"
            case .color: "COLOR"
            }
        }

        public var subtitle: String {
            switch self {
            case .iso: "Sensitivity"
            case .shutter: "Angle · speed"
            case .wb: "Kelvin · auto · tint"
            case .focus: "AF-S · AF-C · tracking"
            case .aperture: "Aperture strategy"
            case .exposure: "Exposure"
            case .audio: "Channel · wind · direction · vocal"
            case .mode: "Shooting mode"
            case .resolution: "Resolution · frame rate"
            case .color: "Color mode"
            }
        }
    }

    /// A noninteractive preview follows the readout's original touch. Closing this
    /// view cannot end or replace the recognizer that owns the eventual commit.
    public struct CaptureSheetDrumHost<Host: CaptureSheetHost>: View {
        public var viewport: CGSize
        public var safeArea: EdgeInsets = EdgeInsets()
        public var ceilingY: CGFloat = 0
        public var bottomY: CGFloat? = nil
        public var topDeckMaxY: CGFloat = 0
        @Environment(Host.self) private var host

        public init(
            viewport: CGSize, safeArea: EdgeInsets = EdgeInsets(), ceilingY: CGFloat = 0,
            bottomY: CGFloat? = nil, topDeckMaxY: CGFloat = 0
        ) {
            self.viewport = viewport
            self.safeArea = safeArea
            self.ceilingY = ceilingY
            self.bottomY = bottomY
            self.topDeckMaxY = topDeckMaxY
        }

        public var body: some View {
            let edge: MonitorCapturePopupEdge =
                host.captureDrum?.sheet.isTopAnchored == true ? .top : .bottom
            let topY: CGFloat? =
                edge == .top
                ? (viewport.height > viewport.width ? topDeckMaxY + 6 : 0) : nil
            return CapturePopupContainer(
                viewport: viewport, safeArea: safeArea, ceilingY: ceilingY, bottomY: bottomY,
                edge: edge, topY: topY
            ) { place in
                if let drum = host.captureDrum {
                    CaptureSheetPanel<Host>(
                        sheet: drum.sheet, maximumHeight: CGFloat(place.maximumHeight),
                        bottomPadding: CGFloat(place.bottomPadding),
                        topPadding: CGFloat(place.topPadding),
                        topCornerRadius: CGFloat(place.topCornerRadius),
                        bottomCornerRadius: CGFloat(place.bottomCornerRadius),
                        edge: place.edge,
                        isPresented: { false }, preview: drum, onClose: {}
                    )
                    .id(drum.id)
                    .transition(.identity)
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onChange(of: viewport) { _, _ in host.captureDrum = nil }
            .onChange(of: safeArea) { _, _ in host.captureDrum = nil }
            .onChange(of: bottomY) { _, _ in host.captureDrum = nil }
            .onChange(of: ceilingY) { _, _ in host.captureDrum = nil }
            .onChange(of: topDeckMaxY) { _, _ in host.captureDrum = nil }
        }
    }

    /// Tap and hold use one placement/rendering boundary, including portrait rails
    /// and the scroll ceiling on short windows. Neither host owns a second dial.
    private struct CapturePopupContainer<Content: View>: View {
        let viewport: CGSize
        let safeArea: EdgeInsets
        let ceilingY: CGFloat
        let bottomY: CGFloat?
        var edge: MonitorCapturePopupEdge = .bottom
        var topY: CGFloat? = nil
        @ViewBuilder var content: (MonitorCapturePopupLayout) -> Content

        var body: some View {
            let place = MonitorCapturePopupLayout(
                viewportWidth: viewport.width, viewportHeight: viewport.height,
                tablet: UIDevice.current.userInterfaceIdiom == .pad,
                safeArea: MonitorSafeArea(
                    top: safeArea.top, leading: safeArea.leading,
                    bottom: safeArea.bottom, trailing: safeArea.trailing),
                bottomBoundary: bottomY.map(Double.init), ceiling: ceilingY,
                edge: edge, topBoundary: topY.map(Double.init))
            Group {
                if edge == .top {
                    VStack(spacing: 0) {
                        content(place)
                        Spacer(minLength: 0)
                    }
                    .frame(
                        width: CGFloat(place.width),
                        height: max(CGFloat(0), viewport.height - CGFloat(place.top)),
                        alignment: .top
                    )
                    .offset(
                        x: CGFloat(place.centerX - place.width / 2), y: CGFloat(place.top))
                } else {
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        content(place)
                    }
                    .frame(
                        width: CGFloat(place.width), height: CGFloat(place.bottom),
                        alignment: .bottom
                    )
                    .offset(x: CGFloat(place.centerX - place.width / 2))
                }
            }
            .frame(width: viewport.width, height: viewport.height, alignment: .topLeading)
        }
    }

    /// Let the underlying readouts retain their recognizers while a persistent
    /// picker is open. The rest of the picture remains a dismiss target.
    private struct CapturePickerBackdrop: Shape {
        let frames: [CGRect]
        func path(in rect: CGRect) -> Path {
            var path = Path(rect)
            for frame in frames where frame.width > 0 && frame.height > 0 {
                path.addRect(frame)
            }
            return path
        }
    }
#endif
