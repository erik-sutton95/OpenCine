#if os(iOS)
    import MonitorPresentation
    import MonitorUI
    import OpenCineAppKit
    import OpenCineCameraVocabulary
    import OpenCineMedia
    import SwiftUI
    import UIKit

    /// Reference monitor `MonitorAssistTool.mirror`, plus a vertical axis.
    ///
    /// Tap toggles the tool. Long-press options pick the axes: Horizontal (a body pointed
    /// back at the operator) and Vertical (an underslung camera). Both on is a 180° turn.
    public enum MirrorAssist {
        public static let explanation =
            "Flips the monitor for a camera pointed back at you or mounted upside down. "
            + "The recording and the scopes are never mirrored."
        public static let horizontalHelp = "Left-to-right, for a camera pointed back at you."
        public static let verticalHelp =
            "Top-to-bottom, for an underslung mount. Both on turns it 180°."

        /// Reference monitor `LiveFrameRaster.feedScale`: negative X for Horizontal, negative Y for Vertical.
        public static func feedScale(
            mirrored: Bool,
            flippedVertically: Bool = false,
            squeeze: CGSize = CGSize(width: 1, height: 1)
        ) -> CGSize {
            CGSize(
                width: mirrored ? -squeeze.width : squeeze.width,
                height: flippedVertically ? -squeeze.height : squeeze.height)
        }

        @MainActor
        public static func longPressMenu<Looks: MonitorLookProvider>(
            assist: MonitorAssistState<Looks>, haptics: OperatorHaptics
        ) -> MirrorLongPressMenu<Looks> {
            MirrorLongPressMenu(assist: assist, haptics: haptics)
        }
    }

    /// Grid-style axis switches under the MIRROR help copy.
    public struct MirrorLongPressMenu<Looks: MonitorLookProvider>: View {
        @Bindable public var assist: MonitorAssistState<Looks>
        public var haptics: OperatorHaptics

        public init(
            assist: MonitorAssistState<Looks>, haptics: OperatorHaptics
        ) {
            _assist = Bindable(wrappedValue: assist)
            self.haptics = haptics
        }

        public var body: some View {
            MonitorMirrorMenu(
                horizontal: Binding(
                    get: { assist.mirrorHorizontal },
                    set: {
                        assist.mirrorHorizontal = $0
                        assist.persist()
                    }),
                vertical: Binding(
                    get: { assist.mirrorVertical },
                    set: {
                        assist.mirrorVertical = $0
                        assist.persist()
                    }), explanation: MirrorAssist.explanation,
                horizontalHelp: MirrorAssist.horizontalHelp,
                verticalHelp: MirrorAssist.verticalHelp,
                feedback: {
                    haptics.selection()
                })
        }
    }
#endif
