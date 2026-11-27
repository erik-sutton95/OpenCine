import OpenCineCore
import Testing

/// Which of a computer's interfaces lead to the cameras' network, and which hosts to search there.
@Suite struct HostInterfacePickTests {
    static let wifi = HostInterface(name: "en1", ipv4: "192.168.1.20", prefixLength: 24, isUp: true, carriesDefaultRoute: false)
    static let ethernet = HostInterface(name: "en0", ipv4: "192.168.1.21", prefixLength: 24, isUp: true, carriesDefaultRoute: true)

    @Test func defaultRouteComesFirst() {
        #expect(HostInterfacePick.stationInterfaces([Self.wifi, Self.ethernet]).map(\.name) == ["en0", "en1"])
        var other = Self.ethernet
        other.carriesDefaultRoute = false
        #expect(HostInterfacePick.stationInterfaces([Self.wifi, other]).map(\.name) == ["en0", "en1"])
    }

    @Test func ethernetOnlyMacIsUsable() {
        #expect(HostInterfacePick.stationInterfaces([Self.ethernet]) == [Self.ethernet])
    }

    @Test func tunnelsAndAirDropAreSkipped() {
        let vpn = HostInterface(name: "utun3", ipv4: "10.8.0.2", prefixLength: 24, isUp: true, carriesDefaultRoute: true)
        let awdl = HostInterface(name: "awdl0", ipv4: "192.168.9.1", prefixLength: 24, isUp: true, carriesDefaultRoute: false)
        let others = ["ipsec0", "llw0", "bridge100", "anpi0", "ap1", "gif0", "stf0", "lo0"].map {
            HostInterface(name: $0, ipv4: "10.1.2.3", prefixLength: 24, isUp: true, carriesDefaultRoute: false)
        }
        #expect(HostInterfacePick.stationInterfaces([vpn, awdl] + others + [Self.wifi]) == [Self.wifi])
    }

    @Test func publicLinkLocalAndDownAreSkipped() {
        let linkLocal = HostInterface(name: "en2", ipv4: "169.254.3.4", prefixLength: 16, isUp: true, carriesDefaultRoute: false)
        let publicAddress = HostInterface(name: "en3", ipv4: "17.1.2.3", prefixLength: 24, isUp: true, carriesDefaultRoute: false)
        let loopback = HostInterface(name: "en4", ipv4: "127.0.0.1", prefixLength: 8, isUp: true, carriesDefaultRoute: false)
        var down = Self.wifi
        down.isUp = false
        #expect(HostInterfacePick.stationInterfaces([linkLocal, publicAddress, loopback, down]).isEmpty)
        let ranges = [("10.0.0.5", true), ("172.16.4.2", true), ("172.31.9.9", true), ("172.32.0.1", false), ("192.169.0.1", false)]
        for (address, kept) in ranges {
            let iface = HostInterface(name: "en5", ipv4: address, prefixLength: 24, isUp: true, carriesDefaultRoute: false)
            #expect(HostInterfacePick.stationInterfaces([iface]).isEmpty == !kept, "\(address)")
        }
    }

    @Test func sweepCoversTheSubnetButNotItself() {
        let hosts = HostInterfacePick.sweepHosts(Self.wifi)
        #expect(hosts.count == 253 && !hosts.contains("192.168.1.20") && hosts.first == "192.168.1.1")
        #expect(hosts.last == "192.168.1.254")
        // A wider network is searched on its own /24; a narrower one keeps its range.
        let wide = HostInterface(name: "en0", ipv4: "10.4.7.200", prefixLength: 16, isUp: true, carriesDefaultRoute: true)
        #expect(HostInterfacePick.sweepHosts(wide).first == "10.4.7.1" && HostInterfacePick.sweepHosts(wide).count == 253)
        let narrow = HostInterface(name: "en0", ipv4: "172.20.10.2", prefixLength: 28, isUp: true, carriesDefaultRoute: true)
        #expect(HostInterfacePick.sweepHosts(narrow) == (1...14).filter { $0 != 2 }.map { "172.20.10.\($0)" })
    }

    @Test func theInterfaceOnACameraSubnetCarriesItsLink() {
        let other = HostInterface(name: "en0", ipv4: "10.0.0.9", prefixLength: 24, isUp: true, carriesDefaultRoute: true)
        #expect(HostInterfacePick.interface(reaching: "192.168.1.77", in: [other, Self.wifi]) == Self.wifi)
        #expect(HostInterfacePick.interface(reaching: "10.0.0.40", in: [other, Self.wifi]) == other)
        #expect(HostInterfacePick.interface(reaching: "172.16.0.1", in: [other, Self.wifi]) == nil)
    }

    @Test func theNetmaskFollowsThePrefix() {
        #expect(Self.wifi.netmask == "255.255.255.0")
        let hotspot = HostInterface(name: "en0", ipv4: "172.20.10.2", prefixLength: 28, isUp: true, carriesDefaultRoute: true)
        #expect(hotspot.netmask == "255.255.255.240")
    }

    @Test func hostWordsForTheStationRoute() {
        #expect(StationCopy.noStationNetwork == "This Mac is not on a network the cameras can join.")
        #expect(StationCopy.noStationNetwork.hasPrefix("This Mac"))
    }
}
