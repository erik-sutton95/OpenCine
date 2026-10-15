import Foundation
import OpenCineMedia
import OpenCineNikon
import Testing

@Suite struct NikonMonitorColorProfileTests {
    @Test func generatedLooksAndSampledReadingsMatchOriginalZVectors() throws {
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../Fixtures/monitor-log-display-look-vectors.tsv")
        let rows = try String(contentsOf: path, encoding: .utf8).split(whereSeparator: \.isNewline)
            .filter { !$0.hasPrefix("#") }.map { $0.split(separator: "\t").map(String.init) }
        #expect(rows.count == 40)
        #expect(Set(NikonMonitorColorProfile.rec709LookCurves.keys) == [.log3G10, .nlog])
        for (name, transform, transfer) in [
            ("log3G10", NikonMonitorColorProfile.log3G10Rec709, MonitorTransfer.log3G10),
            ("nLog", NikonMonitorColorProfile.nLogRec709, .nlog),
        ] {
            let rgb = transform.rgb(size: 33)
            let curve = try #require(NikonMonitorColorProfile.rec709LookCurves[transfer])
            #expect(curve.count == 256)
            for row in rows where row[1] == name {
                let r = try #require(Int(row[3]))
                if row[0] == "rgb" {
                    let g = try #require(Int(row[4]))
                    let b = try #require(Int(row[5]))
                    let offset = (r + g * 33 + b * 33 * 33) * 3
                    for channel in 0..<3 {
                        let expected = try #require(Float(row[6 + channel]))
                        #expect(rgb[offset + channel].bitPattern == expected.bitPattern)
                    }
                } else {
                    let expected = try #require(Double(row[6]))
                    #expect(curve[r].bitPattern == expected.bitPattern)
                }
            }
        }
    }
}
