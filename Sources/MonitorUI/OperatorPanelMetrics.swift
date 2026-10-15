#if os(iOS)
    import MonitorPresentation
    import SwiftUI

    /// Full-screen operator panel paddings and safe areas (Settings, Media, Legal), shared by the
    /// apps' panel hosts.
    public enum OperatorPanelMetrics {
        public static let closeSize: CGFloat = 37
        public static let closeLeading: CGFloat = 16
        public static let topStackWidth: CGFloat = 560

        public static func topPadding(safeArea: EdgeInsets) -> CGFloat {
            max(safeArea.top + 6, 16)
        }

        /// The reference monitor's Settings top floor is 14, not the 16 that Media and Legal use.
        public static func settingsTopPadding(safeArea: EdgeInsets) -> CGFloat {
            max(safeArea.top + 6, 14)
        }

        public static func closeTopPadding(safeArea: EdgeInsets) -> CGFloat {
            max(safeArea.top + 6, 22)
        }

        public static func leadingPadding(safeArea: EdgeInsets, floor: CGFloat = 16) -> CGFloat {
            max(safeArea.leading + 6, floor)
        }

        public static func trailingPadding(safeArea: EdgeInsets) -> CGFloat {
            max(safeArea.trailing + 6, 16)
        }

        public static func bottomPadding(safeArea: EdgeInsets) -> CGFloat {
            max(safeArea.bottom + 4, 12)
        }

        /// Extra leading inset so a landscape title clears the floating close button.
        public static func closeButtonClearance(safeArea: EdgeInsets) -> CGFloat {
            max(0, (closeLeading + closeSize + 8) - leadingPadding(safeArea: safeArea))
        }

        /// The reference monitor's full-screen panel safe area.
        /// Landscape zeros the clean short edge so the surface hugs that bezel while clearing
        /// the Dynamic Island on the side it sits. Portrait passes the insets through.
        public static func fullScreenPanelSafeArea(
            from insets: EdgeInsets,
            isPortrait: Bool,
            mirrored: Bool
        ) -> EdgeInsets {
            guard !isPortrait else { return insets }
            return EdgeInsets(
                top: insets.top,
                leading: mirrored ? 0 : insets.leading,
                bottom: insets.bottom,
                trailing: mirrored ? insets.trailing : 0
            )
        }

        /// The reference monitor's standalone Operator Setup host.
        /// iOS reports the landscape island lane on both short edges; zero the smaller side.
        public static func standalonePanelSafeArea(from insets: EdgeInsets) -> EdgeInsets {
            let islandOnLeading = insets.leading >= insets.trailing
            return EdgeInsets(
                top: insets.top,
                leading: islandOnLeading ? insets.leading : 0,
                bottom: insets.bottom,
                trailing: islandOnLeading ? 0 : insets.trailing
            )
        }

        /// Merge the host's layout clearance with an observed physical window snapshot.
        /// Never query UIKit here: its getter can reenter SwiftUI layout on iOS 26.
        public static func resolvedDeviceSafeArea(
            _ proposed: EdgeInsets, window: EdgeInsets
        ) -> EdgeInsets {
            // A full-screen overlay may erase all SwiftUI safe insets. Resolve each
            // edge so portrait camera islands and home indicators receive the same
            // protection as the landscape camera cutout.
            return EdgeInsets(
                top: max(proposed.top, window.top),
                leading: max(proposed.leading, window.leading),
                bottom: max(proposed.bottom, window.bottom),
                trailing: max(proposed.trailing, window.trailing))
        }

        /// The reference monitor's camera pages (a host's pre page, cameras and pair): the same
        /// physical-window resolution as the cover, then landscape zeroes the clean short edge
        /// exactly like the cover page, so the surface hugs that bezel while clearing the island.
        public static func pageSafeArea(
            from insets: EdgeInsets,
            window: EdgeInsets,
            size: CGSize,
            orientation: MonitorDeviceOrientation? = nil
        ) -> EdgeInsets {
            let resolved = resolvedDeviceSafeArea(insets, window: window)
            guard size.width > size.height else { return resolved }
            return fullScreenPanelSafeArea(
                from: resolved, isPortrait: false,
                mirrored: LiveMonitorLayout.shouldMirror(
                    leading: resolved.leading, trailing: resolved.trailing, orientation: orientation))
        }
    }
#endif
