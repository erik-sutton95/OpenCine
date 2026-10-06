#if os(iOS)
    import MonitorPresentation
    import MonitorUI
    import OpenCineAppKit
    import OpenCineCameraVocabulary
    import OpenCineMedia
    import SwiftUI
    import UIKit

    /// Reference monitor framing grid - `AssistConfiguration.Grid`, `FeedGridView`, and `AssistPanel` `.grid`.
    ///
    /// Long-press options are **Thirds**, **Phi Grid**, and **Diagonal**. The reference monitor has no fourths
    /// (or any other) composition grid.
    public enum GridAssist {
        /// Reference monitor `FeedGridView` thirds lines (`1/3`, `2/3`).
        public static let thirdsFractions: [CGFloat] = [1.0 / 3, 2.0 / 3]
        /// Reference monitor phi lines (`0.382`, `0.618` - 1 − 1/φ and 1/φ, as shipped).
        public static let phiFractions: [CGFloat] = [0.382, 0.618]
        /// Prototype stroke `rgba(255,255,255,.22)`, 1px.
        public static let strokeOpacity: Double = 0.22
        public static let strokeWidth: CGFloat = 1

        /// Reference monitor `AssistPanel` grid body - three `GridToggle` / `GlassChoice` chips.
        @MainActor
        public static func longPressMenu<Looks: MonitorLookProvider>(
            assist: MonitorAssistState<Looks>, haptics: OperatorHaptics
        ) -> some View {
            GridLongPressMenu(assist: assist, haptics: haptics)
        }

        /// Reference monitor `FeedGridView` overlay on the de-squeezed feed rect.
        @MainActor
        public static func overlay(feed: CGRect, thirds: Bool, phi: Bool, diagonal: Bool)
            -> some View
        {
            MonitorFeedGrid(feed: feed, thirds: thirds, phi: phi, diagonal: diagonal)
        }

        public static func segments(in feed: CGRect, thirds: Bool, phi: Bool, diagonal: Bool)
            -> [MonitorGridSegment]
        {
            MonitorGridGeometry.segments(in: feed, thirds: thirds, phi: phi, diagonal: diagonal)
        }
    }

    private struct GridLongPressMenu<Looks: MonitorLookProvider>: View {
        @Bindable public var assist: MonitorAssistState<Looks>
        public var haptics: OperatorHaptics

        public init(
            assist: MonitorAssistState<Looks>, haptics: OperatorHaptics
        ) {
            _assist = Bindable(wrappedValue: assist)
            self.haptics = haptics
        }

        public var body: some View {
            MonitorGridMenu(
                selected: Set(MonitorGridOption.allCases.filter(isOn)),
                feedback: {
                    haptics.selection()
                }
            ) { option in
                haptics.selection()
                toggle(option)
            }
        }

        private func isOn(_ option: MonitorGridOption) -> Bool {
            switch option {
            case .thirds: assist.gridThirds
            case .phi: assist.gridPhi
            case .diagonal: assist.gridDiagonal
            }
        }

        private func toggle(_ option: MonitorGridOption) {
            switch option {
            case .thirds: assist.gridThirds.toggle()
            case .phi: assist.gridPhi.toggle()
            case .diagonal: assist.gridDiagonal.toggle()
            }
            assist.persist()
        }

    }
#endif
