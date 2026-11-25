#if os(iOS)
import MonitorPresentation
import XCTest

@testable import OpenCineAppKit

/// The scroll wheel in a Mac window changes only the setting the pointer rests on, as hover finds
/// it (hover follows what is on top, so a panel or dialog over the strip takes the pointer), and
/// only one whose hold opens a drum. With a camera panel open, only that panel's setting takes the
/// wheel, over the panel or its readout (spec 2026-11-25-desktop-mac-sized-ui-and-scroll-dials-design.md).
@MainActor
final class MonitorCaptureWheelTargetTests: XCTestCase {
    private typealias Inputs = MonitorOperatorCaptureInputs<String, String, String>

    private func inputs(panel: String? = nil, admitted: Bool = true) -> Inputs {
        let readouts: [MonitorOperatorLiveReadout<String, String>] = [
            .init(id: "iso", title: "ISO", value: "100"),
            .init(id: "shutter", title: "SHUTTER", value: "1/50"),
            .init(id: "info", title: "INFO", value: "--", quickEnabled: false),
            .init(id: "toggle", title: "METER", value: "Face", action: {}),
        ]
        return Inputs(readouts: readouts, panel: panel.map { .init(key: $0, chrome: .content) },
            open: { _ in }, dismiss: {},
            nativeQuick: { key in
                guard ["iso", "shutter", "toggle"].contains(key) else { return nil }
                return .init(identity: key,
                    snapshot: .init(title: key, options: ["a", "b", "c"], selection: "a"), enabled: true)
            },
            nativeCurrent: { _, _ in true }, nativeCommit: { _, _, _ in },
            commitAdmission: { admitted })
    }

    private func target(_ inputs: Inputs, _ state: MonitorOperatorCaptureState<String, String>,
        enabled: Bool = true, commandEnabled: Bool = true) -> String? {
        inputs.wheelTarget(state: state, enabled: enabled, commandEnabled: commandEnabled, currentSource: { true })
    }

    func testOnlyTheHoveredDialSettingTakesTheWheel() {
        let state = MonitorOperatorCaptureState<String, String>()
        XCTAssertNil(target(inputs(), state))
        state.wheelHover = "iso"
        XCTAssertEqual(target(inputs(), state), "iso")
        // No drum, or a readout that runs its own action: never the wheel.
        state.wheelHover = "info"
        XCTAssertNil(target(inputs(), state))
        state.wheelHover = "toggle"
        XCTAssertNil(target(inputs(), state))
        // Not admitted: the monitor is covered, read-only or disabled.
        state.wheelHover = "iso"
        XCTAssertNil(target(inputs(admitted: false), state))
        XCTAssertNil(target(inputs(), state, enabled: false))
        XCTAssertNil(target(inputs(), state, commandEnabled: false))
        // A readout's own hold owns the pointer.
        let owner = UUID()
        XCTAssertNotNil(state.ownership.acquire(owner))
        XCTAssertNil(target(inputs(), state))
    }

    func testAnOpenPanelTakesTheWheelOnlyForItsOwnSetting() {
        let state = MonitorOperatorCaptureState<String, String>()
        let open = inputs(panel: "iso", admitted: false)
        state.wheelHover = "shutter"
        XCTAssertNil(target(open, state))
        state.pointerOnPanel = true
        XCTAssertEqual(target(open, state), "iso")
        state.pointerOnPanel = false
        state.wheelHover = "iso"
        XCTAssertEqual(target(open, state), "iso")
        // A panel whose setting has no drum (format, colour) takes no wheel.
        state.pointerOnPanel = true
        XCTAssertNil(target(inputs(panel: "info", admitted: false), state))
    }
}
#endif
