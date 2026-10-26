#if os(iOS)
    import MonitorUI
    import SwiftUI
    import UIKit

    /// The grays and tile colors the approved gyro mockups use on the monitor background.
    enum GyroPalette {
        static let overline = MonitorTheme.color(0x8B8D90)
        static let hint = MonitorTheme.color(0x8B8D90)
        static let body = MonitorTheme.color(0xA7A9AC)
        static let track = MonitorTheme.color(0x2C2D2F)
        static let glyphBody = MonitorTheme.color(0x2A2B2D)
        static let dotOff = MonitorTheme.color(0x3A3B3D)
        static let tile = MonitorTheme.color(0x222425)
        static let hairline = MonitorTheme.color(0x1F2021)
        static let tipBorder = MonitorTheme.color(0x2A2B2D)
        static let green = MonitorTheme.color(0x2EC76B)
        static let orange = MonitorTheme.color(0xF5851F)
        static let red = MonitorTheme.color(0xFF453A)
    }

    /// What the arming sheet and the calibration screens can ask of the host.
    public struct GyroSetupActions {
        public var turnOff: () -> Void
        public var keepOn: () -> Void
        public var getStarted: () -> Void
        public var useLast: () -> Void
        public var cancel: () -> Void
        public var done: () -> Void

        public init(
            turnOff: @escaping () -> Void = {}, keepOn: @escaping () -> Void = {},
            getStarted: @escaping () -> Void = {}, useLast: @escaping () -> Void = {},
            cancel: @escaping () -> Void = {}, done: @escaping () -> Void = {}
        ) {
            self.turnOff = turnOff
            self.keepOn = keepOn
            self.getStarted = getStarted
            self.useLast = useLast
            self.cancel = cancel
            self.done = done
        }
    }

    /// Speaks a short phrase to VoiceOver and tells it when the screen changed. Injectable so
    /// tests can record both.
    public struct GyroAnnouncer: Sendable {
        public let announce: @MainActor @Sendable (String) -> Void
        /// Called when the content of one presentation is replaced by a new screen, so VoiceOver
        /// moves its focus to it.
        public let screenChanged: @MainActor @Sendable () -> Void

        public init(
            announce: @escaping @MainActor @Sendable (String) -> Void,
            screenChanged: @escaping @MainActor @Sendable () -> Void = {}
        ) {
            self.announce = announce
            self.screenChanged = screenChanged
        }

        /// Posts VoiceOver announcements and screen changes through the system.
        public static let system = GyroAnnouncer(
            announce: { text in AccessibilityNotification.Announcement(text).post() },
            screenChanged: { UIAccessibility.post(notification: .screenChanged, argument: nil) })
    }

    private struct GyroAnnouncerKey: EnvironmentKey {
        static let defaultValue = GyroAnnouncer.system
    }

    private struct GyroHapticsKey: EnvironmentKey {
        static let defaultValue = OperatorHaptics(isEnabled: { true })
    }

    private struct GyroIsLandscapeKey: EnvironmentKey {
        static let defaultValue = false
    }

    extension EnvironmentValues {
        /// True inside a `GyroAdaptiveStack` laid out in landscape (visual left, text right).
        var gyroIsLandscape: Bool {
            get { self[GyroIsLandscapeKey.self] }
            set { self[GyroIsLandscapeKey.self] = newValue }
        }

        /// Where the gyro screens send VoiceOver announcements.
        public var gyroAnnouncer: GyroAnnouncer {
            get { self[GyroAnnouncerKey.self] }
            set { self[GyroAnnouncerKey.self] = newValue }
        }

        /// The haptics the gyro screens fire on a captured step.
        public var gyroHaptics: OperatorHaptics {
            get { self[GyroHapticsKey.self] }
            set { self[GyroHapticsKey.self] = newValue }
        }
    }

    /// The one primary button of every gyro screen: accent fill, full width, radius 12.
    public struct GyroPrimaryButtonStyle: ButtonStyle {
        public init() {}

        public func makeBody(configuration: Configuration) -> some View {
            Label(configuration: configuration)
        }

        private struct Label: View {
            let configuration: ButtonStyleConfiguration
            @Environment(\.isEnabled) private var isEnabled

            var body: some View {
                configuration.label
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(MonitorTheme.onAccent)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .background(
                        MonitorTheme.accent.opacity(isEnabled ? 1 : 0.35),
                        in: RoundedRectangle(cornerRadius: MonitorTheme.radius, style: .continuous)
                    )
                    .opacity(configuration.isPressed ? 0.8 : 1)
                    .contentShape(Rectangle())
            }
        }
    }

    /// A primary button carrying the shared identifier tests count.
    public struct GyroPrimaryButton: View {
        private let title: String
        private let identifier: String
        private let action: () -> Void

        public init(
            _ title: String, identifier: String = "gyro.primary", action: @escaping () -> Void
        ) {
            self.title = title
            self.identifier = identifier
            self.action = action
        }

        public var body: some View {
            Button(action: action) { Text(title) }
                .buttonStyle(GyroPrimaryButtonStyle())
                .accessibilityIdentifier(identifier)
        }
    }

    /// A secondary action: plain text in the accent or white, never filled.
    struct GyroTextButton: View {
        let title: String
        var tint: Color = MonitorTheme.accent
        var identifier: String
        let action: () -> Void

        var body: some View {
            Button(action: action) {
                Text(title)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(tint)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(identifier)
        }
    }

    /// Content that scrolls only when it is taller than the room it is given. When it fits it is
    /// plain content (reachable without a scroll host); when it does not, it sits in a scroll view.
    struct GyroFitScroll<Content: View>: View {
        private let content: Content

        init(@ViewBuilder content: () -> Content) { self.content = content() }

        var body: some View {
            ViewThatFits(in: .vertical) {
                content
                ScrollView { content }
            }
        }
    }

    /// Reads the stack's orientation for the views placed inside it.
    struct GyroLandscapeReader<Content: View>: View {
        @Environment(\.gyroIsLandscape) private var landscape
        let content: (Bool) -> Content

        init(@ViewBuilder content: @escaping (Bool) -> Content) { self.content = content }

        var body: some View { content(landscape) }
    }

    /// 12 pt uppercase letter-spaced gray line above a title.
    struct GyroOverline: View {
        let text: String
        var body: some View {
            Text(text.uppercased())
                .font(.system(size: 12, weight: .regular))
                .tracking(0.8)
                .foregroundStyle(GyroPalette.overline)
                .accessibilityLabel(text)
        }
    }

    /// The camera body, top hump and accent-outlined lens of the mockup's `#cam` symbol.
    struct GyroCameraGlyph: View {
        /// The glyph's body width; the mockup's symbol is 50 units wide.
        let width: CGFloat

        var body: some View {
            let s = width / 50
            ZStack {
                RoundedRectangle(cornerRadius: 6 * s, style: .continuous)
                    .fill(GyroPalette.glyphBody)
                    .frame(width: 50 * s, height: 32 * s)
                RoundedRectangle(cornerRadius: 2 * s, style: .continuous)
                    .fill(GyroPalette.glyphBody)
                    .frame(width: 14 * s, height: 7 * s)
                    .offset(x: -13 * s, y: -18.5 * s)
                Circle().fill(MonitorTheme.background)
                    .overlay(Circle().stroke(MonitorTheme.accent, lineWidth: 2 * s))
                    .frame(width: 22 * s, height: 22 * s)
            }
            .frame(width: 50 * s, height: 44 * s)
        }
    }

    /// The mockup's `#check`: an accent ring with an accent checkmark, stroked, not filled.
    struct GyroCheckGlyph: View {
        let size: CGFloat
        var color: Color = MonitorTheme.accent

        var body: some View {
            let s = size / 110
            ZStack {
                Circle().stroke(color, lineWidth: 9 * s).frame(width: 80 * s, height: 80 * s)
                GyroCheckMark().stroke(
                    color, style: StrokeStyle(lineWidth: 7 * s, lineCap: .round, lineJoin: .round)
                )
                .frame(width: 110 * s, height: 110 * s)
            }
            .frame(width: size, height: size)
        }
    }

    /// The `#check` tick on a 110 unit square.
    struct GyroCheckMark: Shape {
        func path(in rect: CGRect) -> Path {
            let s = rect.width / 110
            let c = CGPoint(x: rect.midX, y: rect.midY)
            var path = Path()
            path.move(to: CGPoint(x: c.x - 17 * s, y: c.y + 2 * s))
            path.addLine(to: CGPoint(x: c.x - 6 * s, y: c.y + 13 * s))
            path.addLine(to: CGPoint(x: c.x + 18 * s, y: c.y - 12 * s))
            return path
        }
    }
#endif
