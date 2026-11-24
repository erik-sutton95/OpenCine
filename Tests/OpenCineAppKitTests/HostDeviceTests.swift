import OpenCineAppKit
import OpenCineCore
import Testing

/// The device the app runs on, as the pairing words name it, and the station words a Mac shows.
@Suite struct HostDeviceTests {
    @Test func hostNouns() {
        #expect(HostDevice.iPhone.thisDevice == "this iPhone")
        #expect(HostDevice.iPad.thisDevice == "this iPad")
        #expect(HostDevice.mac.thisDevice == "this Mac")
        #expect(HostDevice.mac.isComputer && !HostDevice.iPhone.isComputer && !HostDevice.iPad.isComputer)
    }

    @Test func notFoundOnNetworkNamesItAndTheCause() {
        let text = StationCopy.notFoundOnNetwork("Studio", host: .mac)
        #expect(text.contains("Studio") && text.contains("this Mac") && text.contains("guest networks"))
        #expect(
            text
                == "The camera joined Studio but this Mac cannot reach it. Check that this Mac is on Studio and that the network lets devices see each other (guest networks often do not).")
    }
}
