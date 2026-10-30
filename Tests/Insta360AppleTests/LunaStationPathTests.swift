@testable import Insta360Apple
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
}
