#if os(iOS)
    import OpenCineCameraVocabulary
    import OpenCineMedia
    import XCTest

    @testable import OpenCineCameraControls

    /// Pins OpenZCine `AssistConfiguration.Zebra` units and thresholds (OperatorPreferences.swift).
    final class ZebraAssistTests: XCTestCase {
        /// This test's monitored source (XCTest makes a fresh one per test).
        private let ceiling = DeclaredMonitorColorFacts.makeCeiling()

        func testUnitEditorLabelsRoundTrip() {
            XCTAssertEqual(ZebraAssist.unitOptions, ZebraAssist.Unit.allCases.map(\.editorLabel))
            for unit in ZebraAssist.Unit.allCases {
                XCTAssertEqual(ZebraAssist.Unit.fromEditorLabel(unit.editorLabel), unit, "\(unit)")
            }
        }

        func testIREDisplayIsIdentity() {
            var options = ZebraAssist.Options.default
            options.unit = .ire
            XCTAssertEqual(
                options.displayValue(
                    for: 100, transfer: .dlog2, clipByte: ceiling.clipByte(transfer: .dlog2)), 100)
            XCTAssertEqual(
                options.displayValue(
                    for: 55, transfer: .dlog2, clipByte: ceiling.clipByte(transfer: .dlog2)), 55)
            options.setHighlight(
                fromDisplay: 88, transfer: .dlog2, clipByte: ceiling.clipByte(transfer: .dlog2))
            XCTAssertEqual(options.highlightIRE, 88)
            options.setMidtone(
                fromDisplay: 42, transfer: .rec709, clipByte: ceiling.clipByte(transfer: .rec709))
            XCTAssertEqual(options.midtoneIRE, 42)
            options.setHighlight(
                fromDisplay: 150, transfer: .dlog2, clipByte: ceiling.clipByte(transfer: .dlog2))
            XCTAssertEqual(options.highlightIRE, 100)
            options.setMidtone(
                fromDisplay: -4, transfer: .dlog2, clipByte: ceiling.clipByte(transfer: .dlog2))
            XCTAssertEqual(options.midtoneIRE, 0)
        }

        func testNativeDisplayUsesEncodedCode() {
            // Native display: IRE 100 → live-tap ceiling 247, IRE 0 → paper black 16.
            var options = ZebraAssist.Options.default
            options.unit = .native
            XCTAssertEqual(options.editorMaximum, 255)
            XCTAssertEqual(
                options.displayValue(
                    for: 100, transfer: .dlog2, clipByte: ceiling.clipByte(transfer: .dlog2)), 247)
            XCTAssertEqual(
                options.displayValue(
                    for: 0, transfer: .dlog2, clipByte: ceiling.clipByte(transfer: .dlog2)), 16)
            let midNative = Int(
                (ScopeDisplayScale.signalNative(
                    monitorPercent: 55, transfer: .dlog2,
                    clipByte: ceiling.clipByte(transfer: .dlog2))
                    * 255)
                    .rounded())
            XCTAssertEqual(
                options.displayValue(
                    for: 55, transfer: .dlog2, clipByte: ceiling.clipByte(transfer: .dlog2)),
                midNative)

            options.setHighlight(
                fromDisplay: 247, transfer: .dlog2, clipByte: ceiling.clipByte(transfer: .dlog2))
            XCTAssertEqual(options.highlightIRE, 100, accuracy: 0.01)
            options.setMidtone(
                fromDisplay: midNative, transfer: .dlog2,
                clipByte: ceiling.clipByte(transfer: .dlog2))
            XCTAssertEqual(options.midtoneIRE, 55, accuracy: 0.25)

            XCTAssertEqual(
                options.displayValue(
                    for: 100, transfer: .dlog, clipByte: ceiling.clipByte(transfer: .dlog)), 223)
            XCTAssertEqual(
                options.displayValue(
                    for: 0, transfer: .dlog, clipByte: ceiling.clipByte(transfer: .dlog)), 24)
            options.setHighlight(
                fromDisplay: 223, transfer: .dlog, clipByte: ceiling.clipByte(transfer: .dlog))
            XCTAssertEqual(options.highlightIRE, 100, accuracy: 0.01)
        }

        func testUnitDoesNotChangeOverlayThresholds() {
            var options = ZebraAssist.Options.default
            options.highlightIRE = 88
            options.midtoneIRE = 50
            let ireOverlay = ZebraAssist.overlay(from: options)
            options.unit = .native
            let nativeOverlay = ZebraAssist.overlay(from: options)
            XCTAssertEqual(ireOverlay.highlightIRE, nativeOverlay.highlightIRE)
            XCTAssertEqual(ireOverlay.midtoneIRE, nativeOverlay.midtoneIRE)
            XCTAssertEqual(ireOverlay.highlightIRE, 88)
            XCTAssertTrue(ireOverlay.highlightEnabled)
            XCTAssertTrue(ireOverlay.midtoneEnabled)
        }
    }
#endif
