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

    /// Working per-member services supplied by the host. Absence preserves legacy stage behavior;
    /// an explicit empty availability offers no executable camera or LUT tool.
    public struct MultiviewStageServices: Sendable {
        public let availability: MultiviewToolAvailability
        public let configureLUT: (@MainActor @Sendable (Int) -> Void)?
        /// The host derives each member's look from its reported source (Auto LUT) rather than
        /// from an operator selection. It names the group LUT toggle; it grants no capability.
        public let automaticLUT: Bool
        public init(availability: MultiviewToolAvailability,
            configureLUT: (@MainActor @Sendable (Int) -> Void)? = nil, automaticLUT: Bool = false) {
            self.availability = availability
            self.configureLUT = configureLUT
            self.automaticLUT = automaticLUT
        }
    }

    private struct MultiviewStageServicesKey: EnvironmentKey {
        static let defaultValue: MultiviewStageServices? = nil
    }

    private struct MultiviewStageVisibleKey: EnvironmentKey {
        static let defaultValue = true
    }

    private struct MultiviewStageStateKey: EnvironmentKey {
        static let defaultValue: MultiviewStageState? = nil
    }

    extension EnvironmentValues {
        var multiviewStageServices: MultiviewStageServices? {
            get { self[MultiviewStageServicesKey.self] }
            set { self[MultiviewStageServicesKey.self] = newValue }
        }

        var multiviewStageVisible: Bool {
            get { self[MultiviewStageVisibleKey.self] }
            set { self[MultiviewStageVisibleKey.self] = newValue }
        }

        var multiviewStageState: MultiviewStageState? {
            get { self[MultiviewStageStateKey.self] }
            set { self[MultiviewStageStateKey.self] = newValue }
        }
    }

    extension View {
        /// Additive capability-derived scope; existing initializer and action forms remain callable.
        public func multiviewStageServices(_ services: MultiviewStageServices) -> some View {
            environment(\.multiviewStageServices, services)
        }

        /// Retains the native picture owner while retiring approvals and editors under a cover.
        public func multiviewStageVisible(_ visible: Bool) -> some View {
            environment(\.multiviewStageVisible, visible)
        }

        /// Additive composition scope: existing stage initializers keep their callable shape.
        public func multiviewStageState(_ state: MultiviewStageState) -> some View {
            environment(\.multiviewStageState, state)
        }
    }
#endif
