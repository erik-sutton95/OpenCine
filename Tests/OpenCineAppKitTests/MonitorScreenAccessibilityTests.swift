#if os(iOS)
import MonitorPresentation
import MonitorUI
import OpenCineAppKit
    import OpenCineCore
    import OpenCineCoreTestSupport
import OpenCineHostedAccessibility
import OpenCineHostedTestSupport
import Observation
import SwiftUI
import XCTest

/// What VoiceOver can reach in each slot, read from the hosting view's accessibility
/// elements rather than XCUITest's inventory of mounted containers.
@MainActor
final class MonitorScreenAccessibilityTests: XCTestCase {
        /// The monitor's own `.statusBarHidden` must still reach the window through the native
        /// accessibility boundary, also while a cover hides the retained monitor. Without it the
        /// status bar returns after a rotation and covers the monitor's top-left Back control.
        /// The bridge only restates a hidden status bar: an app that hides it at its root keeps it
        /// hidden, and a monitor that asks for nothing does not hide it.
        func testShellMonitorWithoutAStatusBarPreferenceLeavesTheAppsChoice() async throws {
            for appHides in [true, false] {
                let shell = ShellModel(cameras: CamerasModelTests().model())
                shell.present(ConnectedCamera(saved: CamerasModelTests.camera, session: FakeCameraSession.lunaLike()))
                let host = UIHostingController(
                    rootView: AppShell(
                        model: shell, brand: ShellBrand(name: "SIMULATED"),
                        actions: ShellActions(diagnostics: {}, reportProblem: {}),
                        coverPresentation: .shell
                    ) { _ in
                        Color.black.ignoresSafeArea()
                    } page: { _ in
                        Button("Status cover") {}
                    }.statusBarHidden(appHides))
                let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
                window.rootViewController = host
                window.makeKeyAndVisible()
                host.view.frame = window.bounds
                for _ in 0..<20 {
                    window.layoutIfNeeded()
                    host.view.layoutIfNeeded()
                    try await Task.sleep(for: .milliseconds(10))
                }
                XCTAssertEqual(host.prefersStatusBarHidden, appHides)
                window.isHidden = true
                window.rootViewController = nil
                shell.close()
            }
        }

        func testShellMonitorStatusBarPreferenceReachesTheWindowAcrossCovers() async throws {
            let shell = ShellModel(cameras: CamerasModelTests().model())
            shell.present(ConnectedCamera(saved: CamerasModelTests.camera, session: FakeCameraSession.lunaLike()))
            let host = UIHostingController(
                rootView: AppShell(
                    model: shell, brand: ShellBrand(name: "SIMULATED"),
                    actions: ShellActions(diagnostics: {}, reportProblem: {}),
                    coverPresentation: .shell
                ) { _ in
                    Color.black.ignoresSafeArea().statusBarHidden(true)
                } page: { _ in
                    Button("Status cover") {}.accessibilityIdentifier("probe.status.cover")
                })
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
            window.rootViewController = host
            window.makeKeyAndVisible()
            host.view.frame = window.bounds
            defer {
                window.isHidden = true
                window.rootViewController = nil
                shell.close()
            }
            func statusBarHidden() async -> Bool {
                await HostedCondition.wait {
                    window.layoutIfNeeded()
                    host.view.layoutIfNeeded()
                    return host.prefersStatusBarHidden
                }
            }
            let live = await statusBarHidden()
            XCTAssertTrue(live, "The live monitor's hidden status bar must reach the window's root controller")
            shell.open(.settings)
            window.frame = CGRect(origin: .zero, size: CGSize(width: 874, height: 402))
            host.view.frame = window.bounds
            let covered = await statusBarHidden()
            XCTAssertTrue(covered, "The retained monitor keeps its status bar preference under a cover")
            shell.dismissCover()
            window.frame = CGRect(origin: .zero, size: CGSize(width: 402, height: 874))
            host.view.frame = window.bounds
            let revealed = await statusBarHidden()
            XCTAssertTrue(revealed, "Returning from a rotated cover must keep the status bar hidden")
        }

        func testShellMonitorKeepsItsNativeGlobalFrameAcrossAnInsetParentAndCovers() async throws {
            let shell = ShellModel(cameras: CamerasModelTests().model())
            let camera = FakeCameraSession.lunaLike()
            shell.present(ConnectedCamera(saved: CamerasModelTests.camera, session: camera))
            let lifetime = ShellAccessibilityLifetime()
            let host = UIHostingController(
                rootView: AppShell(
                    model: shell, brand: ShellBrand(name: "SIMULATED"),
                    actions: ShellActions(diagnostics: {}, reportProblem: {}),
                    coverPresentation: .shell
                ) { _ in
                    ShellAccessibilityFrameMonitor(lifetime: lifetime)
                } page: { _ in
                    Button("Geometry cover") {}.accessibilityIdentifier("probe.geometry.cover")
                })
            // SIMULATED inset parent: the monitor still owns this whole native test window.
            host.additionalSafeAreaInsets = UIEdgeInsets(top: 37, left: 13, bottom: 29, right: 17)
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
            window.rootViewController = host
            window.makeKeyAndVisible()
            host.view.frame = window.bounds
            defer {
                window.isHidden = true
                window.rootViewController = nil
                shell.close()
            }
            func fillsWindow() async -> Bool {
                await HostedCondition.wait {
                    window.layoutIfNeeded()
                    host.view.layoutIfNeeded()
                    guard let native = lifetime.natives.first else { return false }
                    let frame = native.convert(native.bounds, to: window)
                    return abs(frame.minX - window.bounds.minX) < 0.5
                        && abs(frame.minY - window.bounds.minY) < 0.5
                        && abs(frame.width - window.bounds.width) < 0.5
                        && abs(frame.height - window.bounds.height) < 0.5
                }
            }
            let initialFullFrame = await fillsWindow()
            let native = try XCTUnwrap(lifetime.natives.first)
            XCTAssertGreaterThan(host.view.safeAreaInsets.top, 0, "The parent must be inset")
            XCTAssertGreaterThan(host.view.safeAreaInsets.left, 0, "The parent must be inset")
            XCTAssertTrue(
                initialFullFrame,
                "Native monitor frame \(native.convert(native.bounds, to: window)) must fill \(window.bounds)"
            )
            let identity = lifetime.identities.first
            XCTAssertNotNil(identity)

            for (cover, size) in [
                (ShellModel.Cover.media, CGSize(width: 874, height: 402)),
                (.settings, CGSize(width: 402, height: 874)),
            ] {
                shell.open(cover)
                let covered = await HostedCondition.wait {
                    host.view.layoutIfNeeded()
                    return HostedAccessibility.elements(in: host.view).contains {
                        Self.probeIdentifier($0) == "probe.geometry.cover"
                    }
                }
                XCTAssertTrue(covered)
                XCTAssertTrue(native.window === window)
                XCTAssertTrue(native.isDescendant(of: host.view))
                window.frame = CGRect(origin: .zero, size: size)
                host.view.frame = window.bounds
                shell.dismissCover()
                let revealedFullFrame = await fillsWindow()
                XCTAssertTrue(
                    revealedFullFrame,
                    "Native monitor frame \(native.convert(native.bounds, to: window)) must fill \(window.bounds)"
                )
                XCTAssertEqual(lifetime.identities, identity.map { [$0] } ?? [])
                XCTAssertEqual(lifetime.natives.count, 1)
                XCTAssertTrue(native.window === window)
                XCTAssertTrue(native.isDescendant(of: host.view))
                XCTAssertEqual(shell.hostsMounted, 1)
                XCTAssertEqual(shell.hostsUnmounted, 0)
                XCTAssertEqual(shell.monitor?.session.id, camera.id)
            }
        }

        func testShellCoverExcludesExplicitlyExposedLiveControlsWithoutRemounting() async throws {
            let shell = ShellModel(cameras: CamerasModelTests().model())
            let camera = FakeCameraSession.lunaLike()
            shell.present(ConnectedCamera(saved: CamerasModelTests.camera, session: camera))
            let lifetime = ShellAccessibilityLifetime()
            let environment = ShellAccessibilityEnvironment()
            let physical = MonitorWindowGeometry(
                size: CGSize(width: 874, height: 402),
                safeArea: EdgeInsets(top: 0, leading: 59, bottom: 21, trailing: 7),
                topControlInset: 17)
            let host = UIHostingController(
                rootView: ZStack {
                    AppShell(
                        model: shell, brand: ShellBrand(name: "SIMULATED"),
                        actions: ShellActions(diagnostics: {}, reportProblem: {}),
                        coverPresentation: .shell
                    ) { _ in
                        ShellAccessibilityMonitor(lifetime: lifetime)
                    } page: { _ in
                        Button("Cover action") {}.accessibilityIdentifier("probe.cover")
                    }
                    Text("Ready").accessibilityIdentifier("probe.anchor")
                }.environment(environment).environment(\.monitorWindowGeometry, physical))
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 874, height: 402))
            window.rootViewController = host
            window.makeKeyAndVisible()
            host.view.frame = window.bounds
            defer {
                window.isHidden = true
                window.rootViewController = nil
                shell.close()
            }
            func exposed() -> Set<String> {
                host.view.layoutIfNeeded()
                return Set(
                    HostedAccessibility.elements(in: host.view).filter(\.isAccessibilityElement)
                        .compactMap(Self.probeIdentifier))
            }
            let mounted = await HostedCondition.wait { exposed().contains("probe.live") }
            XCTAssertTrue(mounted, "The live control must be exposed before checking coverage")
            XCTAssertFalse(exposed().contains("probe.live.selfHidden"))
            let identity = lifetime.identities.first
            XCTAssertNotNil(identity)
            let native = try XCTUnwrap(lifetime.natives.first)
            XCTAssertEqual(lifetime.environmentIdentity, ObjectIdentifier(environment))
            XCTAssertEqual(lifetime.windowGeometry, physical)

            for cover in [ShellModel.Cover.media, .settings] {
                shell.open(cover)
                let covered = await HostedCondition.wait {
                    let values = exposed()
                    return values.contains("probe.cover") && !values.contains("probe.live")
                }
                XCTAssertTrue(covered, "Covered controls remain exposed: \(exposed().sorted())")
                XCTAssertTrue(
                    exposed().contains("probe.anchor"), "Coverage must preserve its sibling")
                XCTAssertFalse(exposed().contains("probe.live.selfHidden"))

                shell.dismissCover()
                let revealed = await HostedCondition.wait {
                    let values = exposed()
                    return values.contains("probe.live") && !values.contains("probe.cover")
                }
                XCTAssertTrue(revealed, "Live controls must return when the page closes")
                XCTAssertFalse(exposed().contains("probe.live.selfHidden"))
                XCTAssertEqual(lifetime.identities, identity.map { [$0] } ?? [])
                XCTAssertEqual(shell.hostsMounted, 1)
                XCTAssertEqual(shell.hostsUnmounted, 0)
                XCTAssertEqual(shell.monitor?.session.id, camera.id)
                XCTAssertEqual(lifetime.natives.count, 1)
                XCTAssertTrue(native.isDescendant(of: host.view))
                XCTAssertEqual(lifetime.environmentIdentity, ObjectIdentifier(environment))
                XCTAssertEqual(lifetime.windowGeometry, physical)
            }
        }

    func testVisibleChromeKeepsControlsThatHideThemselvesHidden() async throws {
        let inputs = ProbeInputs()
        let exposed = try await exposedProbes(inputs)

        XCTAssertTrue(ProbeInputs.slotProbes.isSubset(of: exposed), "Exposed: \(exposed.sorted())")
        // Pocket's zoom chip hides itself under an open picker. A slot or group attachment
        // above it would expose it again while the chrome is visible.
        XCTAssertFalse(exposed.contains("probe.tools.selfHidden"))
    }

    func testCoveredChromeIsNotExposed() async throws {
        let inputs = ProbeInputs()
        inputs.visible = false
        let exposed = try await exposedProbes(inputs)

        XCTAssertTrue(exposed.isDisjoint(with: ProbeInputs.allProbes), "Exposed: \(exposed.sorted())")
    }

    func testTransientlyHiddenChromeLeavesItsBoundedSlotsHidden() async throws {
        let inputs = ProbeInputs()
        inputs.transientControlsHidden = true
        let exposed = try await exposedProbes(inputs)

        // Status, power and values are hidden by the screen; tools and system content hide
        // per control, as the zoom-dial apps already do (LiveSystemChrome `visible`).
        for probe in ["probe.status", "probe.power", "probe.capture", "probe.tools.selfHidden"] {
            XCTAssertFalse(exposed.contains(probe), "\(probe) exposed: \(exposed.sorted())")
        }
    }

    func testStatusOnlyAdmissionLeavesOtherChromeExposed() async throws {
        let inputs = ProbeInputs()
        inputs.statusInteractive = false
        let exposed = try await exposedProbes(inputs)

        XCTAssertFalse(exposed.contains("probe.status"), "Exposed: \(exposed.sorted())")
        XCTAssertTrue(ProbeInputs.slotProbes.subtracting(["probe.status"]).isSubset(of: exposed),
            "Exposed: \(exposed.sorted())")
        XCTAssertFalse(exposed.contains("probe.tools.selfHidden"))
    }

    private func exposedProbes(_ inputs: ProbeInputs) async throws -> Set<String> {
        let host = UIHostingController(rootView: ProbeScreen(inputs: inputs))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 874, height: 402))
        host.safeAreaRegions = []
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        // The anchor sits outside the screen and is always exposed: once it is in the tree the
        // screen has rendered, so every "not exposed" check reads a complete tree.
        var exposed = Set<String>()
        _ = await HostedCondition.wait {
            host.view.layoutIfNeeded()
            exposed = Set(HostedAccessibility.leaves(in: host.view).compactMap(Self.probeIdentifier))
            return exposed.contains("probe.anchor")
        }
        // The shared walk turns the accessibility runtime on wherever it can (a simulator), so
        // only a host where it cannot (a device without assistive access) may skip.
        try XCTSkipIf(
            !exposed.contains("probe.anchor") && !HostedAccessibility.enableRuntime(),
            "No accessibility tree: enable app accessibility")
        // Without the anchor every "not exposed" check would pass on an empty tree.
        XCTAssertTrue(exposed.contains("probe.anchor"), "No accessibility tree from the hosted walk")
        return exposed
    }

    private static func probeIdentifier(_ object: NSObject) -> String? {
        HostedAccessibility.identifier(object).flatMap { $0.hasPrefix("probe.") ? $0 : nil }
    }
}

    @MainActor
    private final class ShellAccessibilityLifetime {
        var identities: [UUID] = []
        var natives: [UIView] = []
        var environmentIdentity: ObjectIdentifier?
        var windowGeometry: MonitorWindowGeometry?
    }

    private struct ShellAccessibilityMonitor: View {
        let lifetime: ShellAccessibilityLifetime
        @State private var identity = UUID()
        @Environment(ShellAccessibilityEnvironment.self) private var environment

        var body: some View {
            VStack {
                Button("Live action") {}.accessibilityIdentifier("probe.live")
                    .accessibilityHidden(false)
                Button("Hidden action") {}.accessibilityIdentifier("probe.live.selfHidden")
                    .accessibilityHidden(true)
                ShellAccessibilityNativeProbe(lifetime: lifetime)
                    .frame(width: 1, height: 1).accessibilityHidden(true)
            }
            .onAppear {
                lifetime.identities.append(identity)
                lifetime.environmentIdentity = ObjectIdentifier(environment)
            }
        }
    }

    private struct ShellAccessibilityFrameMonitor: View {
        let lifetime: ShellAccessibilityLifetime
        @State private var identity = UUID()

        var body: some View {
            Color.clear.overlay {
                ShellAccessibilityNativeProbe(lifetime: lifetime)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .ignoresSafeArea()
            .onAppear { lifetime.identities.append(identity) }
        }
    }

    private struct ShellAccessibilityNativeProbe: UIViewRepresentable {
        let lifetime: ShellAccessibilityLifetime

        func makeUIView(context: Context) -> UIView {
            let view = UIView()
            lifetime.natives.append(view)
            return view
        }

        func updateUIView(_ view: UIView, context: Context) {
            lifetime.windowGeometry = context.environment.monitorWindowGeometry
        }
    }

    @MainActor
    @Observable
    private final class ShellAccessibilityEnvironment {
        let marker = UUID()
    }

@MainActor
@Observable
private final class ProbeInputs {
    static let slotProbes: Set<String> = [
        "probe.status", "probe.power", "probe.capture", "probe.tools", "probe.system.lock",
        "probe.system.settings", "probe.system.media", "probe.system.record", "probe.system.display",
    ]
    static let allProbes = slotProbes.union(["probe.tools.selfHidden"])

    var visible = true
    var transientControlsHidden = false
    var statusInteractive = true
    let control = MonitorControlModel()
}

private struct ProbeScreen: View {
    let inputs: ProbeInputs

    var body: some View {
        ZStack(alignment: .topLeading) {
            screen
            probe("anchor")
        }
    }

    private var screen: some View {
        let layout = FieldMonitorLayout(width: 874, height: 402)
        return MonitorScreen(control: inputs.control, layout: layout, sourceAspect: 16 / 9,
            presentation: MonitorScreenPresentation(visible: inputs.visible,
                transientControlsHidden: inputs.transientControlsHidden, statusInteractive: inputs.statusInteractive)) {
            Color.gray
        } assists: {
            EmptyView()
        } signal: {
            EmptyView()
        } status: {
            probe("status")
        } power: {
            probe("power")
        } capture: {
            probe("capture")
        } system: {
            // The real placement: each control carries its own `accessibilityHidden(!visible)`,
            // which an app (Nikon) may leave at its default while a full-screen page covers it.
            MonitorSystemControls(
                layout: layout,
                visibility: MonitorSystemControlsVisibility(
                    lock: true, settings: true, media: true, record: true, display: true)
            ) {
                probe("system.lock")
            } settings: {
                probe("system.settings")
            } media: {
                probe("system.media")
            } record: {
                probe("system.record")
            } display: {
                probe("system.display")
            }
        } tools: {
            ZStack {
                probe("tools").position(x: 200, y: 200)
                probe("tools.selfHidden").position(x: 300, y: 200).opacity(0).accessibilityHidden(true)
            }
        } panels: {
            EmptyView()
        } cover: {
            if !inputs.visible { Color.black }
        } recovery: {
            EmptyView()
        }
    }

    private func probe(_ name: String) -> some View {
        Button(name) {}.frame(width: 44, height: 44).accessibilityIdentifier("probe.\(name)")
    }
}
#endif
