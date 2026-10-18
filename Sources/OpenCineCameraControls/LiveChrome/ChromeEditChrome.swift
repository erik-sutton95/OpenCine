#if os(iOS)
    import MonitorUI
    import OpenCineAppKit
    import OpenCineCameraVocabulary
    import SwiftUI

    // MARK: - Edit view (per-DISP chrome)

    /// What the chrome editor needs from an app: its own sections and DISP modes, their names,
    /// which sections a mode offers, and the operator's per-mode choice. `LiveChromeHost` apps get
    /// it from `MonitorDisplayChrome`; an app with its own sections and modes supplies them.
    @MainActor
    public protocol ChromeEditHost: AnyObject, Observable {
        associatedtype Palette: LiveChromePalette
        associatedtype ChromeSection: Hashable
        associatedtype ChromeMode

        var hapticsEnabled: Bool { get }
        /// Every section, in badge placement priority (containers before what nests in them).
        var chromeEditSections: [ChromeSection] { get }
        func chromeSectionTitle(_ section: ChromeSection) -> String
        /// The stable name in the badge's accessibility identifier.
        func chromeSectionID(_ section: ChromeSection) -> String
        func chromeModeTitle(_ mode: ChromeMode) -> String
        func isChromeConfigurable(_ section: ChromeSection, in mode: ChromeMode) -> Bool
        func isChromeVisible(_ section: ChromeSection, in mode: ChromeMode) -> Bool
        func toggleChrome(_ section: ChromeSection, for mode: ChromeMode)
        func endChromeEditing()
    }

    /// Measured bounds of every badgeable monitor element, in canvas space.
    ///
    /// Boxes are measured, never derived from the zone map: a zone frame is a layout
    /// budget, and several elements draw inset within theirs.
    public struct ChromeEditSectionBoundsKey<Section: Hashable>: PreferenceKey {
        public static var defaultValue: [Section: CGRect] { [:] }

        public static func reduce(
            value: inout [Section: CGRect],
            nextValue: () -> [Section: CGRect]
        ) {
            value.merge(nextValue()) { existing, next in existing.union(next) }
        }
    }

    public typealias ChromeEditBoundsKey = ChromeEditSectionBoundsKey<MonitorDisplayChrome.Section>

    public enum ChromeEditSpace {
        public static var name: String { LiveCanvasSpace.name }
    }

    extension View {
        func chromeEditable<Host: ChromeEditHost>(
            _ section: Host.ChromeSection,
            editing mode: Host.ChromeMode?,
            in host: Host.Type
        ) -> some View {
            modifier(ChromeEditableModifier<Host>(section: section, mode: mode))
        }
    }

    /// Dims a hidden element and outlines every configurable one while its DISP mode is edited,
    /// and reports its bounds for the eye badges.
    public struct ChromeEditableModifier<Host: ChromeEditHost>: ViewModifier {
        @Environment(Host.self) private var host
        let section: Host.ChromeSection
        let mode: Host.ChromeMode?

        public init(section: Host.ChromeSection, mode: Host.ChromeMode?) {
            self.section = section
            self.mode = mode
        }

        public func body(content: Content) -> some View {
            if let mode, host.isChromeConfigurable(section, in: mode) {
                let on = host.isChromeVisible(section, in: mode)
                content
                    .opacity(on ? 1 : 0.3)
                    .background {
                        GeometryReader { proxy in
                            Color.clear.preference(
                                key: ChromeEditSectionBoundsKey<Host.ChromeSection>.self,
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
    struct ChromeEditBadge<Host: ChromeEditHost>: View {
        @Environment(Host.self) private var host
        let section: Host.ChromeSection
        let mode: Host.ChromeMode

        var body: some View {
            let on = host.isChromeVisible(section, in: mode)
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
            .minTapTarget(MonitorChromeEditBadgeLayout.touchTarget)
            .accessibilityLabel(host.chromeSectionTitle(section))
            .accessibilityValue(on ? "Shown" : "Hidden")
            .accessibilityHint("Shows or hides this on \(host.chromeModeTitle(mode))")
            .accessibilityIdentifier("monitor.chromeEdit.\(host.chromeSectionID(section))")
        }
    }

    /// The eye badges over every measured element of the DISP mode being edited.
    public struct ChromeEditBadges<Host: ChromeEditHost>: View {
        @Environment(Host.self) private var host
        let mode: Host.ChromeMode
        let boxes: [Host.ChromeSection: CGRect]
        let viewport: CGSize

        public init(
            mode: Host.ChromeMode, boxes: [Host.ChromeSection: CGRect],
            viewport: CGSize
        ) {
            self.mode = mode
            self.boxes = boxes
            self.viewport = viewport
        }

        public var body: some View {
            // Section order is the placement priority.
            let frames = MonitorChromeEditBadgeLayout.badgeFrames(
                keyed: host.chromeEditSections.compactMap { section in
                    boxes[section].map { (key: section, frame: $0) }
                },
                viewport: viewport
            )
            ZStack(alignment: .topLeading) {
                ForEach(host.chromeEditSections, id: \.self) { section in
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
    public struct ChromeEditDoneBanner<Host: ChromeEditHost>: View {
        @Environment(Host.self) private var host
        let mode: Host.ChromeMode

        public init(mode: Host.ChromeMode) {
            self.mode = mode
        }

        public var body: some View {
            HStack(spacing: 10) {
                MonitorIcon.eye
                    .frame(width: 11, height: 11)
                    .foregroundStyle(Host.Palette.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Editing \(host.chromeModeTitle(mode))")
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
        }
    }

    /// Where the chrome editor badges the focus box.
    public enum LiveChromeEditGeometry {
        /// Badge the drawn AF / head box; stand in at the AF point when nothing is locked.
        public static func focusEditRect(
            overlay: FocusOverlay,
            faces: [TrackingBox],
            focusPoint: CGPoint,
            mirrored: Bool,
            flippedVertically: Bool = false,
            in feed: CGRect
        ) -> CGRect {
            let tracked: TrackingBox?
            switch overlay {
            case .search(let box), .subject(let box), .face(let box):
                tracked = box
            case .focus:
                tracked = faces.first
            }
            if let box = tracked {
                let drawn = box.flipped(horizontal: mirrored, vertical: flippedVertically)
                return CGRect(
                    x: feed.minX + drawn.x * feed.width,
                    y: feed.minY + drawn.y * feed.height,
                    width: max(1, drawn.width * feed.width),
                    height: max(1, drawn.height * feed.height)
                )
            }
            let side = min(feed.width, feed.height) * 0.14
            let x = mirrored ? 1 - focusPoint.x : focusPoint.x
            let y = flippedVertically ? 1 - focusPoint.y : focusPoint.y
            return CGRect(
                x: feed.minX + x * feed.width - side / 2,
                y: feed.minY + y * feed.height - side / 2,
                width: side,
                height: side
            )
        }
    }
#endif
