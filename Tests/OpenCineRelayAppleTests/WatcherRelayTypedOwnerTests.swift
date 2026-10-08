import Foundation
import Network
import OpenCineRelay
import XCTest

@testable import OpenCineRelayApple

@available(macOS 14, *)
@MainActor final class WatcherRelayTypedOwnerTests: XCTestCase {
    func testRealPeerAdmissionDeliversTypedCommandAndReclaimRetiresCapturedConfirmation()
        async throws
    {
        let host = makeHost()
        host.start(
            hostName: "Host", cameraName: "Camera", passcode: "", ceilingIndex: 0,
            allowsControl: true)
        defer { host.stop() }
        let transport = try XCTUnwrap(host.transport)
        let delivered = expectation(description: "actual typed peer command")
        var receipt: WatcherRelayCommandDelivery?
        host.onCommand = { value in
            receipt = value
            delivered.fulfill()
        }
        try transport.queue.sync { try admitAndCommand(transport) }
        await fulfillment(of: [delivered], timeout: 2)
        let captured = try XCTUnwrap(receipt)
        XCTAssertTrue(host.admits(captured))
        host.reclaimControl()
        XCTAssertFalse(
            host.admits(captured),
            "A queued confirmation must retire before the transport queue runs reclaim")
        transport.queue.sync {}
        XCTAssertFalse(host.admits(captured))
    }

    func testQueuedTypedCommandCannotCrossStopAndSameNameReplacement() async throws {
        let host = makeHost()
        host.start(
            hostName: "Host", cameraName: "Camera", passcode: "", ceilingIndex: 0,
            allowsControl: true)
        defer { host.stop() }
        let transport = try XCTUnwrap(host.transport)
        let unexpected = expectation(description: "old peer command")
        unexpected.isInverted = true
        host.onCommand = { _ in unexpected.fulfill() }
        try transport.queue.sync { try admitAndCommand(transport) }
        host.stop()
        host.start(
            hostName: "Host", cameraName: "Camera", passcode: "", ceilingIndex: 0,
            allowsControl: true)
        await fulfillment(of: [unexpected], timeout: 0.1)
        let replacement = try XCTUnwrap(host.transport)
        XCTAssertFalse(transport === replacement)
        let delivered = expectation(description: "successor actual peer command")
        host.onCommand = { value in
            XCTAssertTrue(host.admits(value))
            delivered.fulfill()
        }
        try replacement.queue.sync { try admitAndCommand(replacement) }
        await fulfillment(of: [delivered], timeout: 2)
    }

    func testQueuedCommandCannotCrossActualCameraSourceRetirement() async throws {
        let host = makeHost()
        host.start(
            hostName: "Host", cameraName: "Camera", passcode: "", ceilingIndex: 0,
            allowsControl: true)
        defer { host.stop() }
        let transport = try XCTUnwrap(host.transport)
        let unexpected = expectation(description: "old camera source command")
        unexpected.isInverted = true
        host.onCommand = { _ in unexpected.fulfill() }
        try transport.queue.sync { try admitAndCommand(transport) }
        host.retireSource()
        await fulfillment(of: [unexpected], timeout: 0.1)
        transport.queue.sync {}
        XCTAssertNil(host.applyCommand(.toggleRecording, from: "saved-watcher"))
    }

    private func makeHost() -> WatcherRelayHost {
        WatcherRelayHost(
            versionMismatchReason: "version", logSubsystem: "com.opencapture.opencine.tests",
            journal: { _ in })
    }
    private nonisolated func admitAndCommand(_ transport: WatcherRelayTransport) throws {
        let peer = WatcherRelayTransport.Peer(
            conn: NWConnection(host: "127.0.0.1", port: 9000, using: .tcp))
        transport.peers[ObjectIdentifier(peer)] = peer
        try transport.onMessage(
            peer: peer,
            msg: .init(
                kind: .hello,
                payload: JSONEncoder().encode(
                    WatcherRelayHello(hostName: "Watcher", watcherID: "saved-watcher")),
                consumedBytes: 0))
        try transport.onMessage(
            peer: peer, msg: .init(kind: .requestControl, payload: Data(), consumedBytes: 0))
        transport.grantControl()
        try transport.onMessage(
            peer: peer,
            msg: .init(
                kind: .command,
                payload: JSONEncoder().encode(WatcherRelayCommand.toggleRecording), consumedBytes: 0
            ))
    }
}
