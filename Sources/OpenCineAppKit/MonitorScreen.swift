#if os(iOS)
    import MonitorPresentation
    import MonitorUI
    import SwiftUI

    /// Shared screen assembly. Native picture and assists stay at fixed structural positions;
    /// native tools, detail panels and pages are bounded adapters around the common chrome.
    public struct MonitorScreen<Picture: View, Assists: View, Signal: View, Status: View, Power: View,
        Capture: View, System: View, Tools: View, Panels: View, Cover: View, Recovery: View>: View {
        private let control: MonitorControlModel
        private let layout: FieldMonitorLayout
        private let sourceAspect: Double
        private let presentation: MonitorScreenPresentation
        private let picture: @MainActor () -> Picture
        private let assists: @MainActor () -> Assists
        private let signal: @MainActor () -> Signal
        private let status: @MainActor () -> Status
        private let power: @MainActor () -> Power
        private let capture: @MainActor () -> Capture
        private let system: @MainActor () -> System
        private let tools: @MainActor () -> Tools
        private let panels: @MainActor () -> Panels
        private let cover: @MainActor () -> Cover
        private let recovery: @MainActor () -> Recovery
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        public init(control: MonitorControlModel, layout: FieldMonitorLayout, sourceAspect: Double,
            presentation: MonitorScreenPresentation,
            @ViewBuilder picture: @escaping @MainActor () -> Picture,
            @ViewBuilder assists: @escaping @MainActor () -> Assists,
            @ViewBuilder signal: @escaping @MainActor () -> Signal,
            @ViewBuilder status: @escaping @MainActor () -> Status,
            @ViewBuilder power: @escaping @MainActor () -> Power,
            @ViewBuilder capture: @escaping @MainActor () -> Capture,
            @ViewBuilder system: @escaping @MainActor () -> System,
            @ViewBuilder tools: @escaping @MainActor () -> Tools,
            @ViewBuilder panels: @escaping @MainActor () -> Panels,
            @ViewBuilder cover: @escaping @MainActor () -> Cover,
            @ViewBuilder recovery: @escaping @MainActor () -> Recovery) {
            self.control = control; self.layout = layout; self.sourceAspect = sourceAspect
            self.presentation = presentation; self.picture = picture; self.assists = assists
            self.signal = signal; self.status = status; self.power = power; self.capture = capture
            self.system = system; self.tools = tools; self.panels = panels; self.cover = cover; self.recovery = recovery
        }

        public var body: some View {
            MonitorCanvas(layout: layout, sourceAspect: sourceAspect, picture: picture, assists: assists) {
                MonitorScreenSlot(content: signal)
                    .frame(width: layout.picture.width, height: layout.picture.height)
                    .position(x: layout.picture.midX, y: layout.picture.midY)
                    .opacity(presentation.pictureWaiting ? 1 : 0)
                    .monitorPresentationVisibility(presentation.visible)
                    .accessibilityHidden(!presentation.pictureWaiting || !presentation.visible)
                    .allowsHitTesting(false)

                if layout.portrait {
                    MonitorTheme.canvas.frame(width: layout.system.width, height: layout.system.height)
                        .position(x: layout.system.midX, y: layout.system.midY).allowsHitTesting(false)
                }
                commonChrome
                    .opacity(presentation.dimmed ? 0.16 : 1)
                    .animation(MonitorMotion.dim(reduceMotion), value: presentation.dimmed)
                    .monitorPresentationVisibility(presentation.visible)
                MonitorScreenSlot(content: system)
                    .opacity(presentation.dimmed ? 0.16 : 1)
                    .animation(MonitorMotion.dim(reduceMotion), value: presentation.dimmed)
                    .monitorPresentationVisibility(presentation.visible)
                    .allowsHitTesting(presentation.visible && presentation.interactive && !presentation.transientControlsHidden)
                    .zIndex(presentation.capturePresented ? 11 : 0)
                MonitorCameraRecordingBorder(control: control)
                    .frame(width: layout.viewport.width, height: layout.viewport.height)
                    .monitorPresentationVisibility(presentation.visible)
                    .allowsHitTesting(false)
                MonitorScreenSlot(content: panels)
                    .zIndex(presentation.panelsRaised ? 16 : 10)
                    .monitorPresentationVisibility(presentation.visible)
                    .allowsHitTesting(presentation.popupInteractive && presentation.visible)
                MonitorScreenSlot(content: cover).transition(.identity).zIndex(20)
                MonitorScreenSlot(content: recovery)
                    .frame(width: layout.viewport.width, height: layout.viewport.height)
                    .zIndex(30).animation(.easeOut(duration: 0.2), value: presentation.recovering)
            }
        }

        private var commonChrome: some View {
            Group {
                MonitorScreenSlot(content: tools)
                    .allowsHitTesting(presentation.interactive && !presentation.transientControlsHidden)
                if presentation.statusMounted {
                    Group {
                        if layout.portrait {
                            MonitorScreenSlot(content: status)
                                .frame(width: layout.status.width, alignment: .topLeading)
                                .offset(x: layout.status.x, y: layout.status.y)
                        } else {
                            MonitorScreenSlot(content: status)
                                .frame(maxWidth: layout.status.width)
                                .position(x: layout.status.midX, y: layout.status.midY)
                        }
                    }
                    .allowsHitTesting(presentation.statusInteractive)
                    .accessibilityHidden(!presentation.statusInteractive || !presentation.visible || presentation.transientControlsHidden)
                }
                if presentation.powerMounted {
                    MonitorScreenSlot(content: power)
                        .frame(width: layout.telemetry.width, height: layout.telemetry.height,
                            alignment: layout.portrait && !layout.tablet ? .topTrailing : .topLeading)
                        .position(x: layout.telemetry.midX, y: layout.telemetry.midY)
                        .modifier(MonitorPowerAccessibilityVisibility(
                            hidden: !presentation.visible || presentation.transientControlsHidden))
                }
                if presentation.captureMounted {
                    MonitorScreenSlot(content: capture)
                        .frame(width: layout.values.width, height: layout.values.height, alignment: .bottom)
                        .position(x: layout.values.midX, y: layout.values.midY)
                        .opacity(presentation.captureHidden ? 0 : (presentation.locked ? 0.4 : 1))
                        .allowsHitTesting(!presentation.captureHidden && !presentation.locked && presentation.captureInteractive)
                        .accessibilityHidden(presentation.captureHidden || !presentation.visible || presentation.transientControlsHidden)
                }
            }
            .allowsHitTesting(presentation.interactive && !presentation.transientControlsHidden && presentation.visible)
            // No AX attachment on the Group or the tools and system slots: while visible it would
            // override a control that hides itself (Pocket's zoom chip under a picker). Their
            // content hides per control; covered chrome is excluded by zero opacity.
        }
    }

    /// A visible container preserves the hidden state of decorative child content.
    private struct MonitorPowerAccessibilityVisibility: ViewModifier {
        let hidden: Bool
        @ViewBuilder
        func body(content: Content) -> some View {
            if hidden {
                content.accessibilityHidden(true)
            } else {
                content
            }
        }
    }

    private struct MonitorScreenSlot<Content: View>: View {
        let content: @MainActor () -> Content
        var body: some View { content() }
    }

    /// Record telemetry is observed here, outside picture geometry and native host ownership.
    private struct MonitorCameraRecordingBorder: View {
        let control: MonitorControlModel
        var body: some View {
            if control.isRecording == true { MonitorRecordingBorder() }
        }
    }
#endif
