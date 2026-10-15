#if os(iOS)
    import Foundation
    import MonitorPresentation
    import MonitorUI
    import OpenCineAppKit
    import OpenCineCore
    import OpenCineCoreTestSupport
    import SwiftUI
    import Testing
    import UIKit

    /// Review fixtures of the shared camera screens, rendered on an iOS simulator. Each must
    /// render; with `OPENCINE_SCREENSHOTS` set (xcodebuild: `TEST_RUNNER_OPENCINE_SCREENSHOTS`)
    /// they are written there as PNGs for review.
    @MainActor
    @Suite struct ReviewScreens {
        typealias T = CamerasModelTests
        let size = CGSize(width: 402, height: 874)
        let safeArea = EdgeInsets(top: 62, leading: 0, bottom: 34, trailing: 0)

        func model(_ fake: FakeIntegration, saved: [SavedCamera]) -> CamerasModel {
            let store = SavedCamerasStore(document: Defaults([:]).at("document"))
            store.save(saved)
            return CamerasModel(integrations: [AppIntegration(fake)], store: store)
        }

        func cameras(_ model: CamerasModel) -> some View {
            CamerasScreen(
                model: model, brandName: "REVIEW", safeArea: safeArea, onPair: {}, onMedia: {}, onSettings: {})
        }

        func pair(_ model: CamerasModel) -> some View {
            PairScreen(model: model, safeArea: safeArea, onDone: {}, onDiagnostics: {}, onReportProblem: {})
        }

        @Test func reviewFixturesRender() async throws {
            let fake = FakeIntegration(id: IntegrationID("test.cameras"))
            var older = T.camera
            older.id = "camera-0"
            older.name = "B cam"
            older.lastConnected = Date(timeIntervalSince1970: 500)

            let empty = model(fake, saved: [])
            try write(cameras(empty), "01-cameras-empty")

            let listed = model(fake, saved: [older, T.camera])
            fake.publish([
                NearbyCamera(id: "camera-1", name: "CAM-1", model: "Test Body", routes: [.cameraAccessPoint]),
                NearbyCamera(id: "n2", name: "CAM-2", model: "Test Body", routes: [.cameraAccessPoint], signalBars: 3),
            ])
            #expect(await eventually { listed.nearby.count == 2 })
            try write(cameras(listed), "02-cameras-saved-and-nearby")

            listed.connect(T.camera)
            fake.liveAttempt(for: "camera-1")?.progress(
                .awaitingApproval, step: 1, prompt: .approveOnCamera("Tap Allow on the camera"))
            #expect(await eventually { listed.attempts["camera-1"]?.prompt != nil })
            try write(cameras(listed), "03-cameras-connecting")
            listed.cancel("camera-1")

            listed.connect(older, route: T.wifi.id)
            fake.liveAttempt(for: "camera-0")?.fail(T.failure)
            #expect(await eventually { listed.failures["camera-0"] != nil })
            try write(cameras(listed), "04-cameras-failure")

            let pairing = model(fake, saved: [T.camera])
            pairing.beginPairing()
            #expect(await eventually { pairing.nearby.count == 2 })
            pairing.selection = "n2"
            try write(pair(pairing), "05-pair-choose")

            pairing.connect(try #require(pairing.nearby.first { $0.id == "n2" }))
            fake.liveAttempt(for: "n2")?.progress(
                .awaitingApproval, step: 1, prompt: .approveOnCamera("Tap Allow on the camera screen"))
            #expect(await eventually { pairing.attempts["n2"]?.prompt != nil })
            // Each render's teardown ends pairing and clears the selection, as leaving the page does.
            pairing.selection = "n2"
            try write(pair(pairing), "06-pair-approve")

            fake.liveAttempt(for: "n2")?.progress(
                .joiningNetwork, step: 2, prompt: .acceptNetworkJoin(network: "CAM-2", "Tap Join when asked to join CAM-2"),
                note: "Joining CAM-2")
            #expect(await eventually { pairing.attempts["n2"]?.progress?.current == 2 })
            pairing.selection = "n2"
            try write(pair(pairing), "07-pair-join-network")

            fake.liveAttempt(for: "n2")?.fail(T.failure)
            #expect(await eventually { pairing.failures["n2"] != nil })
            pairing.selection = "n2"
            try write(pair(pairing), "08-pair-failure")

            let preparation = IntegrationPairingFlow(
                presentation: CameraPairingPresentation(
                    steps: [
                        CameraPairingStep("Prepare", "Enable the connection"),
                        CameraPairingStep("Connect", "Choose the camera"),
                    ],
                    currentStep: 0, title: "Prepare your camera",
                    body: "Choose the camera connection in its menu.", target: "Camera setup", hint: "",
                    primaryAction: "Continue", primaryActionEnabled: true, backAction: "Back"),
                onPrimary: {}, onBack: {},
                content: AnyView(Text("Network setup instructions").foregroundStyle(.white)))
            try write(
                PairScreen(
                    model: pairing, safeArea: safeArea, onDone: {}, onDiagnostics: {},
                    onReportProblem: {}, pairingFlow: preparation),
                "09-pair-integration-preparation")
        }

        /// The shared root over `ShellModel`: cameras, a cover over them, pair, then the monitor slot
        /// (a stand-in here) with and without a cover, then back to the cameras page.
        @Test func reviewRootAndCoverFixturesRender() async throws {
            let fake = FakeIntegration(id: IntegrationID("test.cameras"))
            let shell = ShellModel(cameras: model(fake, saved: [T.camera]))
            func root() -> some View {
                AppShell(
                    model: shell, brand: ShellBrand(name: "REVIEW"),
                    actions: ShellActions(diagnostics: {}, reportProblem: {}),
                    safeArea: { _ in safeArea }
                ) { monitor in
                    ZStack {
                        LinearGradient(colors: [.indigo, .teal, .orange], startPoint: .leading, endPoint: .trailing)
                        VStack(spacing: 8) {
                            Text("MONITOR SLOT (SIMULATED)").font(.headline)
                            Text(monitor.camera.saved.displayName)
                            if let cover = shell.cover { Text("covered by \(String(describing: cover))") }
                        }
                        .foregroundStyle(.white)
                    }
                    .ignoresSafeArea()
                } page: { cover in
                    ZStack {
                        Color(white: 0.08).ignoresSafeArea()
                        VStack(spacing: 8) {
                            Text(cover == .settings ? "SETTINGS PAGE" : "MEDIA PAGE").font(.headline)
                            Text("cover page (SIMULATED)").foregroundStyle(.gray)
                            Circle().fill(.yellow).frame(width: 24, height: 24)
                        }
                        .foregroundStyle(.white)
                    }
                }
            }

            try write(root(), "10-root-cameras")
            shell.open(.settings)
            try write(root(), "11-root-cameras-settings-cover")
            shell.dismissCover()
            shell.beginPairing()
            try write(root(), "12-root-pair")
            shell.cameras.connect(T.camera)
            fake.liveAttempt(for: T.camera.id)?.connect(session: FakeCameraSession.lunaLike())
            #expect(await eventually { shell.route == .monitor })
            let host = shell.monitor?.id
            try write(root(), "13-root-monitor")
            shell.open(.media)
            try write(root(), "14-root-monitor-media-cover")
            shell.dismissCover()
            #expect(shell.monitor?.id == host, "a cover never replaces the monitor")
            try write(root(), "15-root-monitor-revealed")
            shell.close()
            try write(root(), "16-root-cameras-after-close")
        }

        /// Apps call the pair page without `extra`, as before the slot existed.
        @Test func thePairPageStillTakesNoExtra() {
            let page = PairCameraPage(
                presentation: CameraPairingPresentation(steps: [], currentStep: 0, title: "", body: "", target: "", hint: ""),
                onSelect: { _ in }, onPrimary: {}, onBack: {}, onDiagnostics: {}, onReportProblem: {},
                onWatchFeed: {})
            #expect(type(of: page) == PairCameraPage<EmptyView>.self)
        }

        /// A lone setup still renders with its custom title; no legal links on the shared pages.
        @Test func singleSetupFixturesRender() throws {
            let fake = FakeIntegration(id: IntegrationID("test.cameras"))
            var single = T.camera
            single.routes = [T.ap]
            let listed = model(fake, saved: [single])
            listed.renameRoute(T.ap.id, of: single.id, to: "Stage left")
            let layouts: [(String, CGSize, EdgeInsets)] = [
                ("phone-portrait", size, safeArea),
                (
                    "phone-landscape", CGSize(width: 874, height: 402),
                    EdgeInsets(top: 0, leading: 62, bottom: 21, trailing: 62)
                ),
                (
                    "ipad-portrait", CGSize(width: 1032, height: 1376),
                    EdgeInsets(top: 24, leading: 0, bottom: 20, trailing: 0)
                ),
                (
                    "ipad-landscape", CGSize(width: 1376, height: 1032),
                    EdgeInsets(top: 24, leading: 0, bottom: 20, trailing: 0)
                ),
            ]
            for (name, bounds, insets) in layouts {
                try write(
                    CamerasScreen(
                        model: listed, brandName: "REVIEW (SIMULATED)", safeArea: insets,
                        onPair: {}, onMedia: {}, onSettings: {}),
                    "17-cameras-single-setup-\(name)", size: bounds)
                try write(
                    PairScreen(
                        model: model(fake, saved: []), safeArea: insets,
                        onDone: {}, onDiagnostics: {}, onReportProblem: {}),
                    "18-pair-startup-\(name)", size: bounds)
            }
        }

        func write(_ view: some View, _ name: String, size: CGSize? = nil) throws {
            // Fixtures pass their own viewport insets, including when rendering a different orientation.
            let host = UIHostingController(rootView: view.preferredColorScheme(.dark).ignoresSafeArea())
            let window = UIWindow(frame: CGRect(origin: .zero, size: size ?? self.size))
            window.rootViewController = host
            window.isHidden = false
            host.view.frame = window.bounds
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            // A hostless test has no window scene to draw into: render the layer tree directly.
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { context in
                host.view.layer.render(in: context.cgContext)
            }
            window.isHidden = true
            #expect(distinctColors(image) > 8, "\(name) rendered nothing")
            if let directory = ProcessInfo.processInfo.environment["OPENCINE_SCREENSHOTS"] {
                try #require(image.pngData()).write(to: URL(fileURLWithPath: directory).appending(path: "\(name).png"))
            }
        }

        /// Distinct colors on a coarse grid: a blank or single-color render has one or two.
        func distinctColors(_ image: UIImage) -> Int {
            guard let cg = image.cgImage, let data = cg.dataProvider?.data, let bytes = CFDataGetBytePtr(data)
            else { return 0 }
            var colors = Set<UInt32>()
            for y in stride(from: 0, to: cg.height, by: 17) {
                for x in stride(from: 0, to: cg.width, by: 13) {
                    let offset = y * cg.bytesPerRow + x * cg.bitsPerPixel / 8
                    colors.insert(UInt32(bytes[offset]) << 16 | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]))
                }
            }
            return colors.count
        }
    }
#endif
