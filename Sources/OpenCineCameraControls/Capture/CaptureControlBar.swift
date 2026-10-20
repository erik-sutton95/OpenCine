#if os(iOS)
    import MonitorPresentation
    import MonitorUI
    import OpenCineAppKit
    import OpenCineCameraVocabulary
    import OpenCineCore
    import SwiftUI

    /// The live capture strip (the reference monitor's capture strip and setting buttons):
    /// ISO, SHUTTER or EV, EXPOSURE, the host's metering tile, WB, then FOCUS, APERTURE and AUDIO
    /// as the host's capabilities offer them. The parent sizes it to about two thirds of the width.
    public struct CaptureControlBar<Host: CaptureSheetHost, MeteringTile: View>: View {
        var columns: Int
        let meteringTile: MeteringTile
        @Environment(Host.self) private var host
        @Environment(\.interfaceLocked) private var interfaceLocked
        @State private var readoutOwnership = MonitorReadoutOwnership()

        /// `meteringTile` follows EXPOSURE and counts as a column when the host offers face
        /// metering.
        public init(columns: Int = 6, @ViewBuilder meteringTile: () -> MeteringTile) {
            self.columns = columns
            self.meteringTile = meteringTile()
        }

        public var body: some View {
            tileStrip
                .frame(maxWidth: .infinity, alignment: .trailing)
                .onChange(of: interfaceLocked) { _, locked in
                    if locked {
                        host.captureSheet = nil
                        host.captureDrum = nil
                    }
                }
                .onChange(of: host.sessionLocked) { _, locked in
                    if locked {
                        host.captureSheet = nil
                        host.captureDrum = nil
                    }
                }
                .onChange(of: columns) { _, _ in host.captureDrum = nil }
                .onChange(of: controls.focus.isOffered) { _, on in
                    if !on, host.captureSheet == .focus { host.captureSheet = nil }
                }
                .onChange(of: controls.iris.isOffered) { _, on in
                    if !on, host.captureSheet == .aperture { host.captureSheet = nil }
                    if !on, host.captureDrum?.sheet == .aperture { host.captureDrum = nil }
                }
                .onChange(of: host.cameraStatus.isPhoto) { _, photo in
                    if photo, host.captureSheet == .audio { host.captureSheet = nil }
                    if photo, host.captureDrum?.sheet == .audio { host.captureDrum = nil }
                }
        }

        private var tilesLocked: Bool {
            interfaceLocked || host.sessionLocked
        }

        /// The one capability model: which tiles the strip offers.
        private var controls: ControlCapabilities { host.controlCapabilities }

        private var status: CameraStatus { host.cameraStatus }

        private var showsAudio: Bool { controls.audio.isOffered && !status.isPhoto }

        private var visibleTileCount: Int {
            4 + (controls.faceMetering.isOffered ? 1 : 0) + (controls.focus.isOffered ? 1 : 0)
                + (controls.iris.isOffered ? 1 : 0) + (showsAudio ? 1 : 0)
        }

        private var gridColumns: Int { columns == 3 ? 3 : max(visibleTileCount, 1) }

        private var tileStrip: some View {
            MonitorControlGrid(
                columns: gridColumns, spacing: columns == 3 ? 8 : 12, equalColumns: columns == 3
            ) {
                if !host.captureStripShowsPendingEdits || (status.isoIndex == .auto && controls.nativeISO.ceiling == true) {
                    tile(.iso, label: "ISO", value: isoValue, widest: "25600")
                } else {
                    commonTile(.iso, key: .iso)
                }
                if host.control.snapshot?.exposureProgram.value == .automatic {
                    tile(
                        .shutter,
                        label: MonitorExposureReadout.autoEvCaption(
                            shutterDenom: status.shutterDenom),
                        value: evValue, widest: "+3.0",
                        badgeIcon: host.facePriorityExposureEnabled
                            ? CaptureLists.facePriorityBadgeIcon : nil)
                } else if (host.shutterUsesAngle && !status.isPhoto) || !host.captureStripShowsPendingEdits {
                    tile(
                        .shutter, label: "SHUTTER", value: shutterValue,
                        widest: host.shutterUsesAngle && !status.isPhoto ? "346°" : "1/16000")
                } else {
                    commonTile(.shutter, key: .shutter)
                }
                tile(.exposure, label: "EXPOSURE", value: expoValue, widest: "Manual")
                meteringTile
                if host.captureStripShowsPendingEdits, status.whiteBalance?.mode == .custom,
                    !host.autoWhiteBalanceLocked
                {
                    commonTile(.wb, key: .whiteBalance)
                } else {
                    tile(.wb, label: "WB", value: wbValue, widest: "10000K", valueIcon: wbIcon)
                }
                if controls.focus.isOffered {
                    tile(.focus, label: "FOCUS", value: focusValue, widest: "Showcase")
                }
                if controls.iris.isOffered {
                    tile(
                        .aperture, label: "APERTURE", value: apertureValue, widest: "Starburst f/4")
                }
                if showsAudio {
                    tile(.audio, label: "AUDIO", value: audioValue, widest: "Spatial")
                }
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .onTapGesture {}
            .opacity(tilesLocked ? 0.4 : 1)
            .allowsHitTesting(!tilesLocked)
        }

        @ViewBuilder private func commonTile(_ sheet: CaptureSheet, key: SettingKey) -> some View {
            if let field = host.control.captureField(key, selection: readoutSelection) {
                MonitorCaptureReadout(
                    control: host.control, field: field,
                    enabled: !tilesLocked
                        && (host.captureDrum == nil || host.captureDrum?.sheet == sheet),
                    active: host.captureSheet == sheet || host.captureDrum?.sheet == sheet,
                    ownership: $readoutOwnership, presentationOwner: { host.captureDrum?.id },
                    admission: { !tilesLocked && !host.coverOpen && host.captureSheet == nil }
                ) { event in
                    switch event {
                    case .open: open(sheet)
                    case .preview(let preview):
                        guard !tilesLocked, !host.coverOpen,
                            readoutOwnership.owns(preview.id)
                        else { return }
                        host.captureSheet = nil
                        host.captureDrum = CaptureDrumPresentation(
                            id: preview.id, sheet: sheet,
                            snapshot: .common(preview.sourceIdentity), position: preview.position)
                    case .commit(let release, _):
                        if host.captureDrum?.id == release.id { host.captureDrum = nil }
                    case .cancel(let id):
                        if host.captureDrum?.id == id { host.captureDrum = nil }
                    }
                }
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: LiveCaptureTileFramesKey.self,
                            value: [sheet: proxy.frame(in: .named(LiveCanvasSpace.name))])
                    }
                }
                .accessibilityIdentifier("monitor.capture.\(sheet.rawValue)")
            } else {
                MonitorReadout(MonitorCapturePresentation.title(key) ?? "") { Text("--") }
                    .accessibilityValue("Not set")
            }
        }

        private func tile(
            _ sheet: CaptureSheet,
            label: String,
            value: String,
            widest: String,
            valueIcon: MonitorIcon? = nil,
            badgeIcon: MonitorIcon? = nil
        ) -> some View {
            let isActive = host.captureSheet == sheet || host.captureDrum?.sheet == sheet
            let acceptsTouch =
                !tilesLocked && (host.captureDrum == nil || host.captureDrum?.sheet == sheet)
            return CaptureBarReadout(
                label: label,
                value: value,
                widest: widest,
                isActive: isActive,
                valueIcon: valueIcon,
                badgeIcon: badgeIcon
            )
            .modifier(
                CaptureSheetReadoutGesture<Host>(
                    sheet: sheet, locked: tilesLocked, ownership: $readoutOwnership
                ) { open(sheet) }
            )
            .disabled(tilesLocked)
            .allowsHitTesting(acceptsTouch)
            .frame(maxWidth: .infinity)
            .geometryGroup()
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: LiveCaptureTileFramesKey.self,
                        value: [sheet: proxy.frame(in: .named(LiveCanvasSpace.name))]
                    )
                }
            }
            .accessibilityIdentifier("monitor.capture.\(sheet.rawValue)")
            .accessibilityLabel(label)
            .accessibilityValue(
                badgeIcon == nil ? value : "\(value), \(CaptureLists.facePriorityTitle)")
        }

        private func open(_ sheet: CaptureSheet) {
            guard !tilesLocked, host.captureDrum == nil, readoutOwnership.owner == nil else {
                return
            }
            host.captureDrum = nil
            host.captureSheet = CaptureReadoutAdmission.replacing(
                host.captureSheet,
                with: CaptureReadoutAdmission.opening(sheet, isPhoto: status.isPhoto))
        }

        private var readoutSelection: MonitorCaptureSelection {
            host.captureStripShowsPendingEdits ? .pending : .reported
        }

        private func commonValue(_ key: SettingKey) -> String {
            host.control.captureValue(key, selection: readoutSelection).map(MonitorCapturePresentation.label) ?? "--"
        }

        private var isoValue: String { commonValue(.iso) }

        private var shutterValue: String {
            if !host.shutterUsesAngle || status.isPhoto { return commonValue(.shutter) }
            // The same angle readout as the live strip: common shutter and reported cadence.
            return host.shutterAngleReadout(selection: readoutSelection).value
        }

        private var evValue: String {
            host.captureRouting.commonExposureCompensation ? commonValue(.exposureCompensation) : status.evComp?.label ?? "--"
        }

        private var wbIcon: MonitorIcon? {
            if case .whiteBalance(.auto)? = host.control.captureValue(.whiteBalance, selection: readoutSelection) {
                return host.autoWhiteBalanceLocked ? nil : .aperture
            }
            return nil
        }

        private var wbValue: String {
            if host.autoWhiteBalanceLocked { return CaptureLists.awbLockTile }
            return commonValue(.whiteBalance)
        }

        private var focusValue: String {
            let commonFocus: OpenCineCore.FocusMode?
            if case .focusMode(let value)? = host.control.captureValue(.focusMode, selection: readoutSelection) {
                commonFocus = value
            } else { commonFocus = nil }
            return CaptureNativeReadoutPresentation.focus(common: commonFocus,
                native: FocusOption.resolve(mode: status.focusMode, track: status.focusTrack))
        }

        private var apertureValue: String {
            commonValue(.aperture)
        }

        private var expoValue: String {
            if host.autoExposureLocked { return CaptureLists.aeLock }
            return host.control.snapshot?.exposureProgram.value.map(MonitorCapturePresentation.exposureProgram) ?? "--"
        }

        private var audioValue: String {
            status.audioChannel?.label ?? "\u{2014}"
        }
    }

    extension CaptureControlBar where MeteringTile == EmptyView {
        public init(columns: Int = 6) {
            self.init(columns: columns) { EmptyView() }
        }
    }

    /// A capture strip tile's readout: one typeface for every tile.
    public struct CaptureBarReadout: View {
        let label: String
        let value: String
        let widest: String
        var isActive: Bool
        var valueIcon: MonitorIcon?
        /// Shown beside the label (EV Face Priority). Distinct from `valueIcon`, which replaces
        /// the value.
        var badgeIcon: MonitorIcon?

        public init(
            label: String, value: String, widest: String, isActive: Bool = false,
            valueIcon: MonitorIcon? = nil, badgeIcon: MonitorIcon? = nil
        ) {
            self.label = label
            self.value = value
            self.widest = widest
            self.isActive = isActive
            self.valueIcon = valueIcon
            self.badgeIcon = badgeIcon
        }

        public var body: some View {
            MonitorReadout(label, active: isActive) {
                HStack(spacing: 3) {
                    if let valueIcon { valueIcon.frame(width: 17, height: 17) }
                    Text(value)
                    if let badgeIcon { badgeIcon.frame(width: 11, height: 11) }
                }
            }
        }
    }
#endif
