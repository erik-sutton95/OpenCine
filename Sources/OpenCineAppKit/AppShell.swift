#if os(iOS)
    import MonitorPresentation
    import MonitorUI
    import OpenCineCore
    import SwiftUI

    /// What the shared root shows of the app's brand. Values only.
    public struct ShellBrand: Sendable {
        public var name: String
        /// How nearby cameras are found, under NEARBY ("announcing over Bluetooth").
        public var nearbyNote: String

        public init(name: String, nearbyNote: String = "announcing over Bluetooth") {
            self.name = name
            self.nearbyNote = nearbyNote
        }
    }

    /// The app's own actions the shared pages offer. `nil` hides an entry.
    public struct ShellActions {
        public var diagnostics: () -> Void
        public var reportProblem: () -> Void
        public var watchFeed: (() -> Void)?
        public var multiview: (() -> Void)?
        /// Camera id, integration action id (`RecoveryAction.integration`).
        public var integrationAction: ((String, String) -> Void)?
        /// The cameras page's Pair, Media and Settings; `nil` opens the shell's pair page or cover.
        public var pair: (() -> Void)?
        public var media: (() -> Void)?
        public var settings: (() -> Void)?
        /// A tap on one of the app's own NEARBY rows (`AppShell`'s `extraNearby`), by its id.
        public var extraNearby: ((String) -> Void)?

        public init(
            diagnostics: @escaping () -> Void, reportProblem: @escaping () -> Void,
            watchFeed: (() -> Void)? = nil, multiview: (() -> Void)? = nil,
            integrationAction: ((String, String) -> Void)? = nil,
            pair: (() -> Void)? = nil, media: (() -> Void)? = nil, settings: (() -> Void)? = nil,
            extraNearby: ((String) -> Void)? = nil
        ) {
            self.diagnostics = diagnostics
            self.reportProblem = reportProblem
            self.watchFeed = watchFeed
            self.multiview = multiview
            self.integrationAction = integrationAction
            self.pair = pair
            self.media = media
            self.settings = settings
            self.extraNearby = extraNearby
        }
    }

    /// Existing hosts can keep presenting their own covers during migration. Complete shared
    /// hosts select `shell`, which retains the monitor beneath one sibling cover page.
    public enum ShellCoverPresentation: Equatable, Sendable {
        case monitor
        case shell
    }

    /// One keyed monitor beneath camera pages and covers. Layout changes preserve its owner.
    public struct AppShell<Monitor: View, Page: View, PrePage: View>: View {
        @Bindable var model: ShellModel
        let brand: ShellBrand
        let actions: ShellActions
        let safeArea: ((GeometryProxy) -> EdgeInsets)?
        @Environment(\.monitorWindowGeometry) private var windowGeometry
        @State private var pageOrientation = InterfaceOrientationObserver()
        let extraNearby: [CameraListItem]
        let pairingFlow: IntegrationPairingFlow?
        let prePage: (EdgeInsets) -> PrePage?
        let monitor: (ShellModel.Monitor) -> Monitor
        let page: (ShellModel.Cover) -> Page
        let coverPresentation: ShellCoverPresentation

        /// Pages clear the physical window's safe areas by default. `safeArea` can override
        /// that policy for a host's custom layout. `extraNearby`:
        /// the app's own NEARBY rows on the cameras page. `pairingFlow`: the app's own rail and
        /// actions on the pair page (`PairScreen.pairingFlow`). `prePage`: the app's own page before
        /// the shared ones (a first-pair wizard, a connect in progress), shown instead of the
        /// cameras or pair page while it returns one.
        public init(
            model: ShellModel, brand: ShellBrand, actions: ShellActions,
            safeArea: ((GeometryProxy) -> EdgeInsets)? = nil,
            extraNearby: [CameraListItem] = [], pairingFlow: IntegrationPairingFlow? = nil,
            coverPresentation: ShellCoverPresentation = .monitor,
            prePage: @escaping (EdgeInsets) -> PrePage?,
            @ViewBuilder monitor: @escaping (ShellModel.Monitor) -> Monitor,
            @ViewBuilder page: @escaping (ShellModel.Cover) -> Page
        ) {
            self.model = model
            self.brand = brand
            self.actions = actions
            self.safeArea = safeArea
            self.extraNearby = extraNearby
            self.pairingFlow = pairingFlow
            self.prePage = prePage
            self.monitor = monitor
            self.page = page
            self.coverPresentation = coverPresentation
        }

        public var body: some View {
            ZStack {
                if let live = model.monitor {
                    monitor(live)
                        .id(live.id)
                        .monitorPresentationVisibility(!hidesMonitor)
                        .onAppear { model.noteHost(mounted: true) }
                        .onDisappear { model.noteHost(mounted: false) }
                } else {
                    GeometryReader { proxy in
                        pages(
                            safeArea?(proxy)
                                ?? OperatorPanelMetrics.pageSafeArea(
                                    from: proxy.safeAreaInsets, window: windowGeometry.safeArea,
                                    size: proxy.size, orientation: pageOrientation.orientation))
                    }
                        .ignoresSafeArea()
                        .accessibilityElement(children: model.cover == nil ? .contain : .ignore)
                        .accessibilityHidden(model.cover != nil)
                        .onAppear { pageOrientation.start() }
                        .onDisappear { pageOrientation.stop() }
                }
                if let cover = model.cover, model.monitor == nil || coverPresentation == .shell {
                    page(cover)
                }
            }
            .operatorConsentPresenter(model.cameras.consent)
        }

        private var hidesMonitor: Bool { coverPresentation == .shell && model.cover != nil }

        @ViewBuilder private func pages(_ insets: EdgeInsets) -> some View {
            if let lead = prePage(insets) {
                lead
            } else if model.route == .pair {
                PairScreen(
                    model: model.cameras, safeArea: insets, onDone: { model.endPairing() },
                    onDiagnostics: actions.diagnostics, onReportProblem: actions.reportProblem,
                    onWatchFeed: actions.watchFeed, pairingFlow: pairingFlow)
            } else {
                CamerasScreen(
                    model: model.cameras, brandName: brand.name, nearbyNote: brand.nearbyNote,
                    safeArea: insets, onPair: actions.pair ?? { model.beginPairing() },
                    onMedia: actions.media ?? { model.open(.media) },
                    onSettings: actions.settings ?? { model.open(.settings) },
                    onMultiview: actions.multiview, onWatchFeed: actions.watchFeed,
                    onIntegrationAction: actions.integrationAction,
                    extraNearby: extraNearby, onExtraNearby: actions.extraNearby ?? { _ in })
            }
        }
    }

    extension AppShell where PrePage == EmptyView {
        /// Without pages of the app's own.
        public init(
            model: ShellModel, brand: ShellBrand, actions: ShellActions,
            safeArea: ((GeometryProxy) -> EdgeInsets)? = nil,
            pairingFlow: IntegrationPairingFlow? = nil,
            coverPresentation: ShellCoverPresentation = .monitor,
            @ViewBuilder monitor: @escaping (ShellModel.Monitor) -> Monitor,
            @ViewBuilder page: @escaping (ShellModel.Cover) -> Page
        ) {
            self.init(
                model: model, brand: brand, actions: actions, safeArea: safeArea, pairingFlow: pairingFlow,
                coverPresentation: coverPresentation,
                prePage: { _ in nil }, monitor: monitor, page: page)
        }
    }

    /// Physical layout of an operator cover, independent of the source's native picture.
    /// The same owner serves a live monitor and an offline camera page.
    public struct MonitorCoverPage<Content: View>: View {
        private let content: (EdgeInsets) -> Content
        @Environment(\.monitorWindowGeometry) private var windowGeometry
        @State private var orientation = InterfaceOrientationObserver()

        public init(@ViewBuilder content: @escaping (EdgeInsets) -> Content) { self.content = content }

        public var body: some View {
            GeometryReader { proxy in
                let raw = OperatorPanelMetrics.resolvedDeviceSafeArea(
                    proxy.safeAreaInsets, window: windowGeometry.safeArea)
                let safe = OperatorPanelMetrics.fullScreenPanelSafeArea(from: raw,
                    isPortrait: proxy.size.height > proxy.size.width,
                    mirrored: LiveMonitorLayout.shouldMirror(leading: raw.leading,
                        trailing: raw.trailing, orientation: orientation.orientation))
                content(safe).frame(width: proxy.size.width, height: proxy.size.height)
            }
            .ignoresSafeArea()
            .accessibilityElement(children: .contain)
            .onAppear { orientation.start() }
            .onDisappear { orientation.stop() }
        }
    }
#endif
