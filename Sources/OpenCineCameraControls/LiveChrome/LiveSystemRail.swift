#if os(iOS)
    import MonitorPresentation
    import MonitorUI
    import OpenCineAppKitApple
    import OpenCineMedia
    import SwiftUI

    /// The system rail over the shared composition: lock (or Return to Multiview), settings,
    /// media, the host's record button and its DISP toggle.
    public struct LiveSystemRail<Host: LiveChromeHost, Record: View, Display: View>: View {
        @Environment(Host.self) private var host
        @Binding var locked: Bool
        let layout: FieldMonitorLayout
        let capturePresented: Bool
        let visible: Bool
        let interactive: Bool
        let record: (CGFloat) -> Record
        let display: (CGSize) -> Display

        /// `record` draws the record button at a diameter, `display` the DISP toggle at a size.
        public init(
            locked: Binding<Bool>, layout: FieldMonitorLayout, capturePresented: Bool,
            visible: Bool, interactive: Bool,
            @ViewBuilder record: @escaping (CGFloat) -> Record,
            @ViewBuilder display: @escaping (CGSize) -> Display
        ) {
            _locked = locked
            self.layout = layout
            self.capturePresented = capturePresented
            self.visible = visible
            self.interactive = interactive
            self.record = record
            self.display = display
        }

        public var body: some View {
            let editing = host.chromeEditorMode
            let visibility = MonitorSystemControlsVisibility(
                lock: host.multiviewExit != nil || host.chromeSectionMounts(.lockButton),
                settings: host.chromeSectionMounts(.railSettings),
                media: host.chromeSectionMounts(.railMedia),
                record: host.chromeSectionMounts(.railRecord)
            ).resolved(
                locked: locked, recording: host.control.isRecording,
                borrowed: host.multiviewBorrowed)
            MonitorSystemControls(
                layout: layout, visibility: visibility, capturePresented: capturePresented,
                visible: visible, interactive: interactive,
                navigationHidden: host.captureDrum != nil
                    || (host.captureSheet != nil && !layout.portrait)
            ) {
                if let exit = host.multiviewExit {
                    MonitorChromeButton(
                        "Return to Multiview",
                        size: CGSize(width: layout.lock.width, height: layout.lock.height),
                        action: exit
                    ) {
                        MonitorIcon.layoutGrid.frame(
                            width: layout.lock.width * 29 / 54,
                            height: layout.lock.height * 29 / 54)
                    }
                } else {
                    MonitorLockButton(locked: $locked, side: layout.lock.width)
                        .chromeEditable(.lockButton, editing: editing, in: Host.self)
                }
            } settings: {
                LiveSettingsButton(size: layout.settings.width) { host.openSettings() }
                    .chromeEditable(.railSettings, editing: editing, in: Host.self)
            } media: {
                LiveMediaButton(size: layout.media.width) { host.openMedia() }
                    .chromeEditable(.railMedia, editing: editing, in: Host.self)
            } record: {
                record(layout.record.width)
                    .chromeEditable(.railRecord, editing: editing, in: Host.self)
            } display: {
                display(CGSize(width: layout.display.width, height: layout.display.height))
            }
            .environment(\.interfaceLocked, locked)
        }
    }

    /// The reference monitor's settings key on the system rail.
    public struct LiveSettingsButton: View {
        @Environment(\.interfaceLocked) private var locked
        var size: CGFloat
        var onOpen: () -> Void

        public init(
            size: CGFloat = LiveChromeMetrics.auxiliaryButtonSize, onOpen: @escaping () -> Void
        ) {
            self.size = size
            self.onOpen = onOpen
        }

        public var body: some View {
            MonitorChromeButton(
                "Open Operator Setup", size: CGSize(width: size, height: size), action: onOpen
            ) {
                MonitorIcon.settings.frame(width: size * 29 / 54, height: size * 29 / 54)
            }
            .disabled(locked)
            .accessibilityLabel("Open Operator Setup")
            .accessibilityIdentifier("monitor.system.settings")
        }
    }

    /// The reference monitor's media key on the system rail.
    public struct LiveMediaButton: View {
        @Environment(\.interfaceLocked) private var locked
        var size: CGFloat
        var onOpen: () -> Void

        public init(
            size: CGFloat = LiveChromeMetrics.auxiliaryButtonSize, onOpen: @escaping () -> Void
        ) {
            self.size = size
            self.onOpen = onOpen
        }

        public var body: some View {
            MonitorChromeButton(
                "Open Media", size: CGSize(width: size, height: size), action: onOpen
            ) {
                MonitorIcon.film.frame(width: size * 29 / 54, height: size * 29 / 54)
            }
            .disabled(locked)
            .accessibilityLabel("Open Media")
            .accessibilityIdentifier("monitor.system.media")
        }
    }

    /// Resets AF to centre and ends tracking. Uses the Settings reset glyph so it
    /// is not mistaken for the gimbal recenter crosshair.
    public struct FocusResetButton<Host: LiveChromeHost>: View {
        @Environment(Host.self) private var host

        public init() {}

        public var body: some View {
            MonitorFocusResetButton(
                foreground: Host.Palette.text, outline: Host.Palette.hairline
            ) {
                host.focusBoxLocked = false
                host.resetFocusPoint()
            }
        }
    }

    /// Beside the recenter key while AE is locked: releases the lock back to Auto.
    public struct AutoExposureUnlockButton<Host: LiveChromeHost>: View {
        @Environment(Host.self) private var host

        public init() {}

        public var body: some View {
            let size = LiveChromeMetrics.focusResetSize
            Button {
                host.unlockAutoExposure()
            } label: {
                HStack(spacing: 2) {
                    MonitorIcon.sun.frame(width: 15, height: 15)
                    MonitorIcon.lockOpen.frame(width: 13, height: 13)
                }
                .foregroundStyle(Host.Palette.aeLock)
                .frame(width: size * 1.5, height: size)
                .background(.black.opacity(0.55), in: Capsule())
                .overlay(Capsule().strokeBorder(Host.Palette.hairline, lineWidth: 1))
            }
            .buttonStyle(.monitorTapTarget)
            .accessibilityLabel("Unlock exposure")
            .accessibilityHint("Returns exposure to Auto")
            .accessibilityIdentifier("monitor.system.aeUnlock")
        }
    }

    /// Compass Head Lock starts tracking; the same control becomes STOP.
    public struct HeadTrackCalibrateButton<Palette: LiveChromePalette>: View {
        var title: String
        var onTap: () -> Void

        public init(title: String, onTap: @escaping () -> Void) {
            self.title = title
            self.onTap = onTap
        }

        private var isStop: Bool { title == HeadphoneMotionBridge.stopTitle }
        private var size: CGFloat { LiveChromeMetrics.zoomButtonSize }

        public var body: some View {
            Button(action: onTap) {
                MonitorIcon.compass
                    .frame(width: 18, height: 18)
                    .foregroundStyle(isStop ? Palette.background : Palette.text)
                    .frame(width: size, height: size)
                    .background { plateFill }
                    .overlay { plateStroke }
            }
            .buttonStyle(.monitorTapTarget)
            .accessibilityLabel(isStop ? "Stop head tracking" : "Calibrate Head Lock")
            .accessibilityHint(
                isStop
                    ? "Stops AirPods gimbal tracking" : "Sets the current heading as forward"
            )
            .accessibilityIdentifier("monitor.system.headTrackCalibrate")
        }

        @ViewBuilder private var plateFill: some View {
            if isStop {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Palette.accent)
            } else {
                Circle().fill(.black.opacity(0.55))
            }
        }

        @ViewBuilder private var plateStroke: some View {
            if isStop {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Palette.hairline, lineWidth: 1)
            } else {
                Circle().strokeBorder(Palette.hairline, lineWidth: 1)
            }
        }
    }

    /// Fit/fill quick key. Lives just under a landscape 16:9 well; in fill it
    /// parks above the capture strip / system rail so the rail cannot cover it.
    public struct PortraitAspectToggle<Palette: LiveChromePalette>: View {
        @Binding var aspect: PortraitFeedAspect
        var showsLabel: Bool

        public init(aspect: Binding<PortraitFeedAspect>, showsLabel: Bool = false) {
            _aspect = aspect
            self.showsLabel = showsLabel
        }

        public var body: some View {
            Button {
                aspect = aspect == .fill ? .fit16x9 : .fill
            } label: {
                if showsLabel {
                    VStack(spacing: 3) {
                        (aspect == .fill ? MonitorIcon.minimize : MonitorIcon.maximize)
                            .frame(width: 20, height: 20)
                        Text(aspect == .fill ? "FILL" : "FIT")
                            .font(MonitorTheme.font(11, weight: .semibold))
                    }
                    .foregroundStyle(Palette.text)
                    .frame(minWidth: 54, minHeight: 50)
                    .contentShape(Rectangle())
                } else {
                    (aspect == .fill ? MonitorIcon.minimize : MonitorIcon.maximize)
                        .frame(width: 15, height: 15)
                        .foregroundStyle(Palette.text)
                        .frame(width: 40, height: 40)
                        .background(.black.opacity(0.55), in: Circle())
                        .overlay(Circle().strokeBorder(Palette.hairline, lineWidth: 1))
                }
            }
            .buttonStyle(.monitorTapTarget)
            .accessibilityLabel(aspect == .fill ? "Fit feed in frame" : "Fill frame with feed")
            .accessibilityValue(aspect == .fill ? "Fill" : "Fit")
        }
    }
#endif
