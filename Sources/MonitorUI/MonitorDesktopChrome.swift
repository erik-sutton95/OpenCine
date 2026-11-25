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

        /// Runs the live monitor as a desktop window when `target` is set: the desktop chrome, with
        /// Settings, Media, record, the display overlays and the take reaching the window's toolbar
        /// and keys through `target`. Nil (not a desktop window) leaves the device layout.
        public func monitorDesktopCommands(_ target: (any MonitorDesktopCommandTarget)?) -> some View {
            environment(\.monitorDesktopCommands, target)
                .environment(\.monitorChromeStyle, target == nil ? .device : .desktop)
        }
    }

    /// Where a desktop window's toolbar and keys reach the live monitor: the monitor registers its
    /// actions, its take and its look here. The host's own commands object conforms with these
    /// members, so the monitor never names the host.
    @MainActor
    public protocol MonitorDesktopCommandTarget: AnyObject {
        var openSettings: (() -> Void)? { get set }
        var openMedia: (() -> Void)? { get set }
        var toggleRecord: (() -> Void)? { get set }
        var toggleOverlays: (() -> Void)? { get set }
        /// Reads the take now: recording or standing by, and the timecode when the camera has one.
        var readTake: (() -> (recording: Bool, timecode: String?))? { get set }
        var accentColor: UIColor? { get set }
        /// The font family of the monitor's faces ("<family>-SemiBold").
        var fontFamily: String? { get set }
        var settingsIcon: UIImage? { get set }
        var mediaIcon: UIImage? { get set }
    }

    extension MonitorDesktopCommandTarget {
        /// Gives the toolbar the monitor's look: the accent, the font and the monitor's own
        /// Settings and Media glyphs (`media` is the film or the photo glyph).
        public func applyMonitorLook(media: MonitorIcon) {
            MonitorTheme.prepareResources()
            let rgb = MonitorTheme.accentRGB
            accentColor = UIColor(
                red: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
                blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
            fontFamily = MonitorTheme.fontFamily
            settingsIcon = Self.render(.settings)
            mediaIcon = Self.render(media)
        }

        private static func render(_ icon: MonitorIcon) -> UIImage? {
            let renderer = ImageRenderer(
                content: icon.frame(width: 17, height: 17).foregroundStyle(Color.white))
            renderer.scale = 2
            return renderer.uiImage?.withRenderingMode(.alwaysTemplate)
        }
    }

    private struct MonitorDesktopCommandsKey: EnvironmentKey {
        static var defaultValue: (any MonitorDesktopCommandTarget)? { nil }
    }

    extension EnvironmentValues {
        /// The desktop window's command target, or nil on a device.
        public var monitorDesktopCommands: (any MonitorDesktopCommandTarget)? {
            get { self[MonitorDesktopCommandsKey.self] }
            set { self[MonitorDesktopCommandsKey.self] = newValue }
        }
    }
#endif
