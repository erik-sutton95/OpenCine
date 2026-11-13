import Foundation
import OpenCineCore
import Testing

@testable import OpenCineNikon

/// Shared Multiview prep (Plan 6): the Nikon operations a Pocket-standard Multiview tile needs.
/// Scripted links and a manual clock; physical Nikon behavior is untested. Kotlin mirror:
/// `NikonMultiviewTest`, same method names.
@Suite struct NikonMultiviewTests {
    struct LinkDown: Error {}

    /// One opened PTP link: which host it reached and the serial GetDeviceInfo reported.
    struct Link: Sendable, Equatable {
        let host: String
        let serial: String?
    }

    /// The bodies on the network, every dial and close, and a manual clock that `sleep` advances.
    final class Network: @unchecked Sendable {
        // SAFETY: all state behind `lock`.
        private let lock = NSLock()
        private var _connects: [String] = []
        private var _closed: [String] = []
        private var _sleeps: [Duration] = []
        private var _now = MonotonicInstant.zero
        var serials: [String: String?] = [:]

        var connects: [String] { lock.withLock { _connects } }
        var closed: [String] { lock.withLock { _closed } }
        var sleeps: [Duration] { lock.withLock { _sleeps } }
        var now: MonotonicInstant { lock.withLock { _now } }

        func advance(_ duration: Duration) { lock.withLock { _now = _now + duration } }

        func sleep(_ duration: Duration) {
            lock.withLock {
                _sleeps.append(duration)
                _now = _now + duration
            }
        }

        func connect(_ host: String) throws -> Link {
            lock.withLock { _connects.append(host) }
            guard let serial = serials[host] else { throw LinkDown() }
            return Link(host: host, serial: serial)
        }

        func close(_ link: Link) { lock.withLock { _closed.append(link.host) } }
    }

    static let serial = "3001234"
    static let device = NikonMulticamPolicy.device(serialNumber: serial)!

    func opener(_ network: Network) -> NikonMemberOpener<Link> {
        NikonMemberOpener(
            now: { network.now }, sleep: { network.sleep($0) }, connect: { try network.connect($0) },
            serialNumber: { $0.serial }, close: { network.close($0) })
    }

    // MARK: Open a picked body

    @Test func openReturnsTheBodyAndItsSerialDevice() async throws {
        let network = Network()
        network.serials = ["192.168.1.30": Self.serial]
        let result = try await opener(network).open(host: "192.168.1.30", members: [], hostsInUse: [])
        #expect(result.link == Link(host: "192.168.1.30", serial: Self.serial))
        #expect(result.device == Self.device)
        #expect(network.connects == ["192.168.1.30"] && network.closed.isEmpty && network.sleeps.isEmpty)
    }

    /// A host a member or Live View holds is never dialled: a second Init drops its session.
    @Test func openRefusesAHostInUseWithoutDialling() async throws {
        let network = Network()
        network.serials = ["192.168.1.30": Self.serial]
        let result = try await opener(network).open(
            host: "192.168.1.30", members: [], hostsInUse: [" 192.168.1.30"])
        #expect(result.refusal == .hostInUse)
        #expect(network.connects.isEmpty)
    }

    @Test func openClosesAndRefusesABodyAlreadyInTheGroup() async throws {
        let network = Network()
        network.serials = ["192.168.1.40": Self.serial]  // the member, found again under a new address
        let result = try await opener(network).open(host: "192.168.1.40", members: [Self.device], hostsInUse: [])
        #expect(result.refusal == .alreadyMember)
        #expect(network.closed == ["192.168.1.40"])
    }

    @Test func openClosesAndRefusesADifferentBody() async throws {
        let network = Network()
        network.serials = ["192.168.1.30": "3009999"]
        let result = try await opener(network).open(
            host: "192.168.1.30", expectedSerial: Self.serial, members: [], hostsInUse: [])
        #expect(result.refusal == .differentBody)
        #expect(network.closed == ["192.168.1.30"])
    }

    /// Unknown is not a pass: without a serial the group cannot tell this body from a member.
    @Test func openClosesAndRefusesABodyWithoutASerial() async throws {
        let network = Network()
        network.serials = ["192.168.1.30": " "]
        let result = try await opener(network).open(host: "192.168.1.30", members: [], hostsInUse: [])
        #expect(result.refusal == .noIdentity)
        #expect(network.closed == ["192.168.1.30"])
    }

    /// The ZR can hold the PTP slot briefly after CloseSession; an Init inside that window is what
    /// tips a reconnect into a wedge. A failed dial counts as a release too. Other hosts never wait.
    @Test func openWaitsTheReconnectSettleAfterAClose() async throws {
        let network = Network()
        network.serials = ["192.168.1.30": Self.serial, "192.168.1.31": "3005678"]
        let opener = opener(network)
        let first = try #require(try await opener.open(host: "192.168.1.30", members: [], hostsInUse: []).link)
        await opener.close(first, host: "192.168.1.30")
        network.advance(.milliseconds(200))
        _ = try await opener.open(host: "192.168.1.31", members: [], hostsInUse: [])
        #expect(network.sleeps.isEmpty)
        _ = try await opener.open(host: "192.168.1.30", members: [], hostsInUse: [])
        #expect(network.sleeps == [.milliseconds(1_000)])

        // Nothing answers at .50: the dial fails.
        await #expect(throws: LinkDown.self) {
            try await opener.open(host: "192.168.1.50", members: [], hostsInUse: [])
        }
        _ = try? await opener.open(host: "192.168.1.50", members: [], hostsInUse: [])
        #expect(network.sleeps == [.milliseconds(1_000), NikonMemberTiming.reconnectSettle])
        #expect(NikonMemberTiming.reconnectSettle == .milliseconds(1_200))
    }
}
