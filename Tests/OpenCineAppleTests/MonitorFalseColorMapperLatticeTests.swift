#if canImport(CoreImage) && canImport(os)
import OpenCineApple
import OpenCineMedia
import Testing

/// A1-48: the mapper that caches false colour cubes for the live picture, the inspector preview and
/// the assist engine paints exactly what the shared lattice paints. Every app and both platforms
/// then show the same band colours for the same signal.
@Suite(.serialized) struct MonitorFalseColorMapperLatticeTests {
    @Test func oneRec709IRECubePaintsTheSignal() {
        let mapper = MonitorFalseColorMapper(lookCurves: [:])
        let mapped = mapper.cube(scale: .ire, transfer: .rec709, rec709: false, clipByte: 230)
        let shared = MonitorFalseColorLattice.signal(scale: .ire, transfer: .rec709,
            clipByte: 230, readThroughLook: false).cube(.composite)
        #expect(mapped.size == shared.size)
        #expect(zip(mapped.rgb, shared.rgb).allSatisfy { $0.0.bitPattern == $0.1.bitPattern })
    }

    private static let cases: [(MonitorTransfer, LiveFalseColorScale, Bool)] =
        [MonitorTransfer.rec709, .dlog, .dlog2, .ilog].flatMap { transfer in
            LiveFalseColorScale.allCases.flatMap { scale in
                [false, true].map { (transfer, scale, $0) }
            }
        }

    /// The same exhaustive matrix as the retained original, with a result per source/scale/read.
    @Test(arguments: cases) func individualLatticeCase(
        transfer: MonitorTransfer, scale: LiveFalseColorScale, readThroughLook: Bool
    ) {
        let curve: [Double] = [0, 0.04, 0.41, 0.75, 1, 1]
        let mapper = MonitorFalseColorMapper(lookCurves: transfer == .rec709 ? [:] : [transfer: curve])
        let lattice = MonitorFalseColorLattice.signal(scale: scale, transfer: transfer,
            clipByte: 230, lookCurve: transfer == .rec709 ? nil : curve, readThroughLook: readThroughLook)
        let pairs: [(String, CubeLUT, CubeLUT)] = [
            ("full", mapper.cube(scale: scale, transfer: transfer, rec709: readThroughLook, clipByte: 230), lattice.cube(.composite)),
            ("paint", mapper.overlayPaintCube(scale: scale, transfer: transfer, rec709: readThroughLook, clipByte: 230), lattice.cube(.paint)),
            ("weight", mapper.overlayWeightCube(scale: scale, transfer: transfer, rec709: readThroughLook, clipByte: 230), lattice.cube(.weight)),
        ]
        for (name, mapped, shared) in pairs {
            #expect(mapped.size == shared.size)
            #expect(zip(mapped.rgb, shared.rgb).allSatisfy { $0.0.bitPattern == $0.1.bitPattern },
                "\(transfer) \(scale) read709=\(readThroughLook) \(name)")
        }
    }

    /// One mapper retains both distinct transfers: a missing transfer cache key cannot pass.
    @Test func distinctTransfersReuseOneMapperWithoutBorrowingThePreviousCube() {
        let curve: [Double] = [0, 0.04, 0.41, 0.75, 1, 1]
        let mapper = MonitorFalseColorMapper(lookCurves: [.dlog2: curve])
        let first = MonitorFalseColorLattice.signal(scale: .stops, transfer: .rec709,
            clipByte: 230, readThroughLook: true)
        let next = MonitorFalseColorLattice.signal(scale: .stops, transfer: .dlog2,
            clipByte: 230, lookCurve: curve, readThroughLook: true)
        #expect(first.cube(.composite).rgb != next.cube(.composite).rgb,
            "The two declared transfers must exercise different signal calibration")
        for (transfer, lattice) in [(MonitorTransfer.rec709, first), (.dlog2, next)] {
            let pairs: [(CubeLUT, CubeLUT)] = [
                (mapper.cube(scale: .stops, transfer: transfer, rec709: true, clipByte: 230), lattice.cube(.composite)),
                (mapper.overlayPaintCube(scale: .stops, transfer: transfer, rec709: true, clipByte: 230), lattice.cube(.paint)),
                (mapper.overlayWeightCube(scale: .stops, transfer: transfer, rec709: true, clipByte: 230), lattice.cube(.weight)),
            ]
            for (mapped, shared) in pairs {
                #expect(mapped.size == shared.size)
                #expect(zip(mapped.rgb, shared.rgb).allSatisfy { $0.0.bitPattern == $0.1.bitPattern })
            }
        }
    }

    @Test(arguments: [MonitorTransfer.rec709, .dlog, .dlog2, .ilog])
    func theMapperPaintsTheSharedLattice(transfer: MonitorTransfer) {
        // A declared sampling fixture, independent of any integration's official catalog.
        let curve: [Double] = [0, 0.04, 0.41, 0.75, 1, 1]
        let transfers: [MonitorTransfer] = [.rec709, .dlog, .dlog2, .ilog]
        let mapper = MonitorFalseColorMapper(lookCurves: Dictionary(
            uniqueKeysWithValues: transfers.filter { $0 != .rec709 }.map { ($0, curve) }))
        let clipByte = 230
        let look = transfer == .rec709 ? nil : curve
            for scale in LiveFalseColorScale.allCases {
                for rec709 in [false, true] {
                    let lattice = MonitorFalseColorLattice.signal(scale: scale, transfer: transfer,
                        clipByte: clipByte, lookCurve: look, readThroughLook: rec709)
                    let pairs: [(String, CubeLUT, CubeLUT)] = [
                        ("full", mapper.cube(scale: scale, transfer: transfer, rec709: rec709,
                            clipByte: clipByte), lattice.cube(.composite)),
                        ("paint", mapper.overlayPaintCube(scale: scale, transfer: transfer, rec709: rec709,
                            clipByte: clipByte), lattice.cube(.paint)),
                        ("weight", mapper.overlayWeightCube(scale: scale, transfer: transfer, rec709: rec709,
                            clipByte: clipByte), lattice.cube(.weight)),
                    ]
                    for (name, mapped, shared) in pairs {
                        let same = mapped.size == shared.size
                            && zip(mapped.rgb, shared.rgb).allSatisfy { $0.0.bitPattern == $0.1.bitPattern }
                        #expect(same, "\(transfer) \(scale) read709=\(rec709) \(name)")
                    }
                }
            }
    }
}
#endif
