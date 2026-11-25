import MonitorPresentation

#if os(iOS) && !targetEnvironment(macCatalyst)
    import UIKit
#endif

// Not iOS-only like the rest of MonitorUI: the app shell's macOS build reads it too.
extension MonitorHostDevice {
    /// This process's device: a Mac (Catalyst or macOS), else an iPad or iPhone by idiom. Layout
    /// asks `HostDevice.current.isLargeScreen` (`MonitorHostDevice` in the native views), never
    /// the idiom itself: optimized for Mac the idiom is `.mac`, and the Mac keeps the iPad layout.
    @MainActor public static var current: MonitorHostDevice {
        #if targetEnvironment(macCatalyst) || os(macOS)
            return .mac
        #elseif os(iOS)
            return UIDevice.current.userInterfaceIdiom == .pad ? .iPad : .iPhone
        #else
            return .iPhone
        #endif
    }
}
