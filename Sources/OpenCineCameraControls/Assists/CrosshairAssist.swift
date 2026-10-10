#if os(iOS)
    import MonitorPresentation
    import MonitorUI
    import OpenCineAppKit
    import OpenCineCameraVocabulary
    import OpenCineMedia
    import SwiftUI
    import UIKit

    /// Reference monitor centre crosshair - tap toggles; long-press has no style / color / centre-mark
    /// controls (`AssistPanel` `.crosshair`, Android `AssistTool.CROSS`).
    ///
    /// Overlay is the reference monitor's `FeedCrosshairView` / Android `drawCentreCrosshair`: a 40pt cross,
    /// 1.4pt stroke, white at 65% opacity, centred on the feed. The iOS comment about a 46pt
    /// ring plus 34pt cross is leftover prototype copy - neither platform draws a ring or a
    /// centre mark, and `AssistConfiguration` has no crosshair fields.
    public enum CrosshairAssist {
        /// Reference monitor `AssistPanel` / Android `OptionCopy` for CROSS.
        public static let helpCopy = "Tap the toolbar button to show or hide the centre crosshair."

        /// Full arm length in points (Android `20.dp` each side).
        public static let armLength: CGFloat = 40
        public static let strokeWidth: CGFloat = 1.4
        public static let opacity: Double = 0.65

        /// Reference monitor `AssistPanel` `.crosshair` body - help copy only.
        @MainActor
        public static func longPressMenu<Looks: MonitorLookProvider>(
            assist _: MonitorAssistState<Looks>,
            compact: Bool = false
        ) -> CrosshairLongPressMenu {
            CrosshairLongPressMenu(compact: compact)
        }

        /// Reference monitor `FeedCrosshairView` - two 40×1.4 rectangles, white 65%, feed centre.
        @MainActor
        public static func overlay(feed: CGRect) -> MonitorFeedCrosshair {
            MonitorFeedCrosshair(feed: feed)
        }
    }

    /// Reference monitor `AssistPanel` CROSS copy: 13pt muted. Android `OptionCopy` is 11pt in the
    /// compact settings strip - `compact` follows that.
    public struct CrosshairLongPressMenu: View {
        public var compact: Bool = false

        public init(
            compact: Bool = false
        ) {
            self.compact = compact
        }

        public var body: some View { MonitorAssistHelp(CrosshairAssist.helpCopy, compact: compact) }
    }
#endif
