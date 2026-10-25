#if canImport(Darwin) && !os(watchOS)
    import Darwin
    import Foundation
    import Testing

    @testable import OpenCineNikon

    @Suite struct NikonAppleNetworkInterfacesTests {
        @Test func nativeAddressBytesRetainPrivateIPv4Admission() {
            for host in ["10.1.2.3", "172.16.0.1", "172.31.255.254", "192.168.1.10"] {
                #expect(
                    NikonAppleNetworkInterfaces.ipv4Address(from: nikonAppleSockaddr(host)) == host)
            }
            for host in ["172.15.0.1", "172.32.0.1", "127.0.0.1", "169.254.1.1", "203.0.113.1"] {
                #expect(
                    NikonAppleNetworkInterfaces.ipv4Address(from: nikonAppleSockaddr(host)) == nil)
            }
            #expect(NikonAppleNetworkInterfaces.ipv4Address(from: nikonAppleIPv6Sockaddr()) == nil)
            #expect(NikonAppleNetworkInterfaces.ipv4Address(from: Data()) == nil)
            #expect(
                NikonAppleNetworkInterfaces.ipv4Address(from: Data([0, UInt8(AF_INET)])) == nil)
            // The original getifaddrs code also ran a netmask through this private-IPv4 filter.
            // Moving the source must not silently replace that existing discovery input policy.
            #expect(
                NikonAppleNetworkInterfaces.ipv4Address(from: nikonAppleSockaddr("255.255.255.0"))
                    == nil)
        }

        @Test func interfaceFlagsRetainUpIPv4AndAWDLRadioSemantics() {
            #expect(
                NikonAppleNetworkInterfaces.admitsIPv4(
                    flags: UInt32(IFF_UP), family: sa_family_t(AF_INET)))
            #expect(!NikonAppleNetworkInterfaces.admitsIPv4(flags: 0, family: sa_family_t(AF_INET)))
            #expect(
                !NikonAppleNetworkInterfaces.admitsIPv4(
                    flags: UInt32(IFF_UP | IFF_LOOPBACK), family: sa_family_t(AF_INET)))
            #expect(
                !NikonAppleNetworkInterfaces.admitsIPv4(
                    flags: UInt32(IFF_UP), family: sa_family_t(AF_INET6)))
            #expect(
                NikonAppleNetworkInterfaces.isWiFiRadioInterface(
                    name: "awdl0", flags: UInt32(IFF_UP | IFF_RUNNING)))
            #expect(
                !NikonAppleNetworkInterfaces.isWiFiRadioInterface(
                    name: "awdl0", flags: UInt32(IFF_UP)))
            #expect(
                !NikonAppleNetworkInterfaces.isWiFiRadioInterface(
                    name: "en0", flags: UInt32(IFF_UP | IFF_RUNNING)))
        }

        @Test func scanLabelNamesTheWiFiSubnetNeverTheCellularOne() {
            // Hardware pass 2026-10-25: iOS lists pdp_ip0 (cellular, a carrier 10/8 address)
            // before en0, and the pairing sheet read "Searching 10.233.24.x".
            let interfaces = [
                NikonLocalInterface(name: "pdp_ip0", address: "10.233.24.17"),
                NikonLocalInterface(name: "utun4", address: "10.8.0.2"),
                NikonLocalInterface(name: "en0", address: "192.168.1.34"),
            ]
            #expect(NikonAppleNetworkInterfaces.currentScanSubnetLabel(in: interfaces) == "192.168.1.x")
            #expect(NikonAppleNetworkInterfaces.currentScanSubnetLabel(in: [interfaces[0]]) == nil)
        }

        @Test func interfaceOrderAndHotspotDeduplicationRetainCurrentScanGuidance() {
            let interfaces = [
                NikonLocalInterface(name: "en0", address: "203.0.113.1"),
                NikonLocalInterface(name: "bridge100", address: "172.20.10.1"),
                NikonLocalInterface(name: "bridge101", address: "172.20.10.2"),
                NikonLocalInterface(name: "en1", address: "192.168.1.42"),
                NikonLocalInterface(name: "bridge102", address: "10.0.1.1"),
            ]
            #expect(
                NikonAppleNetworkInterfaces.hotspotSubnetBases(in: interfaces) == [
                    "172.20.10", "10.0.1",
                ])
            #expect(
                NikonAppleNetworkInterfaces.currentScanSubnetLabel(in: interfaces) == "172.20.10.x")
            #expect(
                NikonAppleNetworkInterfaces.currentScanSubnetLabel(in: Array(interfaces.reversed()))
                    == "10.0.1.x")
            #expect(NikonAppleNetworkInterfaces.currentScanSubnetLabel(in: [interfaces[0]]) == nil)
            #expect(NikonAppleNetworkInterfaces.hotspotSubnetBases(in: []) == [])
        }
    }
#endif
