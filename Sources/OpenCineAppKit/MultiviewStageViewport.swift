#if os(iOS)
    import MonitorPresentation
    import MonitorUI
    import SwiftUI

    /// Native window facts resolved once for the stage, its backdrop and its popups.
    public struct MultiviewStageViewport {
        public let size: CGSize
        public let safeArea: EdgeInsets
        public let layout: MultiviewPresentationLayout

        public init(
            size: CGSize, reportedSafeArea: EdgeInsets, window: MonitorWindowGeometry,
            orientation: MonitorDeviceOrientation,
            arrangement: MultiviewPresentationLayout.Arrangement,
            selected: Int
        ) {
            self.size = size
            safeArea = OperatorPanelMetrics.pageSafeArea(
                from: reportedSafeArea, window: window.safeArea, size: size,
                orientation: orientation)
            layout = MultiviewPresentationLayout(
                width: size.width, height: size.height,
                safeArea: .init(
                    top: safeArea.top, leading: safeArea.leading,
                    bottom: safeArea.bottom, trailing: safeArea.trailing),
                arrangement: arrangement, selected: selected,
                topControlInset: window.topControlInset)
        }
    }

    /// Owns the physical window and orientation policy shared by every stage composition.
    public struct MultiviewStageSurface<Content: View>: View {
        private let arrangement: MultiviewPresentationLayout.Arrangement
        private let selected: Int
        private let content: (MultiviewStageViewport) -> Content
        @Environment(\.monitorWindowGeometry) private var window
        @State private var orientation = InterfaceOrientationObserver()

        public init(
            arrangement: MultiviewPresentationLayout.Arrangement, selected: Int,
            @ViewBuilder content: @escaping (MultiviewStageViewport) -> Content
        ) {
            self.arrangement = arrangement
            self.selected = selected
            self.content = content
        }

        public var body: some View {
            GeometryReader { proxy in
                content(
                    MultiviewStageViewport(
                        size: proxy.size, reportedSafeArea: proxy.safeAreaInsets, window: window,
                        orientation: orientation.orientation, arrangement: arrangement,
                        selected: selected))
            }
            .ignoresSafeArea(.container)
            .onAppear { orientation.start() }
            .onDisappear { orientation.stop() }
        }
    }

    private struct MultiviewStageStateKey: EnvironmentKey {
        static let defaultValue: MultiviewStageState? = nil
    }

    extension EnvironmentValues {
        var multiviewStageState: MultiviewStageState? {
            get { self[MultiviewStageStateKey.self] }
            set { self[MultiviewStageStateKey.self] = newValue }
        }
    }

    extension View {
        /// Additive composition scope: existing stage initializers keep their callable shape.
        public func multiviewStageState(_ state: MultiviewStageState) -> some View {
            environment(\.multiviewStageState, state)
        }
    }
#endif
