#if targetEnvironment(macCatalyst)
    import Foundation
    import Observation
    import OpenCineDesktopKit
    import UIKit

    /// What the module window's toolbar and keys run. The app's live monitor registers its
    /// actions and its take here, and its look (accent, font, icons); the toolbar shows an item
    /// without a registered action disabled. Every member is a plain value, so a monitor that
    /// cannot name this type reaches it through a protocol of the same members.
    @available(macCatalyst 17.0, *)
    @MainActor @Observable
    public final class DesktopCommands {
        public var openSettings: (() -> Void)?
        public var openMedia: (() -> Void)?
        public var toggleRecord: (() -> Void)?
        public var toggleOverlays: (() -> Void)?
        /// Reads the take now: the toolbar calls it as its timecode advances.
        public var readTake: (() -> (recording: Bool, timecode: String?))?
        /// The camera's accent colour.
        public var accentColor: UIColor?
        /// The monitor's font family, such as "Sora" for faces named "Sora-SemiBold".
        public var fontFamily: String?
        /// The monitor's own glyphs for the toolbar buttons (template images).
        public var settingsIcon: UIImage?
        public var mediaIcon: UIImage?

        public init() {}

        /// The take as the toolbar shows it; standing by while no monitor is registered.
        public var take: DesktopTake {
            guard let state = readTake?() else { return .standby(timecode: nil) }
            return state.recording ? .recording(timecode: state.timecode) : .standby(timecode: state.timecode)
        }

        /// Runs a key's action. Tab actions belong to the dock and are not handled here.
        @discardableResult func perform(_ shortcut: DesktopShortcut) -> Bool {
            let action: (() -> Void)?
            switch shortcut {
            case .record: action = toggleRecord
            case .settings: action = openSettings
            case .media: action = openMedia
            case .overlays: action = toggleOverlays
            case .tab, .nextTab, .previousTab: action = nil
            }
            guard let action else { return false }
            action()
            return true
        }
    }
#endif
