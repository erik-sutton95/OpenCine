#if os(iOS)
    import MonitorPresentation
    import SwiftUI
    import UIKit

    public typealias MonitorChromeStyle = MonitorPresentation.MonitorChromeStyle

    private struct MonitorChromeStyleKey: EnvironmentKey {
        static let defaultValue = MonitorChromeStyle.device
    }

    extension EnvironmentValues {
        /// Device (a phone or tablet screen) or desktop (a window whose title bar is a toolbar).
        /// A host sets desktop only where it runs as a desktop window; the default is device.
        public var monitorChromeStyle: MonitorChromeStyle {
            get { self[MonitorChromeStyleKey.self] }
            set { self[MonitorChromeStyleKey.self] = newValue }
        }
    }

    extension View {
        /// Lays the live monitor out for a device screen or a desktop window.
        public func monitorChromeStyle(_ style: MonitorChromeStyle) -> some View {
            environment(\.monitorChromeStyle, style)
        }

        /// Runs the live monitor as a desktop window when `sink` is set: the desktop chrome, with
        /// Settings, Media, record, the display overlays and the take reaching the window's toolbar
        /// and keys through `sink`. Nil (not a desktop window) leaves the device layout.
        public func monitorDesktopCommands(_ sink: MonitorDesktopCommandSink?) -> some View {
            environment(\.monitorDesktopCommands, sink)
                .environment(\.monitorChromeStyle, sink == nil ? .device : .desktop)
        }
    }

    /// Where a desktop window's toolbar and keys reach the live monitor: the monitor registers its
    /// actions, its take and its look through these functions. A host passes its own methods of
    /// the same shape, so the monitor never names the host.
    public struct MonitorDesktopCommandSink {
        /// A monitor's actions and its take reader (recording nil while unknown); `owner` names the
        /// monitor, so one leaving the screen clears only its own registration.
        public typealias Register = @MainActor (
            _ owner: UUID, _ openSettings: (() -> Void)?, _ openMedia: (() -> Void)?,
            _ toggleRecord: (() -> Void)?, _ toggleOverlays: (() -> Void)?,
            _ readTake: (() -> (recording: Bool?, timecode: String?))?
        ) -> Void
        public typealias Unregister = @MainActor (_ owner: UUID) -> Void
        /// The accent, the font family ("<family>-SemiBold") and the Settings and Media glyphs.
        public typealias ApplyLook = @MainActor (
            _ accent: UIColor?, _ fontFamily: String?, _ settingsIcon: UIImage?, _ mediaIcon: UIImage?
        ) -> Void

        public let register: Register
        public let unregister: Unregister
        public let applyLook: ApplyLook

        public init(register: @escaping Register, unregister: @escaping Unregister, applyLook: @escaping ApplyLook) {
            self.register = register
            self.unregister = unregister
            self.applyLook = applyLook
        }

        /// Gives the toolbar the monitor's look: the accent, the font and the monitor's own
        /// Settings and Media glyphs (`media` is the film or the photo glyph).
        @MainActor public func applyMonitorLook(media: MonitorIcon) {
            MonitorTheme.prepareResources()
            let rgb = MonitorTheme.accentRGB
            let accent = UIColor(
                red: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
                blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
            applyLook(accent, MonitorTheme.fontFamily, Self.render(.settings), Self.render(media))
        }

        @MainActor private static func render(_ icon: MonitorIcon) -> UIImage? {
            let renderer = ImageRenderer(
                content: icon.frame(width: 17, height: 17).foregroundStyle(Color.white))
            renderer.scale = 2
            return renderer.uiImage?.withRenderingMode(.alwaysTemplate)
        }
    }

    private struct MonitorDesktopCommandsKey: EnvironmentKey {
        static var defaultValue: MonitorDesktopCommandSink? { nil }
    }

    extension EnvironmentValues {
        /// The desktop window's command sink, or nil on a device.
        public var monitorDesktopCommands: MonitorDesktopCommandSink? {
            get { self[MonitorDesktopCommandsKey.self] }
            set { self[MonitorDesktopCommandsKey.self] = newValue }
        }
    }
#endif
