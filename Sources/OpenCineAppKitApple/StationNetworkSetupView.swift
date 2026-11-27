#if os(iOS)
    import MonitorUI
    import OpenCineAppKit
    import OpenCineApple
    import OpenCineCore
    import SwiftUI
    import UIKit

    /// What the station-network wizard asks of the app: its saved networks, this phone's network
    /// and hotspot state, and whether the camera accepts a join.
    public struct StationNetworkServices {
        /// Networks this app saved with their passwords, oldest first.
        public var savedNetworks: @MainActor () -> [StationNetwork]
        /// This phone's current Wi-Fi name, nil when iOS withholds it.
        public var currentSSID: @MainActor () async -> String?
        /// This phone's Personal Hotspot is up.
        public var hotspotActive: @MainActor () -> Bool
        /// The camera's join command accepts this network name and password.
        public var acceptsJoin: @MainActor (String, String) -> Bool
        /// Whether a network needs a password, nil when unknown. Nil uses this phone's current
        /// network (`StationNetworkSecurity.currentNetwork(named:)`), as every app does.
        public var networkSecured: (@MainActor (String) async -> Bool?)?

        public init(
            savedNetworks: @escaping @MainActor () -> [StationNetwork],
            currentSSID: @escaping @MainActor () async -> String?,
            hotspotActive: @escaping @MainActor () -> Bool,
            acceptsJoin: @escaping @MainActor (String, String) -> Bool,
            networkSecured: (@MainActor (String) async -> Bool?)? = nil
        ) {
            self.savedNetworks = savedNetworks
            self.currentSSID = currentSSID
            self.hotspotActive = hotspotActive
            self.acceptsJoin = acceptsJoin
            self.networkSecured = networkSecured
        }
    }

    /// One Wi-Fi / hotspot wizard for saved-camera setups and the Multiview session.
    /// Callers supply scanning and connection ownership; this view owns drafts and navigation.
    public struct StationNetworkSetupView: View {
        public typealias Context = StationNetworkSetupContext
        /// One landscape column; nil lays the whole page out in one column.
        enum Side { case leading, trailing }
        public enum Page: Hashable {
            case choose, networks, hotspot
            case password(String)
        }

        let context: Context
        let brand: StationNetworkBrand
        let services: StationNetworkServices
        var cameraSSIDs: Set<String> = []
        /// Nil when the camera is not nearby over Bluetooth. Reports each network as it arrives.
        var scan: (@MainActor (@escaping @MainActor (String) -> Void) async throws -> Void)?
        /// False for a camera that cannot list networks at all: Nearby says so instead of asking
        /// for the camera to be turned on.
        var cameraScansNetworks = true
        /// Saves the confirmed network as this route kind; true closes the wizard.
        var save: @MainActor (StationNetwork) async -> Bool
        var errorMessage: String? = nil
        var close: () -> Void
        /// The network cameras are using. When set, the view shows only the read-only Shared Wi-Fi
        /// page and never scans.
        var lockedNetwork: StationNetwork?
        /// The locked page's Done: the network stays confirmed (never `close`, which may cancel).
        /// Kotlin: the wizard's `complete`.
        var complete: () -> Void
        @State var path: [Page] = []

        public init(
            context: Context, brand: StationNetworkBrand, services: StationNetworkServices,
            cameraSSIDs: Set<String> = [],
            scan: (@MainActor (@escaping @MainActor (String) -> Void) async throws -> Void)?,
            cameraScansNetworks: Bool = true,
            save: @escaping @MainActor (StationNetwork) async -> Bool, errorMessage: String? = nil,
            close: @escaping () -> Void, path: [Page] = [], lockedNetwork: StationNetwork? = nil,
            complete: @escaping () -> Void
        ) {
            self.init(
                host: .current, context: context, brand: brand, services: services,
                cameraSSIDs: cameraSSIDs, scan: scan, cameraScansNetworks: cameraScansNetworks,
                save: save, errorMessage: errorMessage, close: close, path: path,
                lockedNetwork: lockedNetwork, complete: complete)
        }

        /// `host` is the device the page is for (tests lay a computer's page out on any device).
        init(
            host: HostDevice, context: Context, brand: StationNetworkBrand,
            services: StationNetworkServices, cameraSSIDs: Set<String> = [],
            scan: (@MainActor (@escaping @MainActor (String) -> Void) async throws -> Void)?,
            cameraScansNetworks: Bool = true,
            save: @escaping @MainActor (StationNetwork) async -> Bool, errorMessage: String? = nil,
            close: @escaping () -> Void, path: [Page] = [], lockedNetwork: StationNetwork? = nil,
            complete: @escaping () -> Void
        ) {
            self.host = host
            self.context = context
            self.brand = brand
            self.services = services
            self.cameraSSIDs = cameraSSIDs
            self.scan = scan
            self.cameraScansNetworks = cameraScansNetworks
            self.save = save
            self.errorMessage = errorMessage
            self.close = close
            self.lockedNetwork = lockedNetwork
            self.complete = complete
            _path = State(initialValue: Self.startPath(path, root: Self.root(host)))
            _computerScanning = State(initialValue: host.isComputer && scan == nil)
        }

        /// The pages pushed over the root at open. A caller asking for the root page itself (Add
        /// setup's Wi-Fi on a computer, whose root is the network list) gets it once, so Back
        /// never shows the same page again.
        static func startPath(_ path: [Page], root: Page) -> [Page] {
            path.first == root ? Array(path.dropFirst()) : path
        }

        /// A computer opens on the network list: it offers no camera Wi-Fi or hotspot
        /// (`StationSetupRoute.offered`), and the network is one it is on.
        static func root(_ host: HostDevice) -> Page { host.isComputer ? .networks : .choose }

        @State private var working = false
        /// The password page's network and its security (nil: unknown).
        @State private var security: (ssid: String, secured: Bool?)?
        @State private var currentSSID: String?
        @State private var configured: [String] = []
        @State private var found: [String] = []
        @State private var scanTask: Task<Void, Never>?
        @State private var scanning = false
        @State private var scanFinished = false
        @State private var scanFailed = false
        @State private var otherNetwork = false
        @State private var otherName = ""
        @State private var password = ""
        @State private var hotspotName = ""
        @State private var hotspotPassword = ""
        @State private var hotspotNameTouched = false
        @State private var reveal = false
        @State private var hotspotActive = false
        @State private var locationHint: String?
        @State private var locationDenied = false
        /// The networks a computer sees itself, when no camera scans for it.
        @State private var computerNearby: [String] = []
        @State private var computerScanning = false
        @Environment(\.openURL) private var openURL
        @Environment(\.scenePhase) private var scenePhase
        @Environment(\.monitorWindowGeometry) private var windowGeometry

        /// The dark sheet colour portrait shows (elevated system background). Pinned so the
        /// full-screen landscape sheet, which drops to the base level, keeps the same page.
        private static let pageBackground = Color(
            uiColor: .systemBackground.resolvedColor(
                with: UITraitCollection {
                    $0.userInterfaceStyle = .dark
                    $0.userInterfaceLevel = .elevated
                }))

        /// The device the words name.
        let host: HostDevice
        private var mac: Bool { host.isComputer }
        private var root: Page { Self.root(host) }
        private var networkHint: String {
            mac
                ? "The camera joins this network. This Mac must be on it too, by Wi-Fi or Ethernet."
                : context.networkHint
        }

        private var warning: Color { MonitorTheme.linkHealthColor(.watch) }
        private var good: Color { MonitorTheme.linkHealthColor(.stable) }

        /// What the locked page shows and does; nil when the wizard runs normally.
        var lockedPage: LockedPage? { lockedNetwork.map(LockedPage.init) }

        /// The decisions of the Shared Wi-Fi page, kept apart from its rendering.
        struct LockedPage: Equatable {
            let network: StationNetwork
            var title: String { "Shared Wi-Fi" }
            var ssid: String { network.ssid }
            var message: String { "Cameras are using this network. Remove them before changing it." }
            var allowsScan: Bool { false }
        }

        public var body: some View {
            if let page = lockedPage {
                lockedView(page)
            } else {
                wizard
            }
        }

        private func lockedView(_ page: LockedPage) -> some View {
            NavigationStack {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 10) {
                        MonitorIcon.wifi.frame(width: 20, height: 20)
                        Text(page.ssid)
                    }
                    Text(page.message).foregroundStyle(MonitorTheme.muted)
                    Spacer()
                }
                .padding(24)
                .navigationTitle(page.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { complete() }
                    }
                }
            }
            .font(MonitorTheme.font(15))
            .foregroundStyle(MonitorTheme.text)
            .tint(MonitorTheme.accent)
            .preferredColorScheme(.dark)
            // A container of its own, so the sheet carries the wizard context's name while its
            // rows stay separately reachable.
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(context.identifier)
        }

        private var wizard: some View {
            NavigationStack(path: $path) {
                screen(root)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel", action: dismiss)
                        }
                    }
                    .navigationDestination(for: Page.self) { screen($0) }
            }
            .font(MonitorTheme.font(15))
            .foregroundStyle(MonitorTheme.text)
            .tint(MonitorTheme.accent)
            .preferredColorScheme(.dark)
            .alert("Other network", isPresented: $otherNetwork) {
                TextField("Network name", text: $otherName)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Cancel", role: .cancel) {}
                Button("Next") {
                    let name = otherName.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !name.isEmpty { open(.password(name)) }
                }
            }
            .task {
                await refreshCurrentNetwork()
                // Networks this app configured before. iOS keeps other saved networks private.
                let ssids = await StationConfiguredNetworks.ssids()
                configured = ssids.filter { !isCameraNetwork($0) }
            }
            .task {
                // A computer with no camera to scan through lists what its own Wi-Fi sees.
                guard mac, scan == nil else { return }
                computerNearby = await ComputerWiFi.nearbyNetworks()
                computerScanning = false
            }
            .task {
                while !Task.isCancelled {
                    hotspotActive = services.hotspotActive()
                    do { try await Task.sleep(for: .seconds(1)) } catch { return }
                }
            }
            .onAppear { path.forEach(prefill) }
            .onChange(of: scenePhase) { _, phase in
                // Back from Settings with Location or Precise Location changed.
                if phase == .active { Task { await refreshCurrentNetwork() } }
            }
            .onDisappear { scanTask?.cancel() }
            .interactiveDismissDisabled(scanning || working)
            .disabled(working)
        }

        private func screen(_ page: Page) -> some View {
            GeometryReader { proxy in
                // Keyboard avoidance must not switch layout branches and destroy the focused field.
                let size = windowGeometry.size == .zero ? proxy.size : windowGeometry.size
                let landscape = size.width > size.height
                if landscape, page != .choose, !(page == .networks && listLayout.oneColumn) {
                    // Landscape: the leading column stays put; only the form column scrolls,
                    // with Connect / Other network pinned beneath it.
                    HStack(alignment: .top, spacing: page == .networks ? 16 : 14) {
                        // ponytail: scrolls only if it overflows (long saved list, keyboard up).
                        ScrollView {
                            content(page, landscape: true, side: .leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.top, 8).padding(.bottom, 16)
                        }
                        .scrollBounceBehavior(.basedOnSize)
                        .scrollIndicators(.hidden)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        VStack(spacing: 0) {
                            form(page, landscape: true, side: .trailing, inset: 0)
                            footer(page, inset: 0)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .padding(.horizontal, 24)
                } else {
                    let inset: CGFloat = landscape ? 24 : 18
                    VStack(spacing: 0) {
                        form(page, landscape: landscape, side: nil, inset: inset)
                        footer(page, inset: inset)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(Self.pageBackground)
            .navigationTitle(title(page))
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                // Wi-Fi scans the moment it opens; Hotspot only when it needs the name.
                if page == .networks || (page == .hotspot && hotspotName.isEmpty) { startScan() }
                if page == .networks {
                    Task {
                        await StationWiFiNameAccess.shared.request()
                        await refreshCurrentNetwork()
                    }
                }
            }
        }

        /// The scrolling form: the whole page in portrait, the trailing column in landscape.
        private func form(_ page: Page, landscape: Bool, side: Side?, inset: CGFloat) -> some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    content(page, landscape: landscape, side: side)
                    if working {
                        ProgressView(scanning ? "Finishing camera scan…" : "Connecting…")
                            .accessibilityIdentifier("\(context.prefix).progress")
                    }
                    if let errorMessage {
                        Text(errorMessage).font(MonitorTheme.font(13)).foregroundStyle(warning)
                            .accessibilityIdentifier("\(context.prefix).error")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, inset).padding(.top, 8).padding(.bottom, 16)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollDismissesKeyboard(.interactively)
            .monitorScrollFade()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("\(context.prefix).form")
        }

        // MARK: Navigation

        private func title(_ page: Page) -> String {
            switch page {
            case .choose: context.title
            case .networks, .password: "Wi-Fi"
            case .hotspot: "Hotspot"
            }
        }

        private func open(_ next: Page) {
            prefill(next)
            path.append(next)
        }

        private func dismiss() {
            finish { true }
        }

        private func refreshCurrentNetwork() async {
            var current = await services.currentSSID()
            // A Mac's system never names its Wi-Fi to the app; CoreWLAN does.
            if current == nil, mac { current = await ComputerWiFi.currentNetwork() }
            currentSSID = current.flatMap { isCameraNetwork($0) ? nil : $0 }
            let access = StationWiFiNameAccess.shared
            locationDenied = access.denied
            if current != nil || access.undecided {
                locationHint = nil
            } else if access.denied {
                locationHint = mac ? "Allow Location to show this Mac’s Wi-Fi" : "Allow Location to show this iPhone’s Wi-Fi"
            } else if access.approximateOnly {
                locationHint =
                    mac
                    ? "Turn on Precise Location to show this Mac’s Wi-Fi"
                    : "Turn on Precise Location to show this iPhone’s Wi-Fi"
            } else {
                locationHint = nil
            }
        }

        private func isCameraNetwork(_ ssid: String) -> Bool {
            StationNetworkSetupRules.isCameraNetwork(
                ssid, brand: brand, camera: context.camera, cameraSSIDs: cameraSSIDs)
        }

        /// The saved network with this name and kind, if the app stored one.
        private func stored(_ ssid: String, hotspot: Bool) -> StationNetwork? {
            services.savedNetworks().first { $0.ssid == ssid && $0.hotspot == hotspot }
        }

        private var cameraHotspotSSID: String? {
            context.camera.flatMap { StationNetworkSetupRules.network($0, .phoneHotspot) }
        }

        private func prefill(_ next: Page) {
            reveal = false
            switch next {
            case .password(let ssid):
                password = stored(ssid, hotspot: false)?.password ?? ""
            case .hotspot:
                guard hotspotName.isEmpty else { return }
                // A hotspot saved by Multiview or another camera is this same phone's.
                let known =
                    cameraHotspotSSID.flatMap { stored($0, hotspot: true) }
                    ?? services.savedNetworks().last { $0.hotspot }
                hotspotName = known?.ssid ?? cameraHotspotSSID ?? ""
                hotspotPassword = known?.password ?? ""
            case .choose, .networks: break
            }
        }

        // MARK: Camera scan

        private func startScan() {
            guard let scan, lockedPage?.allowsScan ?? true, scanTask == nil, !scanFinished, !working else { return }
            scanning = true
            scanFailed = false
            scanTask = Task {
                do {
                    try await scan { name in
                        guard !working, !found.contains(name), !isCameraNetwork(name) else { return }
                        withAnimation(.snappy) { found.append(name) }
                        suggestHotspot()
                    }
                } catch {
                    if !(error is CancellationError) { scanFailed = true }
                }
                scanning = false
                scanFinished = !scanFailed
                scanTask = nil
            }
        }

        private func rescan() {
            scanFinished = false
            startScan()
        }

        /// iOS hides this phone's name (its hotspot name) from apps, but the camera sees the
        /// hotspot. One phone-like network is taken as this phone's until the operator types.
        private var phoneNetworks: [String] {
            StationNetworkSetupRules.phoneNetworks(found)
        }

        private func suggestHotspot() {
            guard !hotspotNameTouched, hotspotName.isEmpty, phoneNetworks.count == 1 else { return }
            hotspotName = phoneNetworks[0]
            hotspotPassword =
                stored(phoneNetworks[0], hotspot: true)?.password
                ?? hotspotPassword
        }

        /// Saving starts a Bluetooth connect, so a running scan first returns the camera to
        /// its own Wi-Fi and releases its link.
        private func finish(_ action: @escaping @MainActor () async -> Bool) {
            guard !working else { return }
            working = true
            let running = scanTask
            running?.cancel()
            Task {
                await running?.value
                if await action() { close() }
                working = false
            }
        }

        @ViewBuilder private func content(_ page: Page, landscape: Bool, side: Side?) -> some View {
            switch page {
            case .choose: choosePage(landscape)
            case .networks: networksPage(landscape, side)
            case .password(let ssid): passwordPage(ssid, landscape, side)
            case .hotspot: hotspotPage(landscape, side)
            }
        }

        /// Picks one landscape column, or stacks both in portrait.
        @ViewBuilder private func columns<Leading: View, Trailing: View>(
            _ side: Side?, spacing: CGFloat, _ leading: Leading, _ trailing: Trailing
        ) -> some View {
            switch side {
            case .leading: leading
            case .trailing: trailing
            case nil:
                VStack(alignment: .leading, spacing: spacing) {
                    leading
                    trailing
                }
            }
        }

        // MARK: Choose

        private func choosePage(_ landscape: Bool) -> some View {
            AddSetupChooserView(
                chooser: StationNetworkSetupRules.setupChooser(
                    context: context, routes: StationSetupRoute.offered(on: host, hostRoutes: StationSetupRoute.stationNetworks)),
                onSelect: { open($0.kind == .infrastructureNetwork ? .networks : .hotspot) },
                horizontal: landscape)
        }

        // MARK: Wi-Fi

        /// The page's network rows: this device's network, the ones saved in this app's Keychain
        /// (with passwords) or configured by this app before, then the ones found nearby.
        private var rows: StationNetworkRows {
            StationNetworkRows(
                current: currentSSID,
                saved: services.savedNetworks().filter { !$0.hotspot }.map(\.ssid) + configured,
                nearby: computerList ? computerNearby : found, isCameraNetwork: isCameraNetwork)
        }

        private var computerList: Bool { mac && scan == nil }

        /// What the network list shows now (`ListLayout`).
        private var listLayout: ListLayout {
            ListLayout(
                host: host, cameraScans: scan != nil, rows: rows,
                computerScanning: computerScanning, locationDenied: locationDenied)
        }

        private var emptyList: Bool { listLayout.otherNetworkLeads }

        /// The decisions of the network list, kept apart from its rendering.
        struct ListLayout: Equatable {
            let host: HostDevice
            /// A camera scans for networks (it is nearby over Bluetooth).
            let cameraScans: Bool
            let rows: StationNetworkRows
            /// A computer's own Wi-Fi is still looking for networks.
            let computerScanning: Bool
            let locationDenied: Bool

            /// A computer with no camera to scan through: one column (no camera Nearby column
            /// beside it), with what its own Wi-Fi sees as Nearby.
            var oneColumn: Bool { host.isComputer && !cameraScans }
            /// Nothing to choose from and nothing still looking: Other network is the list's first
            /// row, full width, and `emptyNote` says why. Otherwise it is pinned under the list.
            var otherNetworkLeads: Bool { oneColumn && rows.isEmpty && !computerScanning }
            var emptyNote: String? {
                otherNetworkLeads
                    ? StationNetworkRows.emptyNote(host: host, locationDenied: locationDenied) : nil
            }
        }

        private func hasPassword(_ ssid: String) -> Bool {
            stored(ssid, hotspot: false) != nil
        }

        private func networksPage(_ landscape: Bool, _ side: Side?) -> some View {
            let rows = rows
            let savedNetworks = rows.saved
            let known = VStack(alignment: .leading, spacing: 7) {
                if side == nil {
                    Text("Choose the network").font(MonitorTheme.font(22, weight: .semibold))
                    hint(networkHint).padding(.bottom, 8)
                }
                if emptyList {
                    group { otherNetworkButton }
                    emptyNote.padding(.top, 4)
                } else if let currentSSID = rows.current {
                    sectionHeader(mac ? "THIS MAC IS ON" : "THIS IPHONE IS ON")
                        .accessibilityIdentifier("\(context.prefix).currentHeader")
                    group {
                        networkRow(
                            currentSSID,
                            detail: hasPassword(currentSSID)
                                ? "Connected · password saved" : "Connected",
                            detailColor: good)
                    }
                } else if let locationHint {
                    sectionHeader(mac ? "THIS MAC IS ON" : "THIS IPHONE IS ON")
                        .accessibilityIdentifier("\(context.prefix).currentHeader")
                    group {
                        Button {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                openURL(url)
                            }
                        } label: {
                            row(
                                icon: .wifi, title: locationHint,
                                detail: mac
                                    ? "System Settings › Privacy & Security › Location Services. Only the Wi-Fi name is used."
                                    : "Settings › \(brand.appName) › Location. Only the Wi-Fi name is used."
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("\(context.prefix).locationHint")
                    }
                }
                if !savedNetworks.isEmpty {
                    sectionHeader(mac ? "SAVED ON THIS MAC" : "SAVED ON THIS IPHONE").padding(.top, 6)
                    group {
                        ForEach(Array(savedNetworks.enumerated()), id: \.element) { index, name in
                            if index > 0 { divider }
                            networkRow(name, detail: hasPassword(name) ? "Password saved" : nil)
                        }
                    }
                }
            }
            let nearby = VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    sectionLabel("NEARBY")
                    if scanning { ProgressView().controlSize(.mini) }
                    Spacer()
                    if !scanning, scan != nil {
                        Button("Scan again", action: rescan)
                            .font(MonitorTheme.font(12, weight: .semibold))
                            .frame(minHeight: 44)
                            .accessibilityIdentifier("\(context.prefix).rescan")
                    }
                }
                // Same height as `sectionHeader`; Scan again keeps its 44 pt target past the row.
                .frame(height: Self.headerHeight)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("\(context.prefix).nearbyHeader")
                .padding(.top, side == nil ? 6 : 0)
                group {
                    let nearbyNames = rows.nearby
                    ForEach(Array(nearbyNames.enumerated()), id: \.element) { index, name in
                        if index > 0 { divider }
                        networkRow(name, detail: hasPassword(name) ? "Password saved" : nil)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                    if scan == nil || scanning || nearbyNames.isEmpty {
                        if !nearbyNames.isEmpty { divider }
                        row(
                            icon: scanning ? nil : .scan,
                            title: scanning
                                ? "The camera is looking for networks…"
                                : !cameraScansNetworks
                                    ? "This camera can’t list networks"
                                    : scan == nil
                                        ? "Turn the camera on to find networks" : "No networks found yet",
                            detail: scanning
                                ? "Networks appear here as it finds them"
                                : !cameraScansNetworks
                                    ? "Choose a known network, or Other network."
                                    : scanFailed ? "The scan did not finish. Try Scan again." : nil,
                            showsProgress: scanning, chevron: false
                        )
                        .accessibilityIdentifier("\(context.prefix).scanStatus")
                    }
                }
                if side != nil {
                    hint(networkHint).padding(.top, 4)
                }
            }
            // A Mac pairing a new camera has no camera link to scan with: its own, saved and
            // nearby networks, and Other network.
            return columns(
                side, spacing: 7, known,
                Group { if computerList { computerNearbySection(rows.nearby) } else { nearby } })
        }

        /// The networks a computer's own Wi-Fi sees, while it looks and once it found some.
        @ViewBuilder private func computerNearbySection(_ names: [String]) -> some View {
            if computerScanning || !names.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 8) {
                        sectionLabel("NEARBY")
                        if computerScanning { ProgressView().controlSize(.mini) }
                        Spacer()
                    }
                    .frame(height: Self.headerHeight)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("\(context.prefix).nearbyHeader")
                    .padding(.top, 6)
                    group {
                        ForEach(Array(names.enumerated()), id: \.element) { index, name in
                            if index > 0 { divider }
                            networkRow(name, detail: hasPassword(name) ? "Password saved" : nil)
                        }
                        if names.isEmpty {
                            row(
                                icon: nil, title: "Looking for networks nearby…", detail: nil,
                                showsProgress: true, chevron: false
                            )
                            .accessibilityIdentifier("\(context.prefix).scanStatus")
                        }
                    }
                }
            }
        }

        /// Why an empty list is empty. A computer refused Location opens Settings from it.
        @ViewBuilder private var emptyNote: some View {
            let note = listLayout.emptyNote ?? ""
            if mac, locationDenied {
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                } label: {
                    hint(note).multilineTextAlignment(.leading)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("\(context.prefix).emptyNote")
            } else {
                hint(note).accessibilityIdentifier("\(context.prefix).emptyNote")
            }
        }

        private var otherNetworkButton: some View {
            Button {
                otherName = ""
                otherNetwork = true
            } label: {
                row(icon: .plus, title: "Other network…", detail: nil)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("\(context.prefix).otherNetwork")
        }

        private func networkRow(_ name: String, detail: String? = nil, detailColor: Color? = nil)
            -> some View
        {
            Button {
                open(.password(name))
            } label: {
                row(icon: .wifi, title: name, detail: detail, detailColor: detailColor, lock: true)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("\(context.prefix).network.\(name)")
        }

        private func passwordPage(_ ssid: String, _ landscape: Bool, _ side: Side?) -> some View {
            let network = HStack(spacing: 12) {
                MonitorIcon.wifi.frame(width: 19, height: 19).foregroundStyle(MonitorTheme.accent)
                    .frame(width: 38, height: 38)
                    .background(
                        MonitorTheme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 2) {
                    Text(ssid).font(MonitorTheme.font(16, weight: .semibold))
                    Text(
                        ssid == currentSSID
                            ? mac ? "This Mac’s current network" : "This iPhone’s current network"
                            : mac ? "This Mac must be on it, by Wi-Fi or Ethernet" : "This iPhone joins it too"
                    )
                    .font(MonitorTheme.font(11.5)).foregroundStyle(MonitorTheme.muted)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16).padding(.vertical, 13).background(card)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("\(context.prefix).networkSummary")
            let summary = VStack(alignment: .leading, spacing: 6) {
                sectionHeader("NETWORK")
                network
            }
            let checklist = VStack(alignment: .leading, spacing: 13) {
                sectionLabel("BEFORE YOU CONNECT")
                check(
                    "WPA2 or WPA2/WPA3 mixed",
                    landscape ? nil : "WPA3-only networks can refuse some cameras.")
                check(
                    "Devices can see each other",
                    landscape ? nil : "Guest networks with client isolation block the picture.")
                check(
                    "Camera within range",
                    landscape ? nil : "The camera leaves its own Wi-Fi and joins this one.")
            }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading).background(card)
            let secured = security?.ssid == ssid ? security?.secured : nil
            let field = VStack(alignment: .leading, spacing: 6) {
                secureField("PASSWORD", text: $password, id: "\(context.prefix).password")
                if let note = StationNetworkSetupRules.passwordNote(password, secured: secured) {
                    hint(note).accessibilityIdentifier("\(context.prefix).passwordNote")
                }
                hint(
                    mac
                        ? "Saved in this Mac’s Keychain. Every camera you add joins it."
                        : "Saved in this iPhone’s Keychain. Multiview can reuse it.")
            }
            .task(id: ssid) {
                let lookup = services.networkSecured ?? StationNetworkSecurity.currentNetwork(named:)
                let current = await lookup(ssid)
                security = (
                    ssid,
                    StationNetworkSetupRules.security(
                        of: ssid, saved: services.savedNetworks(), current: current)
                )
            }
            // Portrait keeps the password under the network, above the checklist.
            return Group {
                if side == nil {
                    VStack(alignment: .leading, spacing: 16) {
                        summary
                        field
                        checklist
                    }
                } else {
                    columns(
                        side, spacing: 10,
                        VStack(spacing: 10) {
                            summary
                            checklist
                        }, field)
                }
            }
        }

        // MARK: Hotspot

        private func hotspotPage(_ landscape: Bool, _ side: Side?) -> some View {
            let status = HStack(spacing: 10) {
                (hotspotActive ? MonitorIcon.radio : MonitorIcon.triangleAlert)
                    .frame(width: 18, height: 18)
                Text(
                    hotspotActive
                        ? "Personal Hotspot is on"
                        : "Personal Hotspot not detected yet. It can appear once the camera joins."
                )
                .font(MonitorTheme.font(13, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .foregroundStyle(hotspotActive ? good : warning)
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(
                (hotspotActive ? good : warning).opacity(0.1), in: RoundedRectangle(cornerRadius: 12)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12).stroke(
                    (hotspotActive ? good : warning).opacity(0.3), lineWidth: 1)
            )
            .accessibilityIdentifier("\(context.prefix).hotspotStatus")
            let checklist = VStack(alignment: .leading, spacing: 13) {
                sectionLabel("IN SETTINGS › PERSONAL HOTSPOT")
                numbered(
                    1, "Allow Others to Join",
                    landscape ? nil : "Lets the camera join without a prompt.")
                numbered(
                    2, "Maximize Compatibility",
                    landscape ? nil : "Uses 2.4 GHz, which every \(brand.cameraFamily) camera supports.")
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                } label: {
                    HStack(spacing: 8) {
                        MonitorIcon.settings.frame(width: 16, height: 16)
                        Text("Open Settings").font(MonitorTheme.font(13.5, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(MonitorTheme.raised, in: RoundedRectangle(cornerRadius: 12))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading).background(card)
            let name = VStack(alignment: .leading, spacing: 6) {
                sectionHeader("HOTSPOT NAME")
                TextField(
                    "Hotspot name",
                    text: Binding(
                        get: { hotspotName },
                        set: {
                            hotspotNameTouched = true
                            hotspotName = $0
                        })
                )
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .modifier(InputStyle())
                .accessibilityIdentifier("\(context.prefix).hotspotName")
                if phoneNetworks.count > 1
                    || (phoneNetworks.count == 1 && phoneNetworks[0] != hotspotName)
                {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 7) {
                            ForEach(phoneNetworks, id: \.self) { name in
                                Button(name) {
                                    hotspotNameTouched = true
                                    hotspotName = name
                                }
                                .font(MonitorTheme.font(12, weight: .semibold))
                                .padding(.horizontal, 12).frame(minHeight: 34)
                                .background(MonitorTheme.raised, in: RoundedRectangle(cornerRadius: 9))
                                .padding(.vertical, 5).contentShape(Rectangle())
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .monitorScrollFade(.horizontal)
                }
                if scanning, hotspotName.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.mini)
                        hint("The camera is looking for this iPhone’s hotspot…")
                    }
                } else if !landscape {
                    hint("This iPhone’s name, as in Settings › General › About › Name.")
                }
            }
            let pass = VStack(alignment: .leading, spacing: 6) {
                secureField(
                    "HOTSPOT PASSWORD", text: $hotspotPassword, id: "\(context.prefix).hotspotPassword")
                if !landscape {
                    hint(
                        "iOS keeps it private: copy it from Settings › Personal Hotspot once. It is remembered here."
                    )
                }
            }
            return Group {
                if side != nil {
                    columns(
                        side, spacing: 10,
                        VStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 6) {
                                sectionHeader("THIS IPHONE’S HOTSPOT")
                                status
                            }
                            checklist
                        },
                        VStack(alignment: .leading, spacing: 10) {
                            name
                            pass
                        })
                } else {
                    VStack(alignment: .leading, spacing: 14) {
                        status
                        checklist
                        name
                        pass
                    }
                }
            }
        }

        // MARK: Pieces

        /// Connect / Other network, pinned under the form above the safe area or keyboard.
        @ViewBuilder private func footer(_ page: Page, inset: CGFloat) -> some View {
            // An empty list carries Other network as its first row instead.
            if page != .choose, !(page == .networks && emptyList) {
                footerAction(page)
                    .padding(.horizontal, inset)
                    .padding(.top, 8).padding(.bottom, 16)
            }
        }

        @ViewBuilder private func footerAction(_ page: Page) -> some View {
            switch page {
            case .networks:
                otherNetworkButton.background(card)
            case .password(let ssid):
                let secured = security?.ssid == ssid ? security?.secured : nil
                let valid =
                    StationNetworkSetupRules.acceptsPassword(password, secured: secured)
                    && services.acceptsJoin(ssid, password)
                connectButton("Connect over Wi-Fi", enabled: valid) {
                    await save(StationNetwork(ssid: ssid, password: password, hotspot: false))
                }
            case .hotspot:
                let trimmed = hotspotName.trimmingCharacters(in: .whitespacesAndNewlines)
                let valid =
                    hotspotPassword.count >= 8
                    && services.acceptsJoin(trimmed, hotspotPassword)
                connectButton("Connect over Hotspot", enabled: valid) {
                    await save(StationNetwork(ssid: trimmed, password: hotspotPassword, hotspot: true))
                }
            case .choose: EmptyView()
            }
        }

        /// Matches `monitorCardSurface()`.
        private var card: some View {
            RoundedRectangle(cornerRadius: MonitorTheme.radius).fill(MonitorTheme.surface)
                .overlay(RoundedRectangle(cornerRadius: MonitorTheme.radius).strokeBorder(MonitorTheme.border))
        }

        private var divider: some View {
            Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1)
        }

        private func group<Rows: View>(@ViewBuilder _ rows: () -> Rows) -> some View {
            VStack(spacing: 0, content: rows).background(card)
                .clipShape(RoundedRectangle(cornerRadius: MonitorTheme.radius))
        }

        /// The app's eyebrow (Settings cards, Cameras groups).
        private func sectionLabel(_ text: String) -> some View {
            MonitorSectionHeader(text)
        }

        /// Fixed height so paired columns keep their headings and card tops aligned.
        private func sectionHeader(_ text: String) -> some View {
            sectionLabel(text).frame(height: Self.headerHeight, alignment: .leading)
        }

        private static let headerHeight: CGFloat = 24

        private func hint(_ text: String) -> some View {
            Text(text).font(MonitorTheme.font(11.5)).foregroundStyle(MonitorTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }

        private func row(
            icon: MonitorIcon?, title: String, detail: String?, detailColor: Color? = nil,
            lock: Bool = false, showsProgress: Bool = false, chevron: Bool = true
        ) -> some View {
            HStack(spacing: 12) {
                if showsProgress {
                    ProgressView().frame(width: 17, height: 17)
                } else if let icon {
                    icon.frame(width: 17, height: 17).foregroundStyle(MonitorTheme.accent)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(MonitorTheme.font(14.5, weight: .medium)).lineLimit(1)
                    if let detail {
                        Text(detail).font(MonitorTheme.font(11))
                            .foregroundStyle(detailColor ?? MonitorTheme.muted)
                    }
                }
                Spacer(minLength: 0)
                if lock {
                    MonitorIcon.lock.frame(width: 13, height: 13).foregroundStyle(MonitorTheme.faint)
                }
                if chevron {
                    MonitorIcon.chevronRight.frame(width: 16, height: 16)
                        .foregroundStyle(MonitorTheme.faint)
                }
            }
            .padding(.horizontal, 16).frame(minHeight: 52).contentShape(Rectangle())
        }

        private func check(_ title: String, _ detail: String?) -> some View {
            HStack(alignment: .top, spacing: 10) {
                MonitorIcon.check.frame(width: 12, height: 12).foregroundStyle(good)
                    .frame(width: 20, height: 20).background(good.opacity(0.16), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(MonitorTheme.font(13, weight: .medium))
                    if let detail { hint(detail) }
                }
            }
        }

        private func numbered(_ number: Int, _ title: String, _ detail: String?) -> some View {
            HStack(alignment: .top, spacing: 10) {
                Text("\(number)").font(MonitorTheme.font(11, weight: .bold))
                    .foregroundStyle(MonitorTheme.accent)
                    .frame(width: 22, height: 22)
                    .background(MonitorTheme.accent.opacity(0.16), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(MonitorTheme.font(13, weight: .medium))
                    if let detail { hint(detail) }
                }
            }
        }

        private func secureField(_ label: String, text: Binding<String>, id: String) -> some View {
            VStack(alignment: .leading, spacing: 6) {
                sectionHeader(label)
                HStack(spacing: 0) {
                    Group {
                        if reveal {
                            TextField("Password", text: text)
                        } else {
                            SecureField("Password", text: text)
                        }
                    }
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .textContentType(.password)
                    .accessibilityIdentifier(id)
                    Button {
                        reveal.toggle()
                    } label: {
                        (reveal ? MonitorIcon.eyeOff : MonitorIcon.eye).frame(width: 18, height: 18)
                            .foregroundStyle(MonitorTheme.muted).frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(reveal ? "Hide password" : "Show password")
                }
                .modifier(InputStyle(trailing: 2))
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("\(id).field")
            }
        }

        private func connectButton(
            _ title: String, enabled: Bool, action: @escaping @MainActor () async -> Bool
        ) -> some View {
            Button {
                finish(action)
            } label: {
                Text(title).frame(maxWidth: .infinity)
            }
            .buttonStyle(CameraPageButtonStyle(primary: true)).disabled(!enabled)
            .accessibilityIdentifier("\(context.prefix).connect")
        }
    }

    private struct InputStyle: ViewModifier {
        var trailing: CGFloat = 14
        func body(content: Content) -> some View {
            content.font(MonitorTheme.font(15))
                .padding(.leading, 14).padding(.trailing, trailing)
                .frame(minHeight: 48)
                .background(MonitorTheme.raised, in: RoundedRectangle(cornerRadius: 11))
                .overlay(
                    RoundedRectangle(cornerRadius: 11).stroke(Color.white.opacity(0.08), lineWidth: 1)
                        .allowsHitTesting(false))
        }
    }
#endif
