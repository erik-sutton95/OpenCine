import Foundation
import Testing

@testable import OpenCineNikon

/// The Swift half of `Fixtures/nikon-network-vectors.tsv`.
///
/// Android re-implements `CameraWiFiSSID`, `CameraDiscovery`'s host rules and
/// `InfrastructureDiscovery`'s miss classification in Kotlin (`NikonNetworkPolicy.kt`), and
/// nothing in the build links the two. Both suites read the same rows so a change that lands on
/// one side and not the other fails a test instead of shipping.
@Suite struct NikonNetworkVectorTests {
    static let vectors: [[String]] = {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // OpenCineNikonTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
        let path = root.appendingPathComponent("Fixtures/nikon-network-vectors.tsv").path
        let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        return
            text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { !$0.hasPrefix("#") && !$0.isEmpty }
            .map { $0.components(separatedBy: "\t") }
    }()

    static func value(_ field: String) -> String? {
        switch field {
        case "<nil>": return nil
        case "<empty>": return ""
        default: return field
        }
    }

    static func tally(_ field: String) -> InfrastructureSweepTally {
        let c = field.split(separator: ",").compactMap { Int($0) }
        return InfrastructureSweepTally(
            openCount: c[0], occupiedCount: c[1], timeoutCount: c[2], refusedCount: c[3],
            noRouteCount: c[4], deniedCount: c[5], otherCount: c[6], hostsProbed: c[7])
    }

    static func described(_ tally: InfrastructureSweepTally) -> String {
        let counts = [
            tally.openCount, tally.occupiedCount, tally.timeoutCount, tally.refusedCount,
            tally.noRouteCount, tally.deniedCount, tally.otherCount, tally.hostsProbed,
        ]
        let hosts = { (list: [String]) in list.isEmpty ? "<empty>" : list.joined(separator: ",") }
        return counts.map(String.init).joined(separator: ",") + "|" + hosts(tally.occupiedHosts)
            + "|" + hosts(tally.openHosts)
    }

    static func described(_ reason: InfrastructureMissReason) -> String {
        switch reason {
        case .localNetworkDenied: return "localNetworkDenied"
        case .noScannableInterface: return "noScannableInterface"
        case .onCameraAccessPoint: return "onCameraAccessPoint"
        case .networkUnreachable: return "networkUnreachable"
        case .hostsVisibleNoPTP: return "hostsVisibleNoPTP"
        case .cameraNotFound: return "cameraNotFound"
        case .heldByOtherDevice(let holder): return "heldByOtherDevice:\(holder)"
        }
    }

    static func preflight(_ name: String) -> InfrastructurePreflight {
        switch name {
        case "noScannableInterface": return .noScannableInterface
        case "localNetworkDenied": return .localNetworkDenied
        default: return .ready(interfaces: [LocalIPv4Interface(name: "en0", address: "192.168.1.5")])
        }
    }

    static func answer(_ row: [String]) -> String? {
        let input = value(row[1])
        switch row[0] {
        case "apSsid": return String(CameraWiFiSSID.isNikonZAccessPoint(input!))
        case "dialable": return String(CameraDiscovery.isDialableHost(input!))
        case "apHostKey": return CameraDiscovery.pendingAccessPointHostKey(ssid: input)
        case "isApHostKey": return String(CameraDiscovery.isAccessPointHostKey(input!))
        case "subnetBase": return CameraDiscovery.subnetBase(for: input!)
        case "privateIPv4": return String(CameraDiscovery.isPrivateIPv4(input!))
        case "scanIface":
            return String(CameraDiscovery.isSupportedScanInterface(name: input!, address: row[2]))
        case "tally":
            var verdicts: [String: HostProbeVerdict] = [:]
            for pair in input!.split(separator: ",") {
                let parts = pair.split(separator: "=").map(String.init)
                verdicts[parts[0]] = HostProbeVerdict(rawValue: parts[1])
            }
            return described(InfrastructureSweepTally.from(verdicts: verdicts))
        case "classify":
            return described(
                InfrastructureDiscovery.classifyMiss(
                    preflight: preflight(row[1]),
                    onCameraAccessPoint: row[2] == "true",
                    tally: value(row[3]).map(tally),
                    heldHolderName: value(row[4])))
        default: return "unknown kind \(row[0])"
        }
    }

    @Test func fixtureIsPresentAndCoversEveryPolicy() {
        #expect(Self.vectors.count > 60, "fixture missing or truncated")
        #expect(
            Set(Self.vectors.map { $0[0] }) == [
                "apSsid", "dialable", "apHostKey", "isApHostKey", "subnetBase", "privateIPv4",
                "scanIface", "tally", "classify",
            ])
    }

    @Test func swiftCoreMatchesEveryVector() {
        for row in Self.vectors {
            #expect(Self.answer(row) == Self.value(row[row.count - 1]), "row: \(row)")
        }
    }
}
