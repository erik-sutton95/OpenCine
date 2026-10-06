#if os(iOS)
    import MonitorUI
    import OpenCineAppKit
    import SwiftUI

    // MARK: - Edit view (per-DISP chrome)

    /// Measured bounds of every badgeable monitor element, in canvas space.
    ///
    /// Boxes are measured, never derived from the zone map: a zone frame is a layout
    /// budget, and several elements draw inset within theirs.
    public struct ChromeEditBoundsKey: PreferenceKey {
        public static var defaultValue: [MonitorDisplayChrome.Section: CGRect] { [:] }

        public static func reduce(
            value: inout [MonitorDisplayChrome.Section: CGRect],
            nextValue: () -> [MonitorDisplayChrome.Section: CGRect]
        ) {
            value.merge(nextValue()) { existing, next in existing.union(next) }
        }
    }

    public enum ChromeEditSpace {
        public static var name: String { LiveCanvasSpace.name }
    }

    extension View {
        func chromeEditable<Host: LiveChromeHost>(
            _ section: MonitorDisplayChrome.Section,
            editing mode: MonitorDisplayMode?,
            in host: Host.Type
        ) -> some View {
            modifier(ChromeEditableModifier<Host>(section: section, mode: mode))
        }
    }

    /// Dims a hidden element and outlines every configurable one while its DISP mode is edited,
    /// and reports its bounds for the eye badges.
    public struct ChromeEditableModifier<Host: LiveChromeHost>: ViewModifier {
        @Environment(Host.self) private var host
        let section: MonitorDisplayChrome.Section
        let mode: MonitorDisplayMode?

        public init(section: MonitorDisplayChrome.Section, mode: MonitorDisplayMode?) {
            self.section = section
            self.mode = mode
        }

        public func body(content: Content) -> some View {
            if let mode, MonitorDisplayChrome.isConfigurable(section, in: mode) {
                let on = host.chrome(for: mode).isVisible(section)
                content
                    .opacity(on ? 1 : 0.3)
                    .background {
                        GeometryReader { proxy in
                            Color.clear.preference(
                                key: ChromeEditBoundsKey.self,
                                value: [section: proxy.frame(in: .named(ChromeEditSpace.name))]
                            )
                        }
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(
                                on
                                    ? Host.Palette.accent.opacity(0.75)
                                    : Host.Palette.muted.opacity(0.75),
                                style: StrokeStyle(lineWidth: 1, dash: [3, 3])
                            )
                            .padding(-2)
                    }
            } else {
                content
            }
        }
    }

    /// One eye badge. Tapping it shows or hides that element for the DISP mode being edited.
    struct ChromeEditBadge<Host: LiveChromeHost>: View {
        @Environment(Host.self) private var host
        let section: MonitorDisplayChrome.Section
        let mode: MonitorDisplayMode

        var body: some View {
            let on = host.chrome(for: mode).isVisible(section)
            Button {
                OperatorSettingsHaptics.selection(enabled: host.hapticsEnabled)
                host.toggleChrome(section, for: mode)
            } label: {
                (on ? MonitorIcon.eye : MonitorIcon.eyeOff)
                    .frame(width: 11, height: 11)
                    .foregroundStyle(on ? Host.Palette.background : Host.Palette.text)
                    .frame(
                        width: MonitorChromeEditBadgeLayout.badgeSize,
                        height: MonitorChromeEditBadgeLayout.badgeSize
                    )
                    .background(on ? Host.Palette.accent : Color.black.opacity(0.9), in: Circle())
                    .overlay(Circle().strokeBorder(Host.Palette.text.opacity(0.55), lineWidth: 1))
            }
            .buttonStyle(.monitorTapTarget)
            .minTapTarget()
            .accessibilityLabel(section.title)
            .accessibilityValue(on ? "Shown" : "Hidden")
            .accessibilityHint("Shows or hides this on \(mode.title)")
            .accessibilityIdentifier("monitor.chromeEdit.\(section.rawValue)")
        }
    }

    /// The eye badges over every measured element of the DISP mode being edited.
    public struct ChromeEditBadges<Host: LiveChromeHost>: View {
        @Environment(Host.self) private var host
        let mode: MonitorDisplayMode
        let boxes: [MonitorDisplayChrome.Section: CGRect]
        let viewport: CGSize

        public init(
            mode: MonitorDisplayMode, boxes: [MonitorDisplayChrome.Section: CGRect],
            viewport: CGSize
        ) {
            self.mode = mode
            self.boxes = boxes
            self.viewport = viewport
        }

        public var body: some View {
            let frames = MonitorChromeEditBadgeLayout.badgeFrames(
                MonitorDisplayChrome.Section.allCases.compactMap { section in
                    boxes[section].map {
                        MonitorChromeEditBadgeLayout.Box(section: section, frame: $0)
                    }
                },
                viewport: viewport
            )
            ZStack(alignment: .topLeading) {
                ForEach(MonitorDisplayChrome.Section.allCases) { section in
                    if let frame = frames[section] {
                        ChromeEditBadge<Host>(section: section, mode: mode)
                            .environment(host)
                            .liveModuleFrame(frame)
                    }
                }
            }
            .frame(width: viewport.width, height: viewport.height, alignment: .topLeading)
        }
    }

    /// Names the mode being edited and gets the operator back to Display settings.
    public struct ChromeEditDoneBanner<Host: LiveChromeHost>: View {
        @Environment(Host.self) private var host
        let mode: MonitorDisplayMode

        public init(mode: MonitorDisplayMode) {
            self.mode = mode
        }

        public var body: some View {
            HStack(spacing: 10) {
                MonitorIcon.eye
                    .frame(width: 11, height: 11)
                    .foregroundStyle(Host.Palette.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Editing \(mode.title)")
                        .font(MonitorTheme.font(11.5, weight: .semibold))
                        .foregroundStyle(Host.Palette.text)
                    Text("Tap an eye to show or hide it")
                        .font(MonitorTheme.font(10, weight: .regular))
                        .foregroundStyle(Host.Palette.muted)
                }
                Button {
                    host.endChromeEditing()
                } label: {
                    Text("Done")
                        .font(MonitorTheme.font(11.5, weight: .bold))
                        .foregroundStyle(Host.Palette.background)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Host.Palette.accent, in: Capsule())
                }
                .buttonStyle(.monitorTapTarget)
                .accessibilityIdentifier("monitor.chromeEdit.done")
            }
            .padding(.leading, 12)
            .padding(.trailing, 6)
            .padding(.vertical, 6)
            .liquidGlass(in: Capsule())
            .accessibilityIdentifier("monitor.chromeEdit.banner")
        }
    }
#endif
