import Foundation
@testable import Insta360Apple
import OpenCineCore
import Testing

/// Where a Wi-Fi or hotspot setup looks for the camera: the camera has no fixed address in
/// station role, so the phone's own subnet is searched, nearest addresses first.
@Suite struct LunaStationPathTests {
    @Test func aPersonalHotspotSearchesItsWholeSubnet() {
        let hosts = LunaStationPath.candidates(
            around: .init(address: "172.20.10.1", netmask: "255.255.255.240"))
        #expect(hosts.count == 13, "a /28 without the phone, the network and the broadcast address")
        #expect(hosts.first == "172.20.10.2" && !hosts.contains("172.20.10.1"))
        #expect(!hosts.contains("172.20.10.0") && !hosts.contains("172.20.10.15"))
    }

    @Test func aLargeNetworkSearchesThePhonesOwnBlockNearestFirst() {
        let hosts = LunaStationPath.candidates(around: .init(address: "10.4.7.200", netmask: "255.255.0.0"))
        #expect(hosts.count == 253)
        #expect(Array(hosts.prefix(2)).sorted() == ["10.4.7.199", "10.4.7.201"])
        #expect(hosts.allSatisfy { $0.hasPrefix("10.4.7.") })
    }

    private static let hotspot = LunaStationPath.Address(address: "172.20.10.1", netmask: "255.255.255.240")

    @Test @MainActor func theCameraIsTheHostAnsweringTheGreeting() async throws {
        let host = try await LunaStationPath.findCamera(
            on: Self.hotspot, preferred: nil, budget: .seconds(60), isCurrent: { true },
            probe: { host, _ in host == "172.20.10.9" ? .camera : .absent })
        #expect(host == "172.20.10.9")
    }

    @Test @MainActor func aNetworkWithoutTheCameraStopsAtTheBatchWhereTheSearchTimeRanOut() async throws {
        let probed = Counter()
        let host = try await LunaStationPath.findCamera(
            on: .init(address: "192.168.1.20", netmask: "255.255.255.0"), preferred: nil,
            budget: .milliseconds(50), isCurrent: { true },
            probe: { _, _ in
                await probed.add()
                try? await Task.sleep(for: .milliseconds(100))
                return .absent
            })
        #expect(host == nil)
        #expect(await probed.value == 32, "one batch of 32 of the 253 hosts, not the whole network")
    }

    @Test @MainActor func localNetworkAccessOffIsSaidInsteadOfCameraNotFound() async {
        do {
            _ = try await LunaStationPath.findCamera(
                on: Self.hotspot, preferred: nil, budget: .milliseconds(50), isCurrent: { true },
                probe: { _, _ in .localNetworkDenied })
            Issue.record("a search iOS held back must not end as camera not found")
        } catch let failure as ConnectionFailure {
            #expect(failure.reason == .permission(.localNetwork))
            #expect(failure.actions.contains(.openSettings))
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test @MainActor func allowingLocalNetworkDuringTheSearchStillFindsTheCamera() async throws {
        let allowed = Flag()
        let host = try await LunaStationPath.findCamera(
            on: Self.hotspot, preferred: nil, budget: .seconds(60), isCurrent: { true },
            probe: { host, _ in
                guard await allowed.isSet else {
                    await allowed.set()
                    return .localNetworkDenied
                }
                return host == "172.20.10.4" ? .camera : .absent
            })
        #expect(host == "172.20.10.4")
    }
}

private actor Flag {
    private(set) var isSet = false
    func set() { isSet = true }
}

private actor Counter {
    private(set) var value = 0
    func add() { value += 1 }
}
