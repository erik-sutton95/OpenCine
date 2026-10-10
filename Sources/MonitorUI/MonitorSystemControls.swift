#if os(iOS)
    import MonitorPresentation
    import SwiftUI

    /// Shared system placement. Five bounded control builders allow app-owned edit decoration
    /// and borrowed-session return, without handing the entire monitor composition to an app.
    public struct MonitorSystemControls<Lock: View, Settings: View, Media: View, Record: View, Display: View>: View {
        private let layout: FieldMonitorLayout
        private let visibility: MonitorSystemControlsVisibility
        private let capturePresented: Bool
        private let navigationHidden: Bool
        private let visible: Bool
        private let interactive: Bool
        private let lock: () -> Lock
        private let settings: () -> Settings
        private let media: () -> Media
        private let record: () -> Record
        private let display: () -> Display
        @Environment(\.monitorPresentationIsVisible) private var presentationIsVisible

        public init(
            layout: FieldMonitorLayout, visibility: MonitorSystemControlsVisibility,
            capturePresented: Bool = false, visible: Bool = true, interactive: Bool = true,
            navigationHidden: Bool? = nil,
            @ViewBuilder lock: @escaping () -> Lock,
            @ViewBuilder settings: @escaping () -> Settings,
            @ViewBuilder media: @escaping () -> Media,
            @ViewBuilder record: @escaping () -> Record,
            @ViewBuilder display: @escaping () -> Display
        ) {
            self.layout = layout
            self.visibility = visibility
            self.capturePresented = capturePresented
            self.navigationHidden = navigationHidden ?? capturePresented
            self.visible = visible
            self.interactive = interactive
            self.lock = lock
            self.settings = settings
            self.media = media
            self.record = record
            self.display = display
        }

        public var body: some View {
            Group {
                if visibility.lock { place(layout.lock, content: lock) }
                if visibility.settings {
                    place(layout.settings, content: settings)
                        .opacity(navigationHidden ? 0 : 1)
                        .allowsHitTesting(!navigationHidden)
                        .accessibilityHidden(navigationHidden || !exposed)
                }
                if visibility.media {
                    place(layout.media, content: media)
                        .opacity(navigationHidden ? 0 : 1)
                        .allowsHitTesting(!navigationHidden)
                        .accessibilityHidden(navigationHidden || !exposed)
                }
                // Constant structural positions preserve confirmation and display state while
                // a popup enters. Their z-index allows Stop and DISP above the capture backdrop.
                if visibility.record {
                    place(layout.record, content: record).zIndex(capturePresented ? 11 : 0)
                }
                if visibility.display {
                    place(layout.display, content: display).zIndex(capturePresented ? 11 : 0)
                }
            }
            .allowsHitTesting(interactive && visible)
        }

        /// Each control's explicit AX attachment beats zero opacity, so a covered screen must
        /// hide it here even when the app leaves `visible` at its default.
        private var exposed: Bool { visible && presentationIsVisible }

        private func place<Content: View>(_ rect: MonitorRect, @ViewBuilder content: () -> Content) -> some View {
            content()
                .accessibilityHidden(!exposed)
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
        }
    }

    public struct MonitorLockButton: View {
        @Binding private var locked: Bool
        private let side: CGFloat

        public init(locked: Binding<Bool>, side: CGFloat) {
            _locked = locked
            self.side = side
        }

        public var body: some View {
            MonitorChromeButton(locked ? "Unlock monitor controls" : "Lock monitor controls",
                size: CGSize(width: side, height: side), active: locked) { locked.toggle() } label: {
                MonitorIcon.lock.frame(width: side * 26 / 54, height: side * 26 / 54)
            }
            .sensoryFeedback(.impact(weight: .medium), trigger: locked)
            .accessibilityHint("Prevents accidental camera and View Assist changes")
            .accessibilityIdentifier("monitor.system.lock")
        }
    }

    public struct MonitorDisplayButton: View {
        private let selectedIndex: Int?
        private let modeCount: Int
        private let title: String
        private let mutedLabel: Bool
        private let size: CGSize
        private let enabled: Bool
        private let action: () -> Void

        public init(clean: Bool, size: CGSize, enabled: Bool = true, action: @escaping () -> Void) {
            self.init(selectedIndex: clean ? 1 : 0, modeCount: 2,
                title: clean ? "DISP 2 clean" : "DISP 1 live", size: size, enabled: enabled,
                mutedLabel: !clean, action: action)
        }

        /// The source supplies admitted mode count and selection; unknown selection lights no dash.
        public init(selectedIndex: Int?, modeCount: Int, title: String,
            size: CGSize, enabled: Bool = true, mutedLabel: Bool = false, action: @escaping () -> Void) {
            self.selectedIndex = selectedIndex
            self.modeCount = max(0, modeCount)
            self.title = title
            self.mutedLabel = mutedLabel
            self.size = size
            self.enabled = enabled
            self.action = action
        }

        public var body: some View {
            MonitorChromeButton("Change display mode", size: size, action: action) {
                VStack(spacing: 3) {
                    Text("DISP").font(MonitorTheme.font(CGFloat(MonitorCapturePopupChrome.dispSize), weight: .bold))
                        .tracking(CGFloat(MonitorCapturePopupChrome.dispTracking))
                    HStack(spacing: 3) {
                        ForEach(0..<modeCount, id: \.self) { index in
                            Capsule().fill(selectedIndex == index ? MonitorTheme.accent : MonitorTheme.faint.opacity(0.5))
                                .frame(width: 14, height: 3)
                        }
                    }
                }.foregroundStyle(mutedLabel ? MonitorTheme.muted : MonitorTheme.text)
            }
            .disabled(!enabled)
            .sensoryFeedback(.selection, trigger: selectedIndex)
            .accessibilityValue(title)
            .accessibilityIdentifier("monitor.system.display")
        }
    }
#endif
