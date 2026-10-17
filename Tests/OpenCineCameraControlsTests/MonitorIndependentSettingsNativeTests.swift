#if os(iOS)
    import Observation
    import OpenCineCameraControls
    import OpenCineHostedAccessibility
    import SwiftUI
    import UIKit
    import XCTest

    /// SIMULATED host values and callbacks exercise the actual shared panel's native buttons.
    @MainActor
    final class MonitorIndependentSettingsNativeTests: XCTestCase {
        func testOpeningClosingAndReorderingNeverSelects() async throws {
            let fixture = await IndependentPanelFixture()
            defer { fixture.close() }
            let first = try await fixture.option("first", 0)
            let second = try await fixture.option("second", 1)
            XCTAssertFalse(
                first.accessibilityTraits.contains(.selected), "Unknown must remain unselected")
            XCTAssertTrue(second.accessibilityTraits.contains(.selected))
            let initialTitles = try await fixture.titles()
            XCTAssertEqual(initialTitles, ["First", "Second"])
            fixture.probe.reversed = true
            let reorderedTitles = try await fixture.titles()
            XCTAssertEqual(reorderedTitles, ["Second", "First"])
            fixture.probe.visible = false
            await fixture.waitUntilClosed()
            XCTAssertTrue(fixture.probe.requests.isEmpty)
            XCTAssertTrue(fixture.probe.refusals.isEmpty)
        }

        func testSelectionSendsOnlyTheTappedRowAndExactOptionOnce() async throws {
            let fixture = await IndependentPanelFixture()
            defer { fixture.close() }
            let first = try await fixture.option("first", 1)
            XCTAssertTrue(first.accessibilityActivate())
            await fixture.settle()
            XCTAssertEqual(fixture.probe.requests, [.first])
            XCTAssertEqual(fixture.probe.options, [" On "])
            let second = try await fixture.option("second", 0)
            XCTAssertTrue(second.accessibilityActivate())
            await fixture.settle()
            XCTAssertEqual(fixture.probe.requests, [.first, .second])
            XCTAssertEqual(fixture.probe.options, [" On ", "off"])
            let unchanged = try await fixture.option("first", 1)
            XCTAssertFalse(
                unchanged.accessibilityTraits.contains(.selected),
                "Sending a request must not invent an observed current")
        }

        func testUnavailableRowReportsItsHostReasonWithoutSending() async throws {
            let fixture = await IndependentPanelFixture()
            defer { fixture.close() }
            fixture.probe.secondAvailable = false
            _ = try await fixture.element("monitor.independentSettings.second.reason")
            let unavailable = try await fixture.option("second", 1)
            XCTAssertTrue(unavailable.accessibilityActivate())
            await fixture.settle()
            XCTAssertTrue(fixture.probe.requests.isEmpty)
            XCTAssertEqual(fixture.probe.refusals, ["second"])
            XCTAssertEqual(fixture.probe.reasons, ["Host refusal"])
        }

        func testInteractionAndCurrentSourceRefuseNativeActions() async throws {
            let fixture = await IndependentPanelFixture()
            defer { fixture.close() }
            let mounted = try await fixture.option("first", 1)
            fixture.probe.sourceCurrent = false
            _ = mounted.accessibilityActivate()
            await fixture.settle()
            XCTAssertTrue(fixture.probe.requests.isEmpty)
            fixture.probe.sourceCurrent = true
            fixture.probe.enabled = false
            let disabled = try await fixture.element("monitor.independentSettings.first.option.1") {
                $0.accessibilityTraits.contains(.notEnabled)
            }
            XCTAssertTrue(disabled.accessibilityTraits.contains(.notEnabled))
            _ = disabled.accessibilityActivate()
            await fixture.settle()
            XCTAssertTrue(fixture.probe.requests.isEmpty)
            XCTAssertTrue(fixture.probe.refusals.isEmpty)
        }
    }

    private enum IndependentPanelTarget { case first, second }

    @MainActor @Observable
    private final class IndependentPanelProbe {
        var reversed = false
        var visible = true
        var enabled = true
        var secondAvailable = true
        var sourceCurrent = true
        var requests: [IndependentPanelTarget] = []
        var options: [String] = []
        var refusals: [String] = []
        var reasons: [String?] = []

        var rows: [IndependentSettingRow<String, IndependentPanelTarget>] {
            let first = IndependentSettingRow(
                id: "first", title: "First", options: ["off", " On "],
                current: nil, request: IndependentPanelTarget.first, unavailableReason: nil)
            let second = IndependentSettingRow(
                id: "second", title: "Second", options: ["off", "on"],
                current: "on", request: secondAvailable ? IndependentPanelTarget.second : nil,
                unavailableReason: secondAvailable ? nil : "Host refusal")
            return reversed ? [second, first] : [first, second]
        }
    }

    @MainActor
    private struct IndependentPanelCanvas: View {
        let probe: IndependentPanelProbe
        var body: some View {
            if probe.visible {
                MonitorIndependentSettingsPanel(
                    rows: probe.rows, interactionEnabled: probe.enabled,
                    currentSource: { probe.sourceCurrent },
                    onSelect: {
                        probe.requests.append($0)
                        probe.options.append($1)
                    },
                    onUnavailable: {
                        probe.refusals.append($0)
                        probe.reasons.append($1)
                    }
                )
                .frame(width: 390)
            }
        }
    }

    @MainActor
    private final class IndependentPanelFixture {
        let probe = IndependentPanelProbe()
        let window: UIWindow
        let host: UIHostingController<IndependentPanelCanvas>

        init() async {
            _ = await HostedAccessibility.awaitRuntime()
            host = UIHostingController(rootView: IndependentPanelCanvas(probe: probe))
            window = UIWindow(frame: CGRect(x: 0, y: 0, width: 420, height: 600))
            window.rootViewController = host
            window.makeKeyAndVisible()
            host.view.frame = window.bounds
        }

        func close() {
            window.isHidden = true
            window.rootViewController = nil
        }

        func settle() async {
            for _ in 0..<40 {
                host.view.layoutIfNeeded()
                await Task.yield()
            }
        }

        func option(_ row: String, _ index: Int) async throws -> NSObject {
            try await element("monitor.independentSettings.\(row).option.\(index)")
        }

        func element(_ id: String, matching matches: (NSObject) -> Bool = { _ in true })
            async throws -> NSObject
        {
            for _ in 0..<200 {
                host.view.layoutIfNeeded()
                if let element = HostedAccessibility.reachable(in: host.view).first(where: {
                    HostedAccessibility.identifier($0) == id && matches($0)
                }) {
                    return element
                }
                await Task.yield()
            }
            throw XCTUnwrapError.missing(id)
        }

        func waitUntilClosed() async {
            for _ in 0..<200 {
                host.view.layoutIfNeeded()
                if !HostedAccessibility.reachable(in: host.view).contains(where: {
                    HostedAccessibility.identifier($0)
                        == "monitor.independentSettings.first.option.0"
                }) {
                    return
                }
                await Task.yield()
            }
            XCTFail("Closing must unmount the actual panel before checking its callbacks")
        }

        func titles() async throws -> [String] {
            let expected = probe.reversed ? ["Second", "First"] : ["First", "Second"]
            for _ in 0..<200 {
                host.view.layoutIfNeeded()
                let labels = HostedAccessibility.reachable(in: host.view).filter {
                    HostedAccessibility.identifier($0)?.hasSuffix(".title") == true
                }.compactMap(\.accessibilityLabel)
                if labels == expected { return labels }
                await Task.yield()
            }
            XCTFail("The actual row titles must follow host order")
            return []
        }

        private enum XCTUnwrapError: Error { case missing(String) }
    }
#endif
