#if os(iOS)
import MonitorPresentation
import MonitorUI
import OpenCineAppKit
import OpenCineHostedAccessibility
import OpenCineHostedTestSupport
import Observation
import SwiftUI
import XCTest

/// What VoiceOver can reach in each slot, read from the hosting view's accessibility
/// elements rather than XCUITest's inventory of mounted containers.
@MainActor
final class MonitorScreenAccessibilityTests: XCTestCase {
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
