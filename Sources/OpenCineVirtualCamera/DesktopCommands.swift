#if targetEnvironment(macCatalyst)
    import Foundation
    import Observation
    import OpenCineDesktopKit
    import UIKit

    /// What the module window's toolbar and keys run. The app's live monitor registers its
    /// actions and its take here (`register`), and its look (`applyLook`); the toolbar shows an
    /// item without a registered action disabled. The methods take plain values only, so an app
    /// hands them to a monitor that cannot name this type as closures.
    @available(macCatalyst 17.0, *)
    @MainActor @Observable
    public final class DesktopCommands {
        /// One monitor's actions.
        struct Actions {
            var openSettings: (() -> Void)?
            var openMedia: (() -> Void)?
            var toggleRecord: (() -> Void)?
            var toggleOverlays: (() -> Void)?
            var readTake: (() -> (recording: Bool?, timecode: String?))?
        }

        private var registry = DesktopRegistry<Actions>()
        /// The camera's accent colour.
        public private(set) var accentColor: UIColor?
        /// The monitor's font family, such as "Sora" for faces named "Sora-SemiBold".
        public private(set) var fontFamily: String?
        /// The monitor's own glyphs for the toolbar buttons (template images).
        public private(set) var settingsIcon: UIImage?
        public private(set) var mediaIcon: UIImage?

        public init() {}

        public var openSettings: (() -> Void)? { registry.current?.openSettings }
        public var openMedia: (() -> Void)? { registry.current?.openMedia }
        public var toggleRecord: (() -> Void)? { registry.current?.toggleRecord }
        public var toggleOverlays: (() -> Void)? { registry.current?.toggleOverlays }
        /// Reads the take now (recording nil while unknown): the toolbar calls it as its timecode
        /// advances.
        public var readTake: (() -> (recording: Bool?, timecode: String?))? { registry.current?.readTake }

        /// A monitor's actions and take. The latest registration wins.
        public func register(
            owner: UUID, openSettings: (() -> Void)?, openMedia: (() -> Void)?,
            toggleRecord: (() -> Void)?, toggleOverlays: (() -> Void)?,
            readTake: (() -> (recording: Bool?, timecode: String?))?
        ) {
            registry.register(
                Actions(
                    openSettings: openSettings, openMedia: openMedia, toggleRecord: toggleRecord,
                    toggleOverlays: toggleOverlays, readTake: readTake),
                owner: DesktopRegistry<Actions>.Owner(owner))
        }

        /// A monitor leaving the screen; a newer monitor's registration stays.
        public func unregister(owner: UUID) {
            registry.unregister(owner: DesktopRegistry<Actions>.Owner(owner))
        }

        /// The monitor's look for the toolbar.
        public func applyLook(
            accentColor: UIColor?, fontFamily: String?, settingsIcon: UIImage?, mediaIcon: UIImage?
        ) {
            self.accentColor = accentColor
            self.fontFamily = fontFamily
            self.settingsIcon = settingsIcon
            self.mediaIcon = mediaIcon
        }

        /// The take as the toolbar shows it; unknown while no monitor is registered.
        public var take: DesktopTake {
            guard let state = readTake?() else { return .unknown(timecode: nil) }
            return DesktopTake(recording: state.recording, timecode: state.timecode)
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
