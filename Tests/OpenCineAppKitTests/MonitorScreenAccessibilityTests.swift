#if os(iOS)
import MonitorPresentation
import MonitorUI
import OpenCineAppKit
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
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        host.view.layoutIfNeeded()
        let exposed = Set(Self.accessibilityLeaves(host.view).compactMap(Self.identifier))
        // The anchor sits outside the screen: without it the walk found no tree at all
        // (simulator app accessibility off), and every "not exposed" check would pass.
        try XCTSkipUnless(exposed.contains("probe.anchor"), "No accessibility tree: enable app accessibility")
        return exposed
    }

    /// The VoiceOver walk: a container vends its elements, a view without them its subviews,
    /// and an element stops the walk. Hidden views and hidden element subtrees are skipped.
    private static func accessibilityLeaves(_ object: NSObject) -> [NSObject] {
        if object.accessibilityElementsHidden { return [] }
        if let view = object as? UIView, view.isHidden || view.alpha < 0.01 { return [] }
        if object.isAccessibilityElement { return [object] }
        // SwiftUI vends its nodes through `accessibilityElements`; `accessibilityElement(at:)`
        // answers nil for them.
        if let elements = object.accessibilityElements as? [NSObject], !elements.isEmpty {
            return elements.flatMap(accessibilityLeaves)
        }
        return ((object as? UIView)?.subviews ?? []).flatMap(accessibilityLeaves)
    }

    /// SwiftUI's nodes answer the selector without declaring `UIAccessibilityIdentification`.
    private static func identifier(_ object: NSObject) -> String? {
        let getter = NSSelectorFromString("accessibilityIdentifier")
        guard object.responds(to: getter),
            let id = object.perform(getter)?.takeUnretainedValue() as? String, id.hasPrefix("probe.")
        else { return nil }
        return id
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
                transientControlsHidden: inputs.transientControlsHidden)) {
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
