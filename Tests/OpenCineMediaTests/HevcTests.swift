import Testing

@testable import OpenCineMedia

private func hex(_ s: String) -> [UInt8] {
    var out = [UInt8]()
    var i = s.startIndex
    while i < s.endIndex {
        let j = s.index(i, offsetBy: 2)
        out.append(UInt8(s[i..<j], radix: 16)!)
        i = j
    }
    return out
}

// Real parameter sets captured from the Osmo Pocket live view (captures/live1.pcap).
private let VPS = hex("40010c01ffff21600000030000030000030000030096ac0c0000030004000003006540")
private let SPS = hex(
    "42010121600000030000030000030000030096a00280802d17aeedc9ae5d4d404040410000030001000003001908")
private let PPS = hex("4401c17312240890")

@Suite struct HevcTests {
    @Test func nalTypesOfRealParameterSets() {
        #expect(Hevc.nalType(VPS[0]) == Hevc.vps)  // 32
        #expect(Hevc.nalType(SPS[0]) == Hevc.sps)  // 33
        #expect(Hevc.nalType(PPS[0]) == Hevc.pps)  // 34
        #expect(Hevc.isKeyframeNal(Hevc.idr) && Hevc.isKeyframeNal(Hevc.vps))
        #expect(!Hevc.isKeyframeNal(1) && !Hevc.isKeyframeNal(35))
        let sc: [UInt8] = [0, 0, 1]
        #expect(Hevc.accessUnitCarriesKeyframe(sc + VPS + sc + SPS + sc + PPS))
        #expect(!Hevc.accessUnitCarriesKeyframe(sc + [0x02, 0xAA, 0xBB]))
    }

    @Test func pocketBLAIsGOPStartNotTRAIL() {
        #expect(Hevc.isIRAP(Hevc.blaWLP) && Hevc.isIRAP(Hevc.idr) && Hevc.isIRAP(Hevc.craNut))
        #expect(!Hevc.isIRAP(1) && !Hevc.isIRAP(35) && !Hevc.isIRAP(Hevc.vps))
        #expect(Hevc.isKeyframeNal(Hevc.blaWLP), "Pocket live GOP is often BLA_W_LP (16)")
        let sc: [UInt8] = [0, 0, 1]
        // First byte 0x20 ⇒ type 16 (handbook BLA_W_LP).
        #expect(Hevc.nalType(0x20) == Hevc.blaWLP)
        let bla: [UInt8] = sc + [0x20, 0x01, 0xAA]
        #expect(Hevc.accessUnitCarriesKeyframe(bla))
        var leftoverTrail: [UInt8] = sc
        leftoverTrail += [0x02, 0xAA]
        leftoverTrail += sc
        leftoverTrail += [0x46, 0x01]
        leftoverTrail += sc
        leftoverTrail += [0x50, 0x01]
        #expect(
            !Hevc.accessUnitCarriesKeyframe(leftoverTrail),
            "leftover TRAIL/AUD/SEI 1,35,40 must not look like a GOP start")
        let idrNlp: [UInt8] = sc + [0x28, 0x01]
        #expect(Hevc.accessUnitCarriesKeyframe(idrNlp), "IDR_N_LP 0x28 still counts")
    }

    @Test func splitsRealAnnexBIntoNALs() {
        let sc: [UInt8] = [0, 0, 1]
        let stream = sc + VPS + sc + SPS + sc + PPS
        let nals = Hevc.nalUnits(stream)
        #expect(nals.count == 3)
        #expect(nals[0] == VPS && nals[1] == SPS && nals[2] == PPS)
        #expect(nals.map { Hevc.nalType($0[0]) } == [Hevc.vps, Hevc.sps, Hevc.pps])
        // Header-only view matches the copied NALs, including 4-byte start codes.
        let padded = [0] + stream + [0, 0, 0, 1, 0x26, 0x01, 0x00]
        #expect(Hevc.nalHeaders(padded) == Hevc.nalUnits(padded).map { $0[0] })
        #expect(Hevc.nalRanges(padded).map { Array(padded[$0]) } == Hevc.nalUnits(padded))
    }
}

@Suite struct AvcLiveViewTests {
    // Real Nano SPS/PPS from mimo-nano-live-20260818 (H.264 High 1280×720).
    private let nanoSPS = hex("6764001facb402802dd3501040106d0a1350")
    private let nanoPPS = hex("68ee06f2c0")

    @Test func capturedNanoParameterSets() {
        #expect(Avc.nalType(nanoSPS[0]) == Avc.sps)
        #expect(Avc.nalType(nanoPPS[0]) == Avc.pps)
        #expect(Avc.isKeyframeNal(Avc.idr) && Avc.isKeyframeNal(Avc.sps))
        #expect(!Avc.isKeyframeNal(Avc.nonIdr) && !Avc.isKeyframeNal(Avc.aud))
    }

    @Test func detectsAvcVersusHevc() {
        let sc: [UInt8] = [0, 0, 1]
        let avc = sc + nanoSPS + sc + nanoPPS
        #expect(LiveVideo.detect(annexB: avc) == .avc)
        #expect(LiveVideo.detect(nals: Hevc.nalUnits(avc)) == .avc)
        let hevc =
            sc + hex("40010c01ffff21600000030000030000030000030096ac0c0000030004000003006540")
        #expect(LiveVideo.detect(annexB: hevc) == .hevc)
        #expect(LiveVideo.detect(annexB: sc + [0x02, 0xAA]) == nil)
        #expect(LiveVideo.codec(ofNAL: 0x41) == nil, "AVC P-slice must not latch as HEVC VPS")
        #expect(LiveVideo.codec(ofNAL: 0x40) == .hevc)
        #expect(LiveVideo.codec(ofNAL: 0x67) == .avc)
        #expect(LiveVideo.codec(ofNAL: 0x68) == .avc)
        // Pocket IDR_N_LP first byte is 0x28 — same as AVC PPS with nal_ref_idc=1.
        // Classifying it as AVC made Android MediaCodec.configure(AVC) throw and
        // left WAITING FOR LIVE VIEW up after leftover P-frames.
        #expect(LiveVideo.codec(ofNAL: 0x28) == nil, "HEVC IDR_N_LP must not latch as AVC PPS")
        #expect(LiveVideo.detect(annexB: sc + [0x28, 0x01]) == nil)
        #expect(
            LiveVideo.detect(annexB: sc + [0x02, 0xAA] + sc + [0x46, 0x01] + sc + [0x50, 0x01])
                == nil)
        let idrThenVps =
            sc + [0x28, 0x01] + sc
            + hex("40010c01ffff21600000030000030000030000030096ac0c0000030004000003006540")
        #expect(LiveVideo.detect(annexB: idrThenVps) == .hevc)
    }
}
