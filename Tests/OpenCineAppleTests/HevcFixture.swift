/// Synthetic gray 64x64 HEVC, generated with libx265, bframes=0 and a single IDR. Excludes
/// encoder metadata; these are not camera captures. Moved with the decoder tests from the apps'
/// `HevcTestFixtures.swift` (the apps keep their copy for their own session tests).
enum HevcFixture {
    static let vps = bytes("40010c01ffff01600000030090000003000003001eba0240")
    static let sps = bytes(
        "42010101600000030090000003000003001ea020810596e92930bc05a02000000300200000030321")
    static let pps = bytes("4401c073c089")
    static let idr = bytes("2801ac76071c24748e")
    static let pSlice = bytes("0201d0097883b0a098")

    static let keyframe: [UInt8] = [vps, sps, pps, idr].flatMap { [0, 0, 0, 1] + $0 }
    static let pFrame: [UInt8] = [0, 0, 0, 1] + pSlice

    private static func bytes(_ hex: String) -> [UInt8] {
        stride(from: 0, to: hex.count, by: 2).map { offset in
            let start = hex.index(hex.startIndex, offsetBy: offset)
            return UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16)!
        }
    }
}
