#if os(iOS)
    import MonitorPresentation
    import MonitorUI
    import OpenCineAppKit
    import OpenCineCameraVocabulary
    import OpenCineMedia
    import SwiftUI
    import UIKit

    /// The field monitor's status row over the host's status projection. Reads the session's
    /// existing throttled snapshot; it never schedules status work or remaps signal health or
    /// camera controls.
    public struct LiveStatusChrome<Host: LiveChromeHost>: View {
        @Environment(Host.self) private var host
        @Environment(\.interfaceLocked) private var locked
        @Binding var menu: LiveTopMenu?
        var layout: LiveMonitorLayout
        @State private var storageForm = 0
        @State private var readoutOwnership = MonitorReadoutOwnership()

        public init(menu: Binding<LiveTopMenu?>, layout: LiveMonitorLayout) {
            _menu = menu
            self.layout = layout
        }

        public var body: some View {
            let geometry =
                layout.presentation
                ?? FieldMonitorLayout(width: layout.viewport.width, height: layout.viewport.height)
            let status = host.cameraStatus
            MonitorStatusChrome(
                layout: geometry,
                status: host.liveStatus,
                showsTimecode: showsTimecode,
                showsRecording: host.chromeSectionMounts(.recReadout) && !status.isPhoto
            ) {
                if host.chromeSectionMounts(.storage) { storageButton }
            } format: {
                if geometry.portrait {
                    topReadout(
                        status.isPhoto ? .mode : .resolution,
                        value: status.isPhoto ? "MODE" : recSetupFormat,
                        fontSize: status.isPhoto ? 12 : (geometry.tablet ? 25 : 23),
                        weight: status.isPhoto ? .semibold : .medium,
                        caption: status.isPhoto ? nil : recSetupColor
                    )
                    .accessibilityLabel(status.isPhoto ? "Shooting mode" : "Recording options")
                } else if host.chromeSectionMounts(.format) {
                    if status.isPhoto {
                        topReadout(
                            .mode,
                            value: host.currentShootingMode?.label(for: host.connectedBody)
                                ?? "Photo",
                            fontSize: geometry.tablet ? 18 : 16, alwaysAccent: true)
                    } else {
                        topButton(.recFormat, value: status.videoFormat?.chipLabel ?? "\u{2014}")
                    }
                }
            } color: {
                // Portrait hangs the color under the format readout (its caption).
                if !geometry.portrait, host.chromeSectionMounts(.color), !status.isPhoto {
                    topButton(
                        .color,
                        value: status.colorMode?.label(in: host.labelProfile) ?? "\u{2014}")
                }
            } mode: {
                if layout.viewport.width >= 800, !status.isPhoto {
                    topReadout(
                        .mode,
                        value: host.currentShootingMode?.label(for: host.connectedBody)
                            ?? "Video",
                        fontSize: geometry.tablet ? 18 : 16, alwaysAccent: true)
                }
            } link: {
                if host.chromeSectionMounts(.batteries) {
                    LiveTelemetryGauges<Host>(horizontal: true, showsPower: false)
                }
            }
            .onChange(of: locked) { _, isLocked in
                if isLocked {
                    host.captureSheet = nil
                    host.captureDrum = nil
                }
            }
            .onChange(of: host.cameraStatus.isPhoto) { _, photo in
                host.captureSheet = CaptureReadoutAdmission.retained(
                    host.captureSheet, isPhoto: photo)
                if CaptureReadoutAdmission.retainedDrum(host.captureDrum?.sheet, isPhoto: photo)
                    == nil
                {
                    host.captureDrum = nil
                }
                if photo, host.assist.configureTool == .audioMeters {
                    host.assist.configureTool = nil
                }
            }
        }

        /// One rule for every app: the single-camera clock slot follows the operator's DISP section
        /// in video; a body without timecode shows the placeholder at its declared precision.
        private var showsTimecode: Bool {
            host.chromeSectionMounts(.timecode) && !host.cameraStatus.isPhoto
        }

        private var storageButton: some View {
            Button {
                storageForm = MonitorStorageReadoutFormat.nextForm(after: storageForm, count: storageForms.count)
            } label: {
                HStack(spacing: 5) {
                    MonitorIcon.cardSim.frame(width: 12, height: 12)
                    Text(storage).font(
                        MonitorTheme.font(
                            layout.presentation?.portrait == true
                                ? 14
                                : (layout.presentation?.tablet == true ? 18 : 16), weight: .medium)
                    ).monospacedDigit()
                        .lineLimit(1).minimumScaleFactor(
                            layout.presentation?.portrait == true ? 11.0 / 14.0 : 0.75)
                }.foregroundStyle(.white)
            }
            .buttonStyle(.monitorTapTarget).accessibilityLabel("Storage remaining")
            .accessibilityValue(storage)
        }

        private var storage: String { storageForms[storageForm % storageForms.count] }

        private var storageForms: [String] {
            // The unified capability readout owns the values; the one shared cycle (A5-11).
            StorageReadoutCycle.forms(host.control.snapshot?.storage, photo: host.cameraStatus.isPhoto)
        }

        private func topButton(_ item: LiveTopMenu, value: String) -> some View {
            topReadout(
                item == .color ? .color : .resolution, value: value,
                fontSize: layout.presentation?.tablet == true ? 18 : 16
            )
            .accessibilityLabel(item == .color ? "Color mode" : "Recording format")
        }

        /// Current format ("4K25p"), not a generic label.
        private var recSetupFormat: String {
            host.cameraStatus.videoFormat.map {
                "\($0.resolution.tabTitle)\($0.frameRate.drumLabel)"
            } ?? "REC SETUP"
        }

        private var recSetupColor: String? {
            host.cameraStatus.colorMode?.label(for: host.bodyFamily, in: host.labelProfile)
        }

        private func topReadout(
            _ sheet: CaptureSheet, value: String, fontSize: CGFloat,
            weight: Font.Weight = .medium,
            alwaysAccent: Bool = false, caption: String? = nil
        ) -> some View {
            let isActive = host.captureSheet == sheet || host.captureDrum?.sheet == sheet
            let acceptsTouch =
                !locked && (host.captureDrum == nil || host.captureDrum?.sheet == sheet)
            return Text(value)
                .font(MonitorTheme.font(fontSize, weight: weight)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.7)
                .overlay(alignment: .bottomTrailing) {
                    if let caption {
                        Text(caption)
                            .font(MonitorTheme.font(11, weight: .semibold))
                            .lineLimit(1).fixedSize()
                            // Hang below the format line (its own line height), not over it.
                            .offset(y: 18)
                    }
                }
                .foregroundStyle(
                    alwaysAccent || isActive ? MonitorTheme.accent : .white
                )
                .modifier(
                    MonitorReadoutHitTargetModifier<Host>(
                        sheet: sheet, locked: locked, acceptsTouch: acceptsTouch,
                        ownership: $readoutOwnership
                    ) { open(sheet) }
                )
                .accessibilityIdentifier(topAccessibilityID(sheet))
                .accessibilityValue(value)
        }

        private func open(_ sheet: CaptureSheet) {
            guard !locked, host.captureDrum == nil, readoutOwnership.owner == nil else { return }
            menu = nil
            host.captureDrum = nil
            host.captureSheet = CaptureReadoutAdmission.replacing(
                host.captureSheet,
                with: CaptureReadoutAdmission.opening(sheet, isPhoto: host.cameraStatus.isPhoto))
        }

        private func topAccessibilityID(_ sheet: CaptureSheet) -> String {
            switch sheet {
            case .color: "monitor.capture.color"
            case .mode: "monitor.capture.mode"
            default: "monitor.capture.format"
            }
        }
    }

    /// Same 44x44pt pad/unpad hit region as `monitorTapTarget`. Gesture and backdrop
    /// frames attach to the expanded region; negative padding restores layout.
    public enum MonitorReadoutHitTarget {
        public static let minimumSize: CGFloat = 44

        public static func padding(for size: CGSize, minSize: CGFloat = minimumSize) -> CGSize {
            CGSize(
                width: size == .zero ? 0 : max(0, (minSize - size.width) / 2),
                height: size == .zero ? 0 : max(0, (minSize - size.height) / 2)
            )
        }
    }

    private struct MonitorReadoutHitTargetSizeKey: PreferenceKey {
        static var defaultValue: CGSize { .zero }

        static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
            let next = nextValue()
            if next != .zero {
                value = next
            }
        }
    }

    private struct MonitorReadoutHitTargetModifier<Host: CaptureSheetHost>: ViewModifier {
        var sheet: CaptureSheet
        var locked: Bool
        var acceptsTouch: Bool
        @Binding var ownership: MonitorReadoutOwnership
        var onOpen: () -> Void
        @State private var measuredSize: CGSize = .zero

        func body(content: Content) -> some View {
            let pad = MonitorReadoutHitTarget.padding(for: measuredSize)
            content
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: MonitorReadoutHitTargetSizeKey.self, value: proxy.size)
                    }
                }
                .onPreferenceChange(MonitorReadoutHitTargetSizeKey.self) { measuredSize = $0 }
                .padding(.horizontal, pad.width)
                .padding(.vertical, pad.height)
                .contentShape(Rectangle())
                .modifier(
                    CaptureSheetReadoutGesture<Host>(
                        sheet: sheet, locked: locked, ownership: $ownership, onTap: onOpen)
                )
                .disabled(locked)
                .allowsHitTesting(acceptsTouch)
                .background {
                    GeometryReader { proxy in
                        let frame = proxy.frame(in: .named(LiveCanvasSpace.name))
                        Color.clear
                            .preference(key: LiveCaptureTileFramesKey.self, value: [sheet: frame])
                            .preference(
                                key: LiveTopPickerFramesKey.self,
                                value: topMenuFrame(frame))
                    }
                }
                .padding(.horizontal, -pad.width)
                .padding(.vertical, -pad.height)
        }

        private func topMenuFrame(_ frame: CGRect) -> [LiveTopMenu: CGRect] {
            switch sheet {
            case .color: [.color: frame]
            case .resolution: [.recFormat: frame]
            default: [:]
            }
        }
    }

    /// The field monitor's assist tool palette. `icon` draws a tool's glyph in the app's style.
    public struct LiveAssistPalette<Host: LiveChromeHost, Icon: View>: View {
        @Environment(Host.self) private var host
        var layout: LiveMonitorLayout
        var isLocked: Bool
        var otherOverlayPresented: Bool
        @Binding var expanded: Bool
        var onExpansionActivityChange: (Bool) -> Void
        let icon: (MonitorAssistSelection) -> Icon

        public init(
            layout: LiveMonitorLayout, isLocked: Bool, otherOverlayPresented: Bool = false,
            expanded: Binding<Bool>, onExpansionActivityChange: @escaping (Bool) -> Void = { _ in },
            @ViewBuilder icon: @escaping (MonitorAssistSelection) -> Icon
        ) {
            self.layout = layout
            self.isLocked = isLocked
            self.otherOverlayPresented = otherOverlayPresented
            _expanded = expanded
            self.onExpansionActivityChange = onExpansionActivityChange
            self.icon = icon
        }

        private var tools: [MonitorAssistSelection] {
            if host.cameraStatus.isPhoto || !host.controlCapabilities.liveAudioLevels.isShown {
                return MonitorAssistSelection.toolbarCases
            }
            return MonitorAssistSelection.toolbarCases + [.audioMeters]
        }

        private var shouldCollapse: Bool {
            isLocked || otherOverlayPresented || host.captureSheet != nil
                || host.captureDrum != nil || host.gimbalPanelOpen
                || host.operatorPanelOpen || host.assist.configureTool != nil
                || host.isEditingChrome
        }

        public static func visibleFrame(
            in layout: LiveMonitorLayout, toolCount: Int, expanded: Bool
        ) -> CGRect {
            let (metrics, frame) = geometry(in: layout, toolCount: toolCount)
            return metrics.resolving(expanded: expanded)
                .anchored(leading: frame.x, bottom: frame.maxY).cgRect
        }

        private static func geometry(
            in layout: LiveMonitorLayout, toolCount: Int
        ) -> (layout: MonitorAssistPaletteLayout, frame: MonitorRect) {
            if let presentation = layout.presentation {
                return MonitorAssistPaletteLayout.fieldMonitor(
                    presentation, toolCount: toolCount, safeTop: layout.safeArea.top)
            }
            let tablet = UIDevice.current.userInterfaceIdiom == .pad
            let portrait = layout.viewport.height > layout.viewport.width
            let maximumWidth =
                portrait
                ? layout.viewport.width - (tablet ? 140 : 126)
                : layout.capture.maxX - layout.assist.minX
            let maximumHeight =
                portrait
                ? min(
                    layout.viewport.height * 0.62,
                    layout.assist.maxY - max(layout.safeArea.top, 8))
                : layout.assist.maxY - max(layout.safeArea.top, 8)
            let metrics = MonitorAssistPaletteLayout(
                portrait: portrait, tablet: tablet, expanded: true, toolCount: toolCount,
                maximumWidth: maximumWidth, maximumHeight: maximumHeight)
            return (
                metrics,
                metrics.anchored(leading: layout.assist.minX, bottom: layout.assist.maxY)
            )
        }

        public var body: some View {
            @Bindable var host = host
            let (metrics, frame) = Self.geometry(in: layout, toolCount: tools.count)
            MonitorAssistPalette(
                tools: tools.map {
                    MonitorToolItem(
                        id: $0.rawValue, title: $0.rawValue,
                        enabled: host.assist.isOn($0), hasOptions: $0.hasConfiguration,
                        accessibilityLabel: $0.title)
                },
                layout: metrics, usageSeed: MonitorToolUsage.fieldMonitorSeed,
                usage: $host.assistToolUsage, expanded: $expanded,
                onToggle: { id in
                    guard !shouldCollapse, let tool = MonitorAssistSelection(rawValue: id) else {
                        return
                    }
                    host.assist.toggle(tool)
                },
                onOptions: { id in
                    guard !shouldCollapse, let tool = MonitorAssistSelection(rawValue: id) else {
                        return
                    }
                    host.assist.longPressAnchor = CGRect(
                        x: frame.x, y: frame.y, width: frame.width, height: frame.height)
                    host.assist.configureTool = tool
                },
                onExpansionActivityChange: onExpansionActivityChange,
                icon: { id in
                    if let tool = MonitorAssistSelection(rawValue: id) {
                        icon(tool)
                    }
                }
            )
            .chromeEditable(.toolBar, editing: host.chromeEditorMode, in: Host.self)
            .position(x: frame.midX, y: frame.midY)
            .frame(
                width: layout.viewport.width, height: layout.viewport.height,
                alignment: .topLeading
            )
            .onChange(of: host.assist.clean) { _, value in if value { expanded = false } }
            .onChange(of: shouldCollapse) { _, value in if value { expanded = false } }
            .onChange(of: expanded) { _, value in if value && shouldCollapse { expanded = false } }
        }
    }

    /// Compatibility projection over the single value-driven telemetry renderer.
    public struct LiveTelemetryGauges<Host: LiveChromeHost>: View {
        @Environment(Host.self) private var host
        var horizontal: Bool
        var showsLink: Bool
        var showsPower: Bool
        public init(horizontal: Bool = false, showsLink: Bool = true, showsPower: Bool = true) {
            self.horizontal = horizontal; self.showsLink = showsLink; self.showsPower = showsPower
        }
        public var body: some View {
            let percent = host.cameraStatus.batteryPercent
            MonitorOperatorTelemetry<Host.Palette>(fps: host.liveFPS, signalBars: host.liveSignalBars,
                camera: .init(id: "camera", title: "Camera battery", camera: true,
                    percent: (0...100).contains(percent) ? percent : nil, charging: host.cameraStatus.charging),
                horizontal: horizontal, showsLink: showsLink, showsPower: showsPower)
        }
        public static func batteryColor(_ percent: Int) -> Color {
            MonitorOperatorTelemetry<Host.Palette>.batteryColor(percent)
        }
        public static func cameraBattery(_ percent: Int) -> some View {
            MonitorOperatorTelemetry<Host.Palette>.gauge(icon: nil,
                value: (0...100).contains(percent) ? "\(percent)%" : "\u{2014}", bars: 0,
                color: batteryColor(percent))
                .accessibilityLabel((0...100).contains(percent)
                    ? "Camera battery \(percent) percent" : "Camera battery unavailable")
        }
    }
#endif
