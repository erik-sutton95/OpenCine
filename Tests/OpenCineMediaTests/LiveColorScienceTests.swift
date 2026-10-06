import Testing

@testable import OpenCineMedia

/// Pure transfer, scope and false-colour math. Ceilings are explicit inputs: the values
/// below are the reference live-tap ceilings an integration measured (8-bit tap: D-Log2 247
/// at EI 1600, D-Log 223 at its native EI, 255 for curves without a measured ceiling).
/// Moved from OpenPocketCine `LiveColorScienceTests` with the global ceiling made explicit.
@Suite struct LiveColorScienceTests {
    private let transfers = MonitorTransfer.allCases

    private func clip(_ transfer: MonitorTransfer) -> Int {
        switch transfer {
        case .dlog2: 247
        case .dlog: 223
        case .rec709, .hdr, .dlogm, .ilog, .srgb, .nlog, .log3G10: 255
        }
    }

    private func anchors(_ transfer: MonitorTransfer) -> ScopeAnchors {
        ScopeAnchors.make(transfer: transfer, clipByte: clip(transfer))
    }

    private func level(_ c: Double, _ transfer: MonitorTransfer) -> Double {
        ScopeDisplayScale.waveformLevel(c, transfer: transfer, clipByte: clip(transfer))
    }

    private func percent(_ c: Double, _ transfer: MonitorTransfer) -> Double {
        ScopeDisplayScale.monitorPercent(c, transfer: transfer, clipByte: clip(transfer))
    }

    private func native(_ percent: Double, _ transfer: MonitorTransfer) -> Double {
        ScopeDisplayScale.signalNative(
            monitorPercent: percent, transfer: transfer, clipByte: clip(transfer))
    }

    private func lights(
        red: [Int], green: [Int], blue: [Int], luma: [Int]? = nil, transfer: MonitorTransfer,
        threshold: Double = ScopeTrafficLights.defaultThreshold,
        previous: ScopeTrafficLightsReading? = nil
    ) -> ScopeTrafficLightsReading {
        ScopeTrafficLights.reading(
            red: red, green: green, blue: blue, luma: luma, transfer: transfer,
            clipByte: clip(transfer), threshold: threshold, previous: previous)
    }

    // MARK: - D-Log M

    @Test func dLogMScopesPreserveSignal() {
        let transfer = MonitorTransfer.dlogm
        for byte in 0...255 {
            let signal = Double(byte) / 255
            #expect(abs(percent(signal, transfer) - signal * 100) < 1e-8)
        }
    }

    @Test func dLogMReferenceStopsAndSignalWarningsStaySeparate() {
        let transfer = MonitorTransfer.dlogm
        #expect(abs(LiveColorScience.encode(0.18, transfer: transfer) - 0.40000007) < 1e-7)
        #expect(abs(LiveColorScience.encode(0.72, transfer: transfer) - 0.698565282656276) < 1e-6)
        #expect(abs(LiveColorScience.stops(encoded: 0.698565282656276, transfer: transfer) - 2) < 1e-5)
        #expect(percent(0.9, transfer) < LiveZebra.highlightIRE)
        #expect(percent(0.05, transfer) > 4.99)
    }

    // MARK: - Transfer functions (paper anchors)

    @Test func roundTripGreyBlackPeak() {
        // D-Log's published constants are rounded (3.89616 ≈ 1/0.256663), so the
        // curve inverts to ~1e-5 relative, not machine precision.
        for transfer in transfers {
            for linear in [0.0, 0.18, transfer.peakLinear] {
                let encoded = LiveColorScience.encode(linear, transfer: transfer)
                let back = LiveColorScience.linearize(encoded, transfer: transfer)
                #expect(
                    abs(back - linear) <= max(1e-6, linear * 1e-4),
                    "\(transfer) round trip at \(linear)")
            }
        }
    }

    @Test func dLog2PaperAnchors() {
        // Gamut white paper Rev 1.0 (2026-06-30) curve table, 1e-6 or table precision.
        let e = { LiveColorScience.encode($0, transfer: .dlog2) }
        #expect(abs(e(0) - 0.062561) < 1e-6)
        #expect(abs(e(0.0289617) - 0.148315) < 1e-5)
        #expect(abs(e(0.18) - 0.304985337243402) < 1e-12)
        #expect(abs(e(0.9) - 0.445264) < 1e-6)
        #expect(abs(e(1.0) - 0.454539) < 1e-6)
        #expect(abs(e(18) - 0.710090) < 1e-6)
        #expect(abs(e(475) - 1.0) < 1e-9)
        // 10-bit full-range code table from the paper.
        for (linear, code) in [
            (0.0, 64.0), (0.18, 312.0), (1.0, 465.0), (18.0, 726.0), (475.0, 1023.0),
        ] {
            #expect(abs(e(linear) * 1023 - code) < 0.5, "code for linear \(linear)")
        }
        #expect(MonitorTransfer.dlog2.peakLinear == 475.0)
    }

    @Test func dLogWhitePaperAnchors() {
        // DJI 2017 white paper: 0% → 95, 18% → 408, 90% → 586 (of 1023); peak 4200%.
        let e = { LiveColorScience.encode($0, transfer: .dlog) }
        #expect(abs(e(0) * 1023 - 95.0) < 0.5)
        #expect(abs(e(0.18) * 1023 - 408.0) < 0.5)
        #expect(abs(e(0.9) * 1023 - 586.0) < 0.5)
        #expect(abs(e(42.0) - 1.0) < 1e-5)
        #expect(MonitorTransfer.dlog.peakLinear == 42.0)
    }

    @Test func hlgFollowsBT2408() {
        #expect(abs(LiveColorScience.encode(1.0, transfer: .hdr) - 0.75) < 1e-6)
        #expect(abs(LiveColorScience.encode(0.18, transfer: .hdr) - 0.378) < 1e-3)
    }

    @Test func rec709EighteenPercent() {
        #expect(abs(LiveColorScience.encode(0.18, transfer: .rec709) - 0.409) < 1e-3)
        #expect(LiveColorScience.encode(0, transfer: .rec709) == 0)
        #expect(abs(LiveColorScience.encode(1, transfer: .rec709) - 1) < 1e-9)
    }

    // MARK: - Anchors (curve-fraction axis; the tap expands the legal-range wire)

    @Test func anchorsAreCurveFractions() {
        let cases: [(MonitorTransfer, Double, Double)] = [
            (.dlog2, 15.95, 77.77),
            (.dlog, 23.69, 101.68),
            (.rec709, 0.00, 104.30),
            (.hdr, 0.00, 96.46),
        ]
        for (transfer, black8, mid8) in cases {
            let a = anchors(transfer)
            #expect(abs(a.black * 255 - black8) < 0.05, "\(transfer) black")
            #expect(abs(a.mid * 255 - mid8) < 0.05, "\(transfer) mid")
            if transfer == .rec709 || transfer == .hdr {
                #expect(a.clip == 1.0, "\(transfer) preview peak is encoded 1.0")
            } else {
                #expect(a.clipEdgeByte == clip(transfer), "\(transfer) clip is the live ceiling")
                #expect(a.clip < 1.0, "\(transfer) must not stretch 255 to 100")
            }
        }
        #expect(abs(MonitorTransfer.dlog2.middleGrayEncoded - 0.304985337243402) < 1e-12)
        #expect(abs(MonitorTransfer.dlog2.middleGrayPaperIRE - 30.50) < 0.01)
    }

    // MARK: - Anchored scope axis (OpenZCine ScopeDisplayScale semantics)

    @Test func waveformLevelPinsAnchors() {
        for transfer in transfers {
            let a = anchors(transfer)
            #expect(abs(level(a.black, transfer) - 0.05) < 1e-12, "\(transfer) black on the 0 line")
            #expect(abs(level(a.clip, transfer) - 0.95) < 1e-12, "\(transfer) clip on the 100 line")
            #expect(abs(level(a.mid, transfer) - a.midLevel) < 1e-12, "\(transfer) grey pinned")
            // Log toes keep a live sub-black margin; zero-black transfers sit on the line.
            let zero = level(0, transfer)
            #expect(a.black > 0 ? zero == 0 : zero == 0.05, "\(transfer) at code 0")
        }
    }

    @Test func waveformLevelStrictlyIncreasing() {
        for transfer in transfers {
            var previous = -1.0
            for code in 0...255 {
                let value = level(Double(code) / 255, transfer)
                #expect(value > previous, "\(transfer) flat/reversed at code \(code)")
                previous = value
            }
        }
    }

    @Test func midLevelsMatchPaperIRE() {
        // 18% is pinned at published paper IRE (encoded × 100), not
        // (mid−black)/(clip−black) which would move with the ceiling.
        let expected: [(MonitorTransfer, Double)] = [
            (.dlog2, 30.50),
            (.dlog, 39.88),
            (.rec709, 40.90),
            (.hdr, 37.83),
        ]
        for (transfer, greyIRE) in expected {
            let a = anchors(transfer)
            #expect(
                abs(a.midLevel - ScopeDisplayScale.level(scaleIRE: greyIRE)) < 1e-3,
                "\(transfer) midLevel")
            #expect(abs(LiveColorScience.paperIRE(a.mid) - greyIRE) < 0.05)
        }
    }

    @Test func monitorPercentContract() {
        for transfer in transfers {
            let a = anchors(transfer)
            #expect(percent(a.black, transfer) == 0)
            #expect(abs(percent(a.clip, transfer) - 100) < 1e-9)
            #expect(percent(0, transfer) == 0, "clamps below")
            #expect(percent(1, transfer) == 100, "clamps above")
            // signalNative inverts it.
            for value in [0.0, 2, 55, 100] {
                #expect(abs(percent(native(value, transfer), transfer) - value) < 1e-9)
            }
        }
    }

    @Test func levelTableMatchesReference() {
        for transfer in transfers {
            let table = ScopeDisplayScale.levelTable(for: transfer, clipByte: clip(transfer))
            #expect(table.count == 256)
            for code in stride(from: 0, through: 255, by: 5) {
                #expect(abs(Double(table[code]) - level(Double(code) / 255, transfer)) < 1e-6)
            }
        }
    }

    @Test func histogramRemapConservesAndAnchors() {
        var bins = [Int](repeating: 0, count: 256)
        bins[5] = 15  // sub-black noise
        bins[16] = 100  // D-Log2 paper black
        bins[78] = 50  // 18% grey
        bins[247] = 25  // live-tap EI ceiling
        bins[255] = 10  // above the ceiling: margin, not the 100 line
        let out = ScopeDisplayScale.remapHistogram(bins, transfer: .dlog2, clipByte: 247)
        #expect(out.reduce(0, +) == 200, "conserves total count")
        // Paper black lands on the scale-0 bucket (level 0.05 → 12/13).
        #expect(out[12] + out[13] >= 100)
        // Live-tap ceiling lands on the scale-100 bucket (level 0.95 → 242).
        #expect(out[242] == 25)
        // Code 255 is overshoot, not stretched onto 100.
        #expect(out[255] == 10)
        let subBlack = out[0...11].reduce(0, +)
        #expect(subBlack == 15)

        var dlogBins = [Int](repeating: 0, count: 256)
        dlogBins[18] = 15  // sub-black
        dlogBins[24] = 100  // D-Log paper black
        dlogBins[102] = 50  // 18% grey
        dlogBins[223] = 25  // live-tap ceiling
        dlogBins[255] = 10  // leak: margin, not the 100 line
        let dlogOut = ScopeDisplayScale.remapHistogram(dlogBins, transfer: .dlog, clipByte: 223)
        #expect(dlogOut.reduce(0, +) == 200)
        #expect(dlogOut[242] == 25, "D-Log 223 is the 100 line")
        #expect(dlogOut[255] == 10, "D-Log code 255 is overshoot")
    }

    @Test func liveClipCeilingIsThe100Line() {
        // 255 is not the 100 line. 188 is below the 100 line (the early-zebra bug).
        #expect(level(1, .dlog2) > ScopeDisplayScale.clipLevel + 0.01)
        #expect(abs(level(247.0 / 255, .dlog2) - ScopeDisplayScale.clipLevel) < 1e-9)
        #expect(abs(level(223.0 / 255, .dlog) - ScopeDisplayScale.clipLevel) < 1e-9)
        #expect(level(188.0 / 255, .dlog2) < ScopeDisplayScale.clipLevel - 0.05)
    }

    /// Two sources with different ceilings (or one source before and after its ceiling
    /// moves) read through the same shared math without affecting each other.
    @Test func twoCeilingsStayIndependent() {
        let a = ScopeDisplayScale.levelTable(for: .dlog2, clipByte: 247)
        let b = ScopeDisplayScale.levelTable(for: .dlog2, clipByte: 231)
        #expect(a != b)
        #expect(ScopeDisplayScale.levelTable(for: .dlog2, clipByte: 247) == a)
        #expect(abs(Double(b[231]) - ScopeDisplayScale.clipLevel) < 1e-6)
        #expect(abs(Double(a[247]) - ScopeDisplayScale.clipLevel) < 1e-6)
        var bins = [Int](repeating: 0, count: 256)
        bins[240] = 1000
        #expect(
            ScopeTrafficLights.reading(
                red: bins, green: bins, blue: bins, transfer: .dlog2, clipByte: 247
            ).anyClip, "240 is on the 247 ceiling's clip shelf")
        #expect(
            !ScopeTrafficLights.reading(
                red: bins, green: bins, blue: bins, transfer: .dlog2, clipByte: 254
            ).anyClip, "a brighter source's ceiling does not clip 240")
    }

    // MARK: - Traffic lights

    @Test func trafficEdgesFollowTheAnchors() {
        for transfer in transfers {
            let a = anchors(transfer)
            #expect(a.clipEdgeByte == clip(transfer), "\(transfer) clip edge")
            #expect(
                a.crushFloorByte == Int((a.black * 255).rounded(.down)), "\(transfer) crush floor")
            #expect(a.crushEdgeByte >= a.crushFloorByte, "\(transfer) crush edge")
        }
        let dlog2 = anchors(.dlog2)
        #expect(dlog2.clipFloorByte == 240, "the clip shelf under the 247 ceiling, not WAVE 95")
        #expect(dlog2.clipFloorByte > 188, "188 stays recoverable, not a clip lamp")
        let dlog = anchors(.dlog)
        #expect(dlog.clipFloorByte <= 219)
        #expect(dlog.clipFloorByte < dlog.clipEdgeByte)
    }

    private func histogram(spikeAt code: Int, count: Int = 1000) -> [Int] {
        var bins = [Int](repeating: 0, count: 256)
        bins[code] = count
        return bins
    }

    @Test func subBlackNoiseDoesNotCrush() {
        // Below the toe floor is sensor noise under true black, not crushed picture.
        let cases: [(MonitorTransfer, Int)] = [(.dlog2, 10), (.dlog, 18)]
        for (transfer, code) in cases {
            let bins = histogram(spikeAt: code)
            let reading = lights(red: bins, green: bins, blue: bins, transfer: transfer)
            #expect(!reading.anyCrush, "\(transfer) sub-black")
            #expect(!reading.anyClip)
        }
    }

    @Test func toePileUpCrushes() {
        for transfer in transfers {
            let floor = anchors(transfer).crushFloorByte
            let bins = histogram(spikeAt: floor + 1)
            let reading = lights(red: bins, green: bins, blue: bins, transfer: transfer)
            #expect(reading.anyCrush, "\(transfer) toe pile-up")
            #expect(!reading.anyClip)
        }
    }

    @Test func curveTopClips() {
        for transfer in transfers {
            let bins = histogram(spikeAt: 255)
            let reading = lights(red: bins, green: bins, blue: bins, transfer: transfer)
            #expect(reading.anyClip, "\(transfer) clip at the curve top")
            #expect(!reading.anyCrush)
        }
    }

    @Test func recoverableDLog2HighlightDoesNotClipLights() {
        let bins = histogram(spikeAt: 188)
        #expect(
            !lights(red: bins, green: bins, blue: bins, transfer: .dlog2).anyClip,
            "byte 188 is below the measured 247 ceiling")
        let shelf = histogram(spikeAt: 243)
        #expect(
            lights(red: shelf, green: shelf, blue: shelf, transfer: .dlog2).anyClip,
            "live-tap shelf 243–247 must light the clip lamps")
        // Journal maxRGB is 243–246 while BT.2020 luma of that door sits ~240: the
        // channels on the shelf light every lamp even though luma is under it.
        let door = histogram(spikeAt: 244)
        let doorReading = lights(
            red: door, green: door, blue: door, luma: histogram(spikeAt: 240), transfer: .dlog2)
        #expect(doorReading.anyClip, "a 244-max door with luma 240 must light the lamps")
        let nearClip = histogram(spikeAt: 238)
        #expect(
            !lights(red: nearClip, green: nearClip, blue: nearClip, luma: nearClip, transfer: .dlog2)
                .anyClip, "238 (about 97 IRE) is near clip, not clipped")
        let atCeiling = histogram(spikeAt: 247)
        #expect(lights(red: atCeiling, green: atCeiling, blue: atCeiling, transfer: .dlog2).anyClip)
    }

    @Test func blownHighlightLightsEveryChannelNotJustGreen() {
        // 4:2:0 reconstruction: G tracks Y at the ceiling, R/B sit a few codes
        // lower. The picture is still clipped: all three lamps must come on.
        var red = [Int](repeating: 0, count: 256)
        var green = [Int](repeating: 0, count: 256)
        var blue = [Int](repeating: 0, count: 256)
        var luma = [Int](repeating: 0, count: 256)
        red[230] = 1000
        green[247] = 1000
        blue[228] = 1000
        luma[242] = 1000
        let reading = lights(red: red, green: green, blue: blue, luma: luma, transfer: .dlog2)
        #expect(reading.red.clip && reading.green.clip && reading.blue.clip)
        #expect(reading.anyClip)
    }

    @Test func mixedSceneDoorClipLightsLampsWhileSubjectMedianIsMid() {
        var red = [Int](repeating: 0, count: 256)
        var green = [Int](repeating: 0, count: 256)
        var blue = [Int](repeating: 0, count: 256)
        var luma = [Int](repeating: 0, count: 256)
        red[90] = 800
        green[90] = 800
        blue[90] = 800
        luma[90] = 800
        red[230] = 200
        green[247] = 200
        blue[228] = 200
        luma[247] = 200
        let reading = lights(red: red, green: green, blue: blue, luma: luma, transfer: .dlog2)
        #expect(reading.red.clip && reading.green.clip && reading.blue.clip)
        #expect(
            abs(reading.green.level - 0.5) < 0.25, "bars still follow the subject, not the door")
    }

    @Test func clipLampsHoldThroughThresholdChatter() {
        let quarter = 0.025
        var bins = [Int](repeating: 0, count: 256)
        bins[128] = 970
        bins[247] = 30
        let on = lights(red: bins, green: bins, blue: bins, transfer: .dlog2, threshold: quarter)
        #expect(on.anyClip)
        bins[247] = 20
        bins[128] = 980
        let held = lights(
            red: bins, green: bins, blue: bins, transfer: .dlog2, threshold: quarter, previous: on)
        #expect(held.anyClip, "2.0% after 3.0% must stay lit (half of 2.5%)")
        bins[247] = 10
        bins[128] = 990
        let off = lights(
            red: bins, green: bins, blue: bins, transfer: .dlog2, threshold: quarter,
            previous: held)
        #expect(!off.anyClip, "1.0% drops the latch")
    }

    @Test func greyBalancesToCentre() {
        for transfer in transfers {
            let grey = Int((anchors(transfer).mid * 255).rounded())
            let bins = histogram(spikeAt: grey)
            let reading = lights(red: bins, green: bins, blue: bins, transfer: transfer)
            #expect(abs(reading.green.level - 0.5) < 0.02, "\(transfer) grey at centre")
            #expect(reading.green.isNeutral)
        }
    }

    @Test func thresholdLadderIsStopsOverTen() {
        #expect(ScopeTrafficLights.defaultThreshold == 0)
        // 2.6% clipped fires a 0.25-stop (2.5%) threshold; 2.4% does not.
        let quarter = 0.025
        var bins = [Int](repeating: 0, count: 256)
        bins[128] = 974
        bins[255] = 26
        #expect(lights(red: bins, green: bins, blue: bins, transfer: .dlog2, threshold: quarter).anyClip)
        bins[255] = 24
        bins[128] = 976
        #expect(!lights(red: bins, green: bins, blue: bins, transfer: .dlog2, threshold: quarter).anyClip)
        // One-stop compensation (10%): 9% does not fire.
        bins[255] = 90
        bins[128] = 910
        #expect(!lights(red: bins, green: bins, blue: bins, transfer: .dlog2, threshold: 0.10).anyClip)
    }

    @Test func emptyHistogramReadsNeutral() {
        let bins = [Int](repeating: 0, count: 256)
        #expect(lights(red: bins, green: bins, blue: bins, transfer: .dlog2) == .none)
    }

    // MARK: - Zebra (monitor-percent axis, no bisection)

    /// A D-Log2 preview tops out at 243–247. Only the ceiling byte itself is IRE 100, so a
    /// highlight threshold of 100 misses the shelf. The factory default must catch the
    /// shelf; 100 must still catch 247.
    @Test func dlog2ShelfUnderCeilingPaintsAtFactoryHighlight() {
        let ceiling = percent(247.0 / 255, .dlog2)
        #expect(abs(ceiling - 100) < 0.05)
        #expect(ceiling >= 100)
        #expect(ceiling >= LiveZebra.highlightIRE)
        for byte in 245...246 {
            let shelf = percent(Double(byte) / 255, .dlog2)
            #expect(shelf < 100, "byte \(byte) is under the 100 line")
            #expect(shelf >= LiveZebra.highlightIRE, "byte \(byte) at factory highlight")
        }
        // Rec.709 / HLG: 100 is still encoded peak; 99 is just under it.
        for transfer in [MonitorTransfer.rec709, .hdr] {
            #expect(abs(native(100, transfer) - 1) < 1e-12)
            let factory = native(LiveZebra.highlightIRE, transfer)
            #expect(factory < 1 && factory > 0.98)
        }
    }

    @Test func clipToolsAgreeOnTheClipShelf() {
        func histogram(atByte byte: Int, pixels: Int = 40) -> [Int] {
            var bins = [Int](repeating: 0, count: 256)
            bins[Int(MonitorTransfer.dlog2.middleGrayEncoded * 255)] = 5_000
            bins[byte] = pixels
            return bins
        }
        func lamps(_ bins: [Int]) -> ScopeTrafficLightsReading {
            lights(red: bins, green: bins, blue: bins, luma: bins, transfer: .dlog2)
        }
        let underClip = Int((native(93, .dlog2) * 255).rounded())
        #expect(underClip < 240)
        #expect(!lamps(histogram(atByte: underClip)).anyClip, "93 IRE is under clip")
        #expect(lamps(histogram(atByte: 244)).anyClip, "the clip shelf is clipped")
        #expect(lamps(histogram(atByte: 242)).anyClip, "a blown window read 242 on device")

        #expect(ScopeAnchors.clipShelfByte(clipByte: 247) == 240)
        let zebra100 = ScopeDisplayScale.zebraHighlightNative(
            monitorPercent: 100, transfer: .dlog2, clipByte: 247)
        #expect(zebra100 * 255 <= 240.0001, "zebra 100% fires on the clip shelf")
        #expect(
            ScopeDisplayScale.zebraHighlightNative(
                monitorPercent: 90, transfer: .dlog2, clipByte: 247) == native(90, .dlog2),
            "lower zebra settings are unchanged")

        let shelfStops = LiveColorScience.stops(encoded: 244.0 / 255, transfer: .dlog2)
        #expect(
            LiveColorScience.falseColorBand(
                value: shelfStops, scale: .sceneStops, transfer: .dlog2, clipEncoded: 247.0 / 255)?
                .label == "clip", "CineStop paints the clip shelf red")
    }

    // MARK: - False colour

    @Test func falseColorIREIsSixZoneVideoScale() {
        let labels = LiveColorScience.falseColorBands(.ire, transfer: .dlog2).map(\.label)
        #expect(labels == ["BDL", "NBDL", "18%MG", "MG+1", "80%WC", "95%WC"])
        func label(_ value: Double, _ transfer: MonitorTransfer) -> String? {
            LiveColorScience.falseColorBand(value: value, scale: .ire, transfer: transfer)?.label
        }
        #expect(label(41, .rec709) == "18%MG")
        #expect(label(30.50, .dlog2) == nil)
        #expect(label(54, .rec709) == "MG+1")
        #expect(label(80, .dlog2) == "80%WC")
        #expect(label(100, .dlog2) == "95%WC")
        #expect(label(1, .dlog2) == "BDL")
        let limits = LiveColorScience.falseColorBands(.limits, transfer: .dlog2).map(\.label)
        #expect(limits == ["0–4", "5–9", "94–98", "99–100"])
    }

    @Test func limitsClipBandStartsOnTheSourceShelf() {
        // 247 ceiling: shelf 240 sits under 99 IRE, so the clip band starts there.
        let bands = LiveColorScience.falseColorBands(
            .limits, transfer: .dlog2, clipEncoded: 247.0 / 255)
        let shelfIRE = ScopeDisplayScale.monitorPercent(
            LiveColorScience.clipShelf(ceiling: 247.0 / 255), transfer: .dlog2, clipByte: 247)
        #expect(bands[3].lowerBound == shelfIRE)
        #expect(bands[2].upperBound == shelfIRE)
        #expect(shelfIRE < 99)
    }

    @Test func cineStopIsVideoModeIRE() {
        let labels = LiveColorScience.falseColorBands(.stops, transfer: .dlog2).map(\.label)
        #expect(
            labels == [
                "0–4", "5", "10–12", "41–48", "61–70", "92–93", "94–95", "96–98", "99–100",
            ])
        #expect(
            LiveColorScience.falseColorBand(value: 41, scale: .stops, transfer: .rec709)?.label
                == "41–48")
        #expect(
            LiveColorScience.falseColorBand(value: 30.50, scale: .stops, transfer: .dlog2) == nil)
        #expect(
            LiveColorScience.falseColorBand(value: 100, scale: .stops, transfer: .dlog2)?.label
                == "99–100")
        #expect(abs(LiveColorScience.stops(linear: 475) - 11.366) < 0.01)
        #expect(abs(LiveColorScience.stops(linear: 42) - 7.867) < 0.01)
        #expect(LiveColorScience.stops(linear: 0) == -.infinity)
    }

    @Test func sceneStopsPaintFiveZonesAroundGray() {
        let bands = LiveColorScience.falseColorBands(.sceneStops, transfer: .dlog2)
        #expect(
            bands.map(\.label) == [
                "crush", "shadows", "−2", "−1", "18%", "+1", "+2", "highlights", "clip",
            ])
        #expect(bands.first?.lowerBound == -.infinity && bands.last?.upperBound == .infinity)
        for index in 0..<(bands.count - 1) {
            #expect(bands[index].upperBound == bands[index + 1].lowerBound, "every stop is painted")
        }
        func label(_ stops: Double) -> String? {
            LiveColorScience.falseColorBand(value: stops, scale: .sceneStops, transfer: .dlog2)?
                .label
        }
        #expect(label(-.infinity) == "crush")
        #expect(label(-7) == "crush")
        #expect(label(-6) == "shadows")
        #expect(label(-2) == "−2")
        #expect(label(-1) == "−1")
        #expect(label(0) == "18%")
        #expect(label(1) == "+1")
        #expect(label(2) == "+2")
        #expect(label(10) == "highlights", "unknown ceiling clips from +11")
        #expect(label(10.6) == "clip")
        for stops in [-5.0, -3] { #expect(label(stops) == "shadows") }
        for stops in [3.0, 5, 9.4] { #expect(label(stops) == "highlights") }
        #expect(LiveFalseColorScale.sceneStops.usesSceneStops)
        #expect(!LiveFalseColorScale.stops.usesSceneStops)
    }

    @Test func sceneStopPaletteIsPinned() {
        let bands = LiveColorScience.falseColorBands(.sceneStops, transfer: .dlog2)
        let palette: [(String, Double, Double, Double)] = [
            ("crush", 75, 8, 165), ("shadows", 102, 102, 102), ("−2", 39, 76, 0),
            ("−1", 155, 196, 56), ("18%", 127, 127, 127), ("+1", 221, 174, 180),
            ("+2", 252, 232, 96), ("highlights", 179, 178, 178), ("clip", 245, 39, 0),
        ]
        #expect(bands.map(\.label) == palette.map(\.0))
        for (band, expected) in zip(bands, palette) {
            #expect(
                band.red == expected.1 / 255 && band.green == expected.2 / 255
                    && band.blue == expected.3 / 255, "\(band.label)")
        }
    }

    @Test func sceneStopClipFollowsTheSourceCeiling() {
        func label(_ stops: Double, _ transfer: MonitorTransfer, clip: Double?) -> String? {
            LiveColorScience.falseColorBand(
                value: stops, scale: .sceneStops, transfer: transfer, clipEncoded: clip)?.label
        }
        let dlog2Clip = 247.0 / 255
        let dlog2Stops = LiveColorScience.stops(encoded: dlog2Clip, transfer: .dlog2)
        #expect(dlog2Stops > 10.5)
        #expect(label(dlog2Stops - 0.5, .dlog2, clip: dlog2Clip) == "highlights")
        #expect(label(dlog2Stops, .dlog2, clip: dlog2Clip) == "clip")

        let rec709Clip = 1.0
        let rec709Stops = LiveColorScience.stops(encoded: rec709Clip, transfer: .rec709)
        #expect(rec709Stops < 2.5)
        #expect(label(rec709Stops - 0.1, .rec709, clip: rec709Clip) == "+2")
        #expect(label(rec709Stops, .rec709, clip: rec709Clip) == "clip")
        let rec709Labels = LiveColorScience.falseColorBands(
            .sceneStops, transfer: .rec709, clipEncoded: rec709Clip
        ).map(\.label)
        #expect(!rec709Labels.contains("highlights"), "Rec.709 clips inside +2")
    }

    // MARK: - 709 reading through an integration-supplied look curve

    @Test func lookCurveDrivesThe709Reading() {
        // Synthetic 3-point grey axis: 0 → 0, 0.5 → 0.4, 1 → 1.
        let curve = [0.0, 0.4, 1.0]
        #expect(abs(LiveColorScience.rec709LookIRE(encoded: 0.25, lookCurve: curve)! - 20) < 1e-12)
        #expect(abs(LiveColorScience.rec709LookIRE(encoded: 0.75, lookCurve: curve)! - 70) < 1e-12)
        #expect(LiveColorScience.rec709LookIRE(encoded: 0.5, lookCurve: nil) == nil)
        #expect(LiveColorScience.rec709LookIRE(encoded: 0.5, lookCurve: [0.3]) == nil)
        #expect(LiveColorScience.readsThroughLook(lookCurve: curve, rec709: true))
        #expect(!LiveColorScience.readsThroughLook(lookCurve: curve, rec709: false))
        #expect(!LiveColorScience.readsThroughLook(lookCurve: nil, rec709: true))

        let video = LiveColorScience.falseColorReading(
            encoded: 0.25, transfer: .dlog2, rec709: true, lookCurve: curve)
        #expect(video.transfer == .rec709 && abs(video.encoded - 0.2) < 1e-12)
        let log = LiveColorScience.falseColorReading(
            encoded: 0.25, transfer: .dlog2, rec709: false, lookCurve: curve)
        #expect(log.transfer == .dlog2 && log.encoded == 0.25)
        let stops = LiveColorScience.falseColorReading(
            encoded: 0.25, transfer: .dlog2, rec709: true, lookCurve: curve, scale: .sceneStops)
        #expect(stops.transfer == .dlog2 && stops.encoded == 0.25, "CineStop reads scene stops")
    }

    @Test func falseColorClipPicksTheCeilingForEachReading() {
        let saturating = [0.0, 0.5, 0.99995, 1.0, 1.0]
        let ceiling = 247.0 / 255
        let logClip = LiveColorScience.falseColorClip(
            scale: .ire, transfer: .dlog2, rec709: false, lookCurve: saturating,
            clipEncoded: ceiling)
        #expect(logClip.transfer == .dlog2 && logClip.ceiling == ceiling)
        let videoClip = LiveColorScience.falseColorClip(
            scale: .ire, transfer: .dlog2, rec709: true, lookCurve: saturating,
            clipEncoded: ceiling)
        #expect(videoClip.transfer == .rec709 && videoClip.ceiling == 1)
        let cineStop = LiveColorScience.falseColorClip(
            scale: .sceneStops, transfer: .dlog2, rec709: true, lookCurve: saturating,
            clipEncoded: ceiling)
        #expect(cineStop.transfer == .dlog2 && cineStop.ceiling == 0.5, "first saturated node")
        let noLook = LiveColorScience.falseColorClip(
            scale: .sceneStops, transfer: .rec709, rec709: true, lookCurve: nil, clipEncoded: 1)
        #expect(noLook.transfer == .rec709 && noLook.ceiling == 1)
    }

    @Test func monitorPercentIsTheWaveAxis() {
        for transfer in transfers {
            let grey = LiveColorScience.encode(0.18, transfer: transfer)
            #expect(
                abs(percent(grey, transfer) - LiveColorScience.paperIRE(grey)) < 0.5,
                "\(transfer) 18% is paper IRE on the WAVE axis, not Reinhard 42")
            #expect(abs(percent(Double(clip(transfer)) / 255, transfer) - 100) < 0.05)
        }
        #expect(abs(percent(LiveColorScience.encode(0.18, transfer: .dlog2), .dlog2) - 30.50) < 0.5)
        #expect(abs(percent(LiveColorScience.encode(0.18, transfer: .dlog), .dlog) - 39.88) < 0.5)
        #expect(abs(percent(223.0 / 255, .dlog) - 100) < 0.05)
        // 188 is recoverable D-Log2 highlight, not clip (journal max is 247).
        let early = percent(188.0 / 255, .dlog2)
        #expect(early < 90)
        #expect(early < LiveZebra.highlightIRE)
    }

    // MARK: - Safety

    @Test func noNaNsAcrossEncodedSweep() {
        for transfer in transfers {
            for step in 0...200 {
                let encoded = Double(step) / 200
                let value = level(encoded, transfer)
                let monitor = percent(encoded, transfer)
                let linear = LiveColorScience.linearize(encoded, transfer: transfer)
                #expect(value.isFinite && value >= 0 && value <= 1)
                #expect(monitor.isFinite && monitor >= 0 && monitor <= 100)
                #expect(linear.isFinite && linear >= 0)
            }
        }
    }
}
