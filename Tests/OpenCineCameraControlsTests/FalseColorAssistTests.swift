#if os(iOS)
    import OpenCineCameraVocabulary
    import OpenCineMedia
    import XCTest

    @testable import OpenCineCameraControls

    /// Pins OpenZCine `falseColorRows` and `FalseColorReference` onto the shared assists.
    @MainActor
    final class FalseColorAssistTests: XCTestCase {
        /// This test's monitored source (XCTest makes a fresh one per test).
        private let ceiling = DeclaredMonitorColorFacts.makeCeiling()
        /// A camera with the D-Log family's official looks. These cases read the signal (LOG), where
        /// the look does not apply.
        private let looks = FalseColorLooks(
            scaleHelp: "", rec709LookCurve: { DeclaredMonitorColorFacts.lookCurves[$0] })

        func testScaleOptionsMatchOpenZCine() {
            XCTAssertEqual(FalseColorAssist.scaleOptions, ["CineStop", "Video", "IRE", "Limits"])
            XCTAssertEqual(FalseColorAssist.Options.default.scale, .sceneStops)
            XCTAssertTrue(FalseColorAssist.Options.default.referenceEnabled)
            XCTAssertEqual(FalseColorAssist.scale(forMenuLabel: "CineStop"), .sceneStops)
            XCTAssertEqual(FalseColorAssist.scale(forMenuLabel: "Video"), .stops)
            XCTAssertEqual(FalseColorAssist.scale(forMenuLabel: "PStops"), .stops)
            XCTAssertEqual(FalseColorAssist.scale(forMenuLabel: "ZC Stops"), .stops)
            XCTAssertEqual(FalseColorAssist.scale(forMenuLabel: "IRE"), .ire)
            XCTAssertEqual(FalseColorAssist.scale(forMenuLabel: "Limits"), .limits)
            XCTAssertEqual(FalseColorAssist.scale(forMenuLabel: "unknown"), .sceneStops)
            XCTAssertEqual(FalseColorAssist.menuLabel(for: .sceneStops), "CineStop")
            XCTAssertEqual(FalseColorAssist.menuLabel(for: .stops), "Video")
            XCTAssertEqual(FalseColorAssist.menuLabel(for: .ire), "IRE")
            XCTAssertEqual(FalseColorAssist.menuLabel(for: .limits), "Limits")
            // A saved "CineStop" predates the scene-stop scale: it keeps the Video scale.
            XCTAssertEqual(MonitorFalseColorSelection(rawValue: "CineStop"), .stops)
            XCTAssertEqual(MonitorFalseColorSelection(rawValue: "SceneStops"), .sceneStops)
            XCTAssertEqual(MonitorFrameEffects().falseColorScale, .sceneStops)
        }

        func testCineStopRulerPlacesZonesOnTheStopAxis() {
            let segments = FalseColorReference.segments(
                scale: .sceneStops, transfer: .dlog2, rec709: false,
                clipByte: ceiling.clipByte(transfer: .dlog2), looks: looks)
            XCTAssertEqual(
                segments.map(\.band.label),
                ["crush", "shadows", "−2", "−1", "18%", "+1", "+2", "highlights", "clip"])
            XCTAssertEqual(segments.first?.lowerFraction, 0)
            XCTAssertEqual(segments.last?.upperFraction, 1)
            for index in 0..<(segments.count - 1) {
                XCTAssertEqual(
                    segments[index].upperFraction, segments[index + 1].lowerFraction,
                    accuracy: 0.0001)
            }
            XCTAssertEqual(
                FalseColorReference.sceneStopMarkers(
                    transfer: .dlog2, rec709: false, clipByte: ceiling.clipByte(transfer: .dlog2),
                    looks: looks
                ).map(\.label),
                ["−6", "−4", "−2", "18%", "+2", "+4", "+6", "+8", "clip"],
                "D-Log2 at ISO 1600: +10 would collide with the +10.9 clip mark")
            XCTAssertEqual(
                FalseColorReference.sceneStopMarkers(
                    transfer: .rec709, rec709: false, clipByte: ceiling.clipByte(transfer: .rec709),
                    looks: looks
                ).map(\.label),
                ["−6", "−4", "−2", "18%", "clip"], "Rec.709 clips at +2.5")
            let labels = FalseColorReference.sceneStopMarkers(
                transfer: .dlog2, rec709: false, clipByte: ceiling.clipByte(transfer: .dlog2),
                looks: looks)
            for index in 0..<(labels.count - 1) {
                XCTAssertGreaterThan(
                    labels[index + 1].fraction - labels[index].fraction, 0.06, "labels never crowd")
            }
            let rec709Clip = FalseColorReference.sceneStopMarkers(
                transfer: .rec709, rec709: false, clipByte: ceiling.clipByte(transfer: .rec709),
                looks: looks
            ).last
            XCTAssertEqual(
                rec709Clip?.fraction ?? 0, 11.0 / 12, accuracy: 0.01,
                "the ruler ends one stop past this curve's clip")
            XCTAssertEqual(FalseColorReference.axisLabels(scale: .sceneStops), [])
        }

        func testReferenceOverlayMatchesOpenZCineChrome() {
            XCTAssertEqual(FalseColorReference.panelSize, CGSize(width: 264, height: 52))

            let ire = FalseColorReference.segments(
                scale: .ire, transfer: .dlog2, rec709: false,
                clipByte: ceiling.clipByte(transfer: .dlog2), looks: looks)
            XCTAssertEqual(ire.count, 6)
            XCTAssertEqual(ire[0].lowerFraction, 0, accuracy: 0.0001)
            XCTAssertEqual(ire[0].upperFraction, 0.025, accuracy: 0.0001)
            XCTAssertEqual(ire[2].lowerFraction, 0.38, accuracy: 0.0001)
            XCTAssertEqual(ire[2].upperFraction, 0.42, accuracy: 0.0001)
            XCTAssertEqual(ire[4].lowerFraction, 0.80, accuracy: 0.0001)
            XCTAssertEqual(ire[4].upperFraction, 0.95, accuracy: 0.0001)
            XCTAssertEqual(ire.last?.upperFraction, 1)
            XCTAssertLessThan(ire[1].upperFraction, ire[2].lowerFraction)

            let stops = FalseColorReference.segments(
                scale: .stops, transfer: .dlog2, rec709: false,
                clipByte: ceiling.clipByte(transfer: .dlog2), looks: looks)
            XCTAssertEqual(stops.count, 9)
            XCTAssertEqual(stops[0].lowerFraction, 0, accuracy: 0.0001)
            XCTAssertEqual(stops[0].upperFraction, 0.05, accuracy: 0.0001)
            XCTAssertEqual(stops[3].lowerFraction, 0.41, accuracy: 0.0001)
            XCTAssertEqual(stops[3].upperFraction, 0.49, accuracy: 0.0001)
            XCTAssertEqual(stops.last?.upperFraction, 1)
            XCTAssertLessThan(stops[2].upperFraction, stops[3].lowerFraction)

            XCTAssertEqual(
                FalseColorReference.axisLabels(scale: .ire),
                ["crush", "18%", "skin", "clip"])
            XCTAssertEqual(
                FalseColorReference.axisLabels(scale: .stops),
                ["crush", "18%", "skin", "clip"])
            XCTAssertEqual(
                FalseColorReference.axisLabels(scale: .limits),
                ["crushed", "midtones untouched", "clipped"])
            XCTAssertEqual(FalseColorReference.curveKeyLabel(.dlog2), "D-Log2")
            XCTAssertEqual(FalseColorReference.curveKeyLabel(.dlog), "D-Log")
            XCTAssertEqual(FalseColorReference.curveKeyLabel(.rec709), "709")
            XCTAssertEqual(FalseColorReference.curveKeyLabel(.hdr), "HLG")
            XCTAssertEqual(FalseColorReference.curveKeyLabel(.srgb), "sRGB")
            XCTAssertEqual(FalseColorReference.curveKeyLabel(.nlog), "N-Log")
            XCTAssertEqual(FalseColorReference.curveKeyLabel(.log3G10), "L3G10")

            let limits = FalseColorReference.segments(
                scale: .limits, transfer: .dlog2, rec709: false,
                clipByte: ceiling.clipByte(transfer: .dlog2), looks: looks)
            XCTAssertEqual(limits.count, 4)
            XCTAssertEqual(limits[0].lowerFraction, 0, accuracy: 0.0001)
            XCTAssertEqual(limits[0].upperFraction, 0.05, accuracy: 0.0001)
            XCTAssertEqual(limits[1].lowerFraction, 0.05, accuracy: 0.0001)
            XCTAssertEqual(limits[1].upperFraction, 0.10, accuracy: 0.0001)
            XCTAssertEqual(limits[2].lowerFraction, 0.94, accuracy: 0.0001)
            // Limits clip starts on the clip shelf every clip tool shares, not 99 IRE.
            let shelfIRE = ScopeDisplayScale.monitorPercent(
                LiveColorScience.clipShelf(ceiling: ceiling.clipEncoded(transfer: .dlog2)),
                transfer: .dlog2, clipByte: ceiling.clipByte(transfer: .dlog2))
            XCTAssertLessThan(shelfIRE, 99)
            XCTAssertEqual(limits[2].upperFraction, shelfIRE / 100, accuracy: 0.0001)
            XCTAssertEqual(limits[3].lowerFraction, shelfIRE / 100, accuracy: 0.0001)
            XCTAssertEqual(limits[3].upperFraction, 1, accuracy: 0.0001)

        }
    }
#endif
