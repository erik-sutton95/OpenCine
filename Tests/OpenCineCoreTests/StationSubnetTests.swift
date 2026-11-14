import OpenCineCore
import Testing

/// The subnet a Multiview stage looks for cameras on. Kotlin twin: `StationSubnetTest`.
@Suite struct StationSubnetTests {
    @Test func respectsTheActualSubnetAndExcludesActiveCameras() {
        let hosts = StationSubnet.hosts(
            address: "192.168.7.130", mask: "255.255.255.248", excluding: ["192.168.7.132"])
        #expect(hosts == ["192.168.7.129", "192.168.7.131", "192.168.7.133", "192.168.7.134"])
    }

    @Test func crossesOctetsWithoutAssumingSlash24() {
        let hosts = StationSubnet.hosts(address: "10.4.1.10", mask: "255.255.254.0")
        #expect(hosts?.count == 509)
        #expect(hosts?.first == "10.4.0.1")
        #expect(hosts?.last == "10.4.1.254")
        #expect(hosts?.contains("10.4.1.10") == false)
    }

    @Test func refusesUnboundedMalformedAndNoncontiguousNetworks() {
        for mask in ["255.255.0.0", "255.255.254.128", "255.255.255.255", "255.255.255.254", "bad"] {
            #expect(StationSubnet.hosts(address: "10.1.2.3", mask: mask) == nil, "\(mask)")
        }
        #expect(StationSubnet.hosts(address: "10.1.2.999", mask: "255.255.255.0") == nil)
        #expect(StationSubnet.hosts(address: "10.1.2.+3", mask: "255.255.255.0") == nil)
        #expect(StationSubnet.hosts(address: "10.4.0.1", mask: "255.255.252.0")?.count == 1021)
    }

    @Test func aCameraAddressIsUnicastIPv4() {
        for address in ["192.168.1.20", "10.0.0.1", "172.20.10.2", "223.1.1.1"] {
            #expect(StationSubnet.validAddress(address), "\(address)")
        }
        for address in ["", "0.1.2.3", "127.0.0.1", "224.0.0.1", "255.255.255.255", "1.2.3", "1.2.3.4.5", "a.b.c.d", "1.2.3.256"] {
            #expect(!StationSubnet.validAddress(address), "\(address)")
        }
    }
}
