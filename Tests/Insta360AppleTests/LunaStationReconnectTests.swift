import Foundation
@testable import Insta360Apple
import OpenCineCore
import Testing

/// LAN-first reconnect for a Wi-Fi or hotspot setup: a camera last reached on the network is
/// opened at its known address with the serial check, and moved over Bluetooth only when that
/// fails. Kotlin mirror: `LunaStationReconnectTest`, same method names.
@MainActor @Suite struct LunaStationReconnectTests {
    private static let studio = LunaStationNetwork(ssid: "Studio", password: "synthetic1", hotspot: false)
    private static let known = LunaStationHost(network: "Studio", hotspot: false, host: "192.168.1.31", serial: "LUNA-A")
    private static let anotherCamera = ConnectionFailure.luna(
        .wrongCamera, "wifi.serial-mismatch", "another camera", phase: .negotiating)

    /// What the connect did: the addresses opened directly, and how often the camera was moved.
    @MainActor private final class Connect {
        var directFailure: Error?
        var reached = false
        private(set) var opened: [LunaStationHost] = []
        private(set) var moves = 0

        func run(
            known: LunaStationHost?, network: LunaStationNetwork = LunaStationReconnectTests.studio,
            inUse: Set<String> = []
        ) async throws -> LunaStationReconnect.Path {
            try await LunaStationReconnect.run(
                known: known, network: network, inUse: inUse, reached: { self.reached },
                direct: { host in
                    self.opened.append(host)
                    if let failure = self.directFailure { throw failure }
                },
                move: { self.moves += 1 })
        }
    }

    @Test func aCameraAnsweringAtItsKnownAddressIsNeverMovedOverBluetooth() async throws {
        let connect = Connect()
        #expect(try await connect.run(known: Self.known) == .direct)
        #expect(connect.opened == [Self.known] && connect.moves == 0)
    }

    @Test func aCameraWithoutAKnownAddressOnThisNetworkIsMoved() async throws {
        let elsewhere = LunaStationHost(network: "Office", hotspot: false, host: "192.168.1.31", serial: "LUNA-A")
        let otherKind = LunaStationHost(network: "Studio", hotspot: true, host: "172.20.10.3", serial: "LUNA-A")
        let unproven = LunaStationHost(network: "Studio", hotspot: false, host: "192.168.1.31", serial: "")
        for known in [nil, elsewhere, otherKind, unproven] {
            let connect = Connect()
            #expect(try await connect.run(known: known) == .bluetooth)
            #expect(connect.opened.isEmpty && connect.moves == 1)
        }
    }

    @Test func aKnownAddressAnotherConnectionHoldsIsNeverTried() async throws {
        let connect = Connect()
        #expect(try await connect.run(known: Self.known, inUse: ["192.168.1.31"]) == .bluetooth)
        #expect(connect.opened.isEmpty && connect.moves == 1)
    }

    @Test func anotherCameraOrNoAnswerAtTheKnownAddressMovesTheCamera() async throws {
        let silent = ConnectionFailure.luna(.notFound, "station.known-host-silent", "no answer", phase: .link)
        for failure in [Self.anotherCamera, silent] {
            let connect = Connect()
            connect.directFailure = failure
            #expect(try await connect.run(known: Self.known) == .bluetooth)
            #expect(connect.opened == [Self.known] && connect.moves == 1)
        }
    }

    @Test func localNetworkAccessOffIsSaidInsteadOfMovingTheCamera() async {
        let connect = Connect()
        connect.directFailure = ConnectionFailure.luna(
            .permission(.localNetwork), "local-network.denied", "off", actions: [.openSettings, .retry])
        await #expect(throws: ConnectionFailure.self) { try await connect.run(known: Self.known) }
        #expect(connect.moves == 0)
    }

    @Test func cancellationIsNotAFallback() async {
        let connect = Connect()
        connect.directFailure = CancellationError()
        await #expect(throws: CancellationError.self) { try await connect.run(known: Self.known) }
        #expect(connect.moves == 0)
    }

    @Test func aDropAfterTheCameraWentLiveEndsTheConnect() async {
        let connect = Connect()
        connect.reached = true
        connect.directFailure = ConnectionFailure.luna(.linkLost, "link.dropped", "dropped")
        await #expect(throws: ConnectionFailure.self) { try await connect.run(known: Self.known) }
        #expect(connect.moves == 0, "a live camera that dropped is not moved over Bluetooth")
    }
}
