#if os(iOS)
    import MonitorPresentation
    import MonitorUI
    import OpenCineAppKit
    import OpenCineCameraVocabulary
    import OpenCineMedia
    import SwiftUI
    import XCTest

    @testable import OpenCineCameraControls

    final class WaveformAssistTests: XCTestCase {
        /// This test's monitored source (XCTest makes a fresh one per test).
        /// A throwaway defaults domain, so a drag that saves never touches an app's settings.
        private static func scratchDefaults() -> UserDefaults {
            let name = "OpenCineCameraControlsTests.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: name)!
            defaults.removePersistentDomain(forName: name)
            return defaults
        }

        private let ceiling = DeclaredMonitorColorFacts.makeCeiling()

        func testWaveAxisMatchesTrafficLightIRE() {
            let black = LiveColorScience.encode(0, transfer: .dlog2)
            let grey = LiveColorScience.encode(0.18, transfer: .dlog2)
            XCTAssertEqual(
                MonitorWaveformAxis.unit(
                    black, transfer: .dlog2, clipByte: ceiling.clipByte(transfer: .dlog2)), 0,
                accuracy: 1e-9)
            XCTAssertEqual(
                MonitorWaveformAxis.unit(
                    grey, transfer: .dlog2, clipByte: ceiling.clipByte(transfer: .dlog2)),
                0.305, accuracy: 0.005,
                "D-Log2 18% gray stays at paper IRE 30.50, not remapped to 50")
            XCTAssertEqual(
                MonitorWaveformAxis.unit(
                    247.0 / 255, transfer: .dlog2, clipByte: ceiling.clipByte(transfer: .dlog2)), 1,
                accuracy: 1e-4)
            XCTAssertEqual(
                MonitorWaveformAxis.unit(
                    223.0 / 255, transfer: .dlog, clipByte: ceiling.clipByte(transfer: .dlog)), 1,
                accuracy: 1e-4)
            XCTAssertLessThan(
                MonitorWaveformAxis.unit(
                    188.0 / 255, transfer: .dlog2, clipByte: ceiling.clipByte(transfer: .dlog2)),
                0.90)
            XCTAssertEqual(
                MonitorWaveformAxis.unit(
                    1, transfer: .dlog2, clipByte: ceiling.clipByte(transfer: .dlog2)), 1,
                accuracy: 1e-9)
            XCTAssertEqual(
                MonitorWaveformAxis.unit(
                    0, transfer: .dlog2, clipByte: ceiling.clipByte(transfer: .dlog2)), 0,
                accuracy: 1e-9)
            XCTAssertEqual(
                MonitorWaveformAxis.middleGrayIRE(transfer: .dlog2), 30.50, accuracy: 0.05)
            XCTAssertEqual(
                MonitorWaveformAxis.middleGrayIRE(transfer: .dlog), 39.88, accuracy: 0.05)
            let dlogBlack = LiveColorScience.encode(0, transfer: .dlog)
            let dlogGrey = LiveColorScience.encode(0.18, transfer: .dlog)
            XCTAssertEqual(
                MonitorWaveformAxis.unit(
                    dlogBlack, transfer: .dlog, clipByte: ceiling.clipByte(transfer: .dlog)), 0,
                accuracy: 1e-9)
            XCTAssertEqual(
                MonitorWaveformAxis.unit(
                    dlogGrey, transfer: .dlog, clipByte: ceiling.clipByte(transfer: .dlog)), 0.3988,
                accuracy: 0.005)
        }

        func testHoldWithoutDragOpensOptions() {
            XCTAssertTrue(WaveformAssist.shouldPresentOptions(translation: .zero))
            XCTAssertTrue(
                WaveformAssist.shouldPresentOptions(translation: CGSize(width: 3, height: -2)))
            XCTAssertFalse(
                WaveformAssist.shouldPresentOptions(translation: CGSize(width: 20, height: 0)))
        }

        func testSafeBordersAreDottedFiveAndNinetyFive() {
            let on = MonitorWaveformAxis.guideStrokes(
                clip: true, crush: true, middle: true, transfer: .dlog2)
            XCTAssertEqual(on.count, 5)
            XCTAssertEqual(on[0].ire, 0, accuracy: 0.01)
            XCTAssertEqual(on[1].ire, 100, accuracy: 0.01)
            XCTAssertEqual(on[2].ire, 5, accuracy: 0.01)
            XCTAssertEqual(on[3].ire, 95, accuracy: 0.01)
            XCTAssertEqual(on[4].ire, 30.50, accuracy: 0.05)
            XCTAssertFalse(on[0].dashed || on[0].usesCrushClipColor, "0 is the solid min line")
            XCTAssertFalse(on[1].dashed || on[1].usesCrushClipColor, "100 is the solid max line")
            XCTAssertTrue(on[2].dashed && on[2].usesCrushClipColor, "5 is the dotted crush buffer")
            XCTAssertTrue(on[3].dashed && on[3].usesCrushClipColor, "95 is the dotted clip buffer")
            XCTAssertFalse(
                on[4].dashed || on[4].usesCrushClipColor, "gray is a solid paper-IRE line")
            XCTAssertEqual(MonitorWaveformAxis.crushClipDash, [3, 3])
            let off = MonitorWaveformAxis.guideStrokes(
                clip: false, crush: false, middle: false, transfer: .dlog2)
            XCTAssertEqual(off.map(\.ire), [0, 100])
            let dlog = MonitorWaveformAxis.guideStrokes(
                clip: false, crush: false, middle: true, transfer: .dlog)
            XCTAssertEqual(dlog.last?.ire ?? 0, 39.88, accuracy: 0.05)
        }

        func testISOMovesClipOnly() {
            let grey = LiveColorScience.encode(0.18, transfer: .dlog2)
            let black = LiveColorScience.encode(0, transfer: .dlog2)
            let at1600 = MonitorWaveformAxis.unit(
                grey, transfer: .dlog2, clipByte: ceiling.clipByte(transfer: .dlog2, iso: 1600))
            let at400 = MonitorWaveformAxis.unit(
                grey, transfer: .dlog2, clipByte: ceiling.clipByte(transfer: .dlog2, iso: 400))
            XCTAssertEqual(at1600, 0.305, accuracy: 0.005)
            XCTAssertEqual(at400, 0.305, accuracy: 0.005)
            XCTAssertEqual(
                MonitorWaveformAxis.unit(
                    black, transfer: .dlog2, clipByte: ceiling.clipByte(transfer: .dlog2, iso: 400)),
                0,
                accuracy: 1e-9)
            let clip1600 = ceiling.clipEncoded(transfer: .dlog2, iso: 1600)
            let clip400 = ceiling.clipEncoded(transfer: .dlog2, iso: 400)
            XCTAssertEqual(
                MonitorWaveformAxis.unit(
                    clip1600, transfer: .dlog2,
                    clipByte: ceiling.clipByte(transfer: .dlog2, iso: 1600)),
                1, accuracy: 1e-9)
            XCTAssertEqual(
                MonitorWaveformAxis.unit(
                    clip400, transfer: .dlog2,
                    clipByte: ceiling.clipByte(transfer: .dlog2, iso: 400)),
                1, accuracy: 1e-9)
            XCTAssertLessThan(clip400, clip1600, "lower EI pulls 100 down; gray stays at paper IRE")
        }

        @MainActor
        func testOrientationCentresStayIndependent() {
            let landscape = CGRect(x: 0, y: 0, width: 874, height: 402)
            let portrait = CGRect(x: 0, y: 0, width: 402, height: 874)
            XCTAssertEqual(MonitorScopeCanvasSlot.forBounds(landscape), .landscape)
            XCTAssertEqual(MonitorScopeCanvasSlot.forBounds(portrait), .portrait)

            let store = MonitorScopePanelStore<MonitorWaveformOptions>(
                options: .default, storage: Self.scratchDefaults(), key: "waveform")
            store.beginDrag(center: CGPoint(x: 120, y: 80), in: landscape)
            store.endDrag(bounds: landscape)
            store.beginDrag(center: CGPoint(x: 200, y: 400), in: portrait)
            store.endDrag(bounds: portrait)

            let land = store.storedCenter(in: landscape)?.center(in: landscape)
            let port = store.storedCenter(in: portrait)?.center(in: portrait)
            XCTAssertEqual(land?.x ?? 0, 120, accuracy: 0.5)
            XCTAssertEqual(land?.y ?? 0, 80, accuracy: 0.5)
            XCTAssertEqual(port?.x ?? 0, 200, accuracy: 0.5)
            XCTAssertEqual(port?.y ?? 0, 400, accuracy: 0.5)
            XCTAssertNotEqual(store.options.storedCenter, store.options.storedCenterPortrait)
        }

        func testLegacyStoredCenterStaysLandscapeOnly() throws {
            let data = Data(#"{"storedCenter":{"xFraction":0.25,"yFraction":0.4}}"#.utf8)
            let decoded = try JSONDecoder().decode(WaveformAssist.Options.self, from: data)
            XCTAssertEqual(decoded.storedCenter?.xFraction ?? 0, 0.25, accuracy: 0.001)
            XCTAssertEqual(decoded.storedCenter?.yFraction ?? 0, 0.4, accuracy: 0.001)
            XCTAssertNil(decoded.storedCenterPortrait)
        }
        @MainActor
        func testRetiredDragLeavesOtherOrientationAndSavedCoordinatesUntouched() {
            let landscape = CGRect(x: 0, y: 0, width: 874, height: 402)
            let portrait = CGRect(x: 0, y: 0, width: 402, height: 874)
            let options = WaveformAssist.Options(
                storedCenter:
                    MonitorScopeStoredCenter(center: CGPoint(x: 120, y: 80), in: landscape))
            let store = MonitorScopePanelStore<MonitorWaveformOptions>(
                options: options, storage: Self.scratchDefaults(), key: "waveform")
            store.beginDrag(center: CGPoint(x: 300, y: 200), in: landscape)
            store.beginDrag(center: CGPoint(x: 200, y: 400), in: portrait)
            store.cancelDrag(bounds: landscape)
            store.endDrag(bounds: landscape)
            XCTAssertNil(store.sessionCenter(in: landscape))
            XCTAssertEqual(store.sessionCenter(in: portrait), CGPoint(x: 200, y: 400))
            XCTAssertEqual(
                store.options, options, "A late release cannot save the retired orientation")
        }

    }
#endif
