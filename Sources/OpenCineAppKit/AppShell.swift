#if os(iOS)
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
        public var privacy: (() -> Void)?
        public var terms: (() -> Void)?
        /// Camera id, integration action id (`RecoveryAction.integration`).
        public var integrationAction: ((String, String) -> Void)?

        public init(
            diagnostics: @escaping () -> Void, reportProblem: @escaping () -> Void,
            watchFeed: (() -> Void)? = nil, multiview: (() -> Void)? = nil,
            integrationAction: ((String, String) -> Void)? = nil,
            privacy: (() -> Void)? = nil, terms: (() -> Void)? = nil
        ) {
            self.diagnostics = diagnostics
            self.reportProblem = reportProblem
            self.watchFeed = watchFeed
            self.multiview = multiview
            self.integrationAction = integrationAction
            self.privacy = privacy
            self.terms = terms
        }
    }

    /// The shared root over `ShellModel`: the cameras or pair page, or the monitor, plus the
    /// cover pages. The monitor slot is keyed by `ShellModel.Monitor.id`, so one host lives for one
    /// monitor lifetime: covers, rotations and recomposition never create a second one.
    ///
    /// Temporary (SHELL-03 I-1): `monitor` is the app's existing native monitor, which presents
    /// `model.cover` over itself while it still owns placement; `page` draws the cover pages
    /// over the cameras and pair pages.
    public struct AppShell<Monitor: View, Page: View>: View {
        @Bindable var model: ShellModel
        let brand: ShellBrand
        let actions: ShellActions
        let safeArea: (GeometryProxy) -> EdgeInsets
        let monitor: (ShellModel.Monitor) -> Monitor
        let page: (ShellModel.Cover) -> Page

        /// `safeArea` turns the pages' geometry into the insets they lay out in.
        public init(
            model: ShellModel, brand: ShellBrand, actions: ShellActions,
            safeArea: @escaping (GeometryProxy) -> EdgeInsets = { $0.safeAreaInsets },
            @ViewBuilder monitor: @escaping (ShellModel.Monitor) -> Monitor,
            @ViewBuilder page: @escaping (ShellModel.Cover) -> Page
        ) {
            self.model = model
            self.brand = brand
            self.actions = actions
            self.safeArea = safeArea
            self.monitor = monitor
            self.page = page
        }

        public var body: some View {
            if let live = model.monitor {
                monitor(live)
                    .id(live.id)
                    .onAppear { model.noteHost(mounted: true) }
                    .onDisappear { model.noteHost(mounted: false) }
            } else {
                GeometryReader { proxy in pages(safeArea(proxy)) }
                    .ignoresSafeArea()
                    .overlay {
                        if let cover = model.cover { page(cover) }
                    }
            }
        }

        @ViewBuilder private func pages(_ insets: EdgeInsets) -> some View {
            if model.route == .pair {
                PairScreen(
                    model: model.cameras, safeArea: insets, onDone: { model.endPairing() },
                    onDiagnostics: actions.diagnostics, onReportProblem: actions.reportProblem,
                    onWatchFeed: actions.watchFeed, onPrivacy: actions.privacy,
                    onTerms: actions.terms)
            } else {
                CamerasScreen(
                    model: model.cameras, brandName: brand.name, nearbyNote: brand.nearbyNote,
                    safeArea: insets, onPair: { model.beginPairing() },
                    onMedia: { model.open(.media) }, onSettings: { model.open(.settings) },
                    onMultiview: actions.multiview, onWatchFeed: actions.watchFeed,
                    onIntegrationAction: actions.integrationAction, onPrivacy: actions.privacy,
                    onTerms: actions.terms)
            }
        }
    }
#endif
