#if os(iOS)
import MonitorPresentation
import MonitorUI
import OpenCineAppKit
import OpenCineCore
import OpenCineCoreTestSupport
import OpenCineHostedAccessibility
import OpenCineHostedTestSupport
import SwiftUI
import Testing
import UIKit
@testable import OpenCineAppKitApple

/// The shared Multiview screen and settings popup, hosted over Core's Multiview fakes (SIMULATED):
/// what the operator is shown and can reach. Pocket's UI tests pin its full layouts.
@MainActor @Suite struct MultiviewScreenTests {
    @Test func theStageOffersAddAndListsTheCamerasThatMayJoin() async throws {
        #expect(await HostedAccessibility.awaitRuntime())
        let stage = ScreenFixture()
        let c = stage.coordinator
        c.networkConfigured = true
        c.ssid = "Studio"
        c.found = [FakeStationCamera(name: "Camera A"), FakeStationCamera(name: "NoPreview B")]
        let window = stage.host(MultiviewScreen(coordinator: c, host: stage.screenHost, startsSession: false))
        defer { window.close() }
        let add = await window.element { HostedAccessibility.identifier($0) == "multiview.add" }
        let button = try #require(add, "an empty slot offers Add camera")
        window.activate(button)
        let picker = await window.element { HostedAccessibility.identifier($0) == "multiview.cameraPicker" }
        #expect(picker != nil, "Add opens the camera list: \(window.labels())")
        #expect(window.labels().contains("Add camera"))
        // The list's rows sit in a scroll view, which vends its elements only in an application
        // scene (the package-only runner has none; `MultiviewCoordinatorTests` pin the rows).
        if window.inScene {
            let listed = await HostedCondition.wait {
                let labels = window.labels()
                return labels.contains("Camera A") && labels.contains("NoPreview B")
                    && labels.contains("Each camera will join Studio. Approve on the camera if asked.")
                    && labels.contains(MultiviewCopy.previewUnavailable)
            }
            #expect(listed, "Shown: \(window.labels())")
        }
    }

    @Test func theSettingsPopupShowsTheCamerasAndTheirCategoriesInOrder() async throws {
        #expect(await HostedAccessibility.awaitRuntime())
        let stage = ScreenFixture()
        let c = stage.coordinator
        c.members[0].camera = FakeStationCamera(name: "Wide")
        c.members[2].camera = FakeStationCamera(name: "Side")
        stage.screenHost.state = MultiviewCameraSettingsState(
            categories: MultiviewSettingsCategory.offered(
                focus: true, aperture: false, photo: false, audio: false),
            recording: true)
        let window = stage.host(
            MultiviewCameraSettingsPanel(
                coordinator: c, host: stage.screenHost, initialSlot: 2,
                viewport: CGSize(width: 402, height: 874), safeArea: EdgeInsets(), close: {}))
        defer { window.close() }
        let shown = await HostedCondition.wait {
            let labels = window.labels()
            return labels.contains("A \u{00B7} Wide") && labels.contains("C \u{00B7} Side")
                && labels.contains(MultiviewCopy.cameraSettings)
        }
        #expect(shown, "Shown: \(window.labels())")
        #expect(stage.screenHost.opened == [2], "the popup opens the chosen camera's editor")
        let ids = window.identifiers()
        #expect(ids.contains("multiview.settings.panel"))
        #expect(ids.contains("multiview.settings.camera.0") && ids.contains("multiview.settings.camera.2"))
        let tab = window.elements().first { HostedAccessibility.identifier($0) == "multiview.settings.camera.2" }
        #expect(tab?.accessibilityValue == "Unavailable", "a camera without a control path is unavailable")
        // The rail and the controls sit in scroll views (see above): checked in an application scene.
        if window.inScene {
            let rail = await HostedCondition.wait {
                let ids = window.identifiers()
                return MultiviewSettingsCategory.offered(focus: true, aperture: false, photo: false, audio: false)
                    .allSatisfy { ids.contains($0.identifier) }
                    && window.labels().contains(MultiviewCopy.controlsUnavailable)
            }
            #expect(rail, "Shown: \(window.labels()) \(window.identifiers())")
        }
    }
}

/// A screen host of plain views.
@MainActor
private final class PlainScreenHost: MultiviewScreenHost {
    var state: MultiviewCameraSettingsState?
    var opened: [Int] = []

    var editsCameraSettings: Bool { true }
    var appliesAutoLUT: Bool { true }
    func openCameraSettings(slot: Int) { opened.append(slot) }
    func cameraSettings(slot: Int) -> MultiviewCameraSettingsState? { state }
    func picture(slot: Int, fill: Bool) -> some View { Color.black }
    func backdrop(
        layout: MultiviewPresentationLayout, geometry: MultiviewStageGeometry, enabled: Bool
    ) -> some ViewModifier { EmptyModifier() }
    func settingsPreview(slot: Int) -> some View { Color.gray.frame(height: 90) }
    func settingsControls(
        slot: Int, category: MultiviewSettingsCategory, enabled: Bool,
        presented: @escaping () -> Bool, close: @escaping () -> Void
    ) -> some View { Text("Controls \(category.title)") }
    func liveView(slot: Int, exit: @escaping () -> Void) -> some View { Button("Back", action: exit) }
    var stationBrand: StationNetworkBrand {
        StationNetworkBrand(appName: "App", cameraFamily: "Cam", cameraNetworkPrefix: "cam")
    }
    var stationServices: StationNetworkServices {
        StationNetworkServices(
            savedNetworks: { [] }, currentSSID: { nil }, hotspotActive: { false },
            acceptsJoin: { _, _ in true })
    }
}

/// A coordinator over Core's Multiview fakes with four slots, and its plain host.
@MainActor
private final class ScreenFixture {
    let links = (0..<4).map { _ in FakeMemberLink() }
    let screenHost = PlainScreenHost()
    let coordinator: MultiviewCoordinator<FakeMemberLink>

    init() {
        let policy = MultiviewCameraPolicy<FakeStationCamera>(
            qualification: { _, _ in .qualified }, hasPreview: { !$0.name.hasPrefix("NoPreview") })
        coordinator = MultiviewCoordinator(
            links: links, policy: policy, commissioner: FakeStationCommissioner(),
            scanner: nil, hostPath: FakeStationHostPath(), describe: { $0.record },
            journal: MultiviewJournalStorage(load: { nil }, save: { _ in true }),
            networks: MultiviewNetworkStorage(password: { _, _ in nil }, save: { _ in }))
        coordinator.host = screenHost
    }

    func host(_ view: some View) -> HostedWindow {
        let controller = UIHostingController(rootView: view)
        // Scroll accessibility needs the foreground application scene, when the runner has one.
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map(UIWindow.init(windowScene:)) ?? UIWindow()
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.frame = window.bounds
        return HostedWindow(window: window, inScene: scene != nil)
    }
}

@MainActor
private struct HostedWindow {
    let window: UIWindow
    /// Hosted in an application scene, where scroll views vend their content.
    let inScene: Bool

    /// Every element SwiftUI vends, scroll view content included (indexed elements).
    func elements() -> [NSObject] {
        guard let view = window.rootViewController?.view else { return [] }
        view.setNeedsLayout()
        view.layoutIfNeeded()
        return HostedAccessibility.elements(in: view)
    }

    func labels() -> [String] {
        elements().filter(\.isAccessibilityElement).compactMap(\.accessibilityLabel)
    }

    func identifiers() -> [String] {
        elements().compactMap(HostedAccessibility.identifier)
    }

    func element(_ matches: @escaping (NSObject) -> Bool) async -> NSObject? {
        var found: NSObject?
        _ = await HostedCondition.wait {
            found = elements().first(where: matches)
            return found != nil
        }
        return found
    }

    func activate(_ element: NSObject) {
        if !element.accessibilityActivate() { (element as? UIControl)?.sendActions(for: .touchUpInside) }
    }

    func close() {
        window.isHidden = true
        window.rootViewController = nil
    }
}
#endif
