#if os(iOS)
    import MonitorUI
    import SwiftUI

    /// The live chrome's ink, from each app's own palette (its accent and HDR chrome gain). Shared
    /// views read it in their own body, as the app's views do.
    public protocol LiveChromePalette {
        static var background: Color { get }
        static var glassBright: Color { get }
        static var hairline: Color { get }
        static var hairlineStrong: Color { get }
        static var text: Color { get }
        static var muted: Color { get }
        static var accent: Color { get }
        /// The accent's faint fill behind a selected row.
        static var accentDim: Color { get }
        /// Ink on a solid accent fill.
        static var onAccent: Color { get }
        static var rec: Color { get }
        /// Destructive actions and errors.
        static var destructive: Color { get }
        static var amber: Color { get }
        /// AE lock yellow: the focus box, its `AE-L` tag and the unlock key.
        static var aeLock: Color { get }
        static var good: Color { get }
        static var cornerRadius: CGFloat { get }
        /// A chrome colour at the display's current HDR gain, like the named ones.
        static func chromeColor(red: CGFloat, green: CGFloat, blue: CGFloat) -> Color
    }

    extension View {
        /// The live chrome's glass: the monitor glass, always dark (the apps' `liveChromeGlass`).
        func liveChromeGlass(in shape: some Shape) -> some View {
            monitorGlass(in: shape)
                .environment(\.colorScheme, .dark)
        }
    }
#endif
