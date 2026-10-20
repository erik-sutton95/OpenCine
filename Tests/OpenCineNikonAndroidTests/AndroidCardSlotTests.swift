import Foundation
import OpenCineNikon
import Testing

@testable import OpenCineNikonAndroid

// ZT-04 / ZT-05 follow-ups: a pulled card cannot leave its count on the shots counter, and a
// photo-mode flip while live view streams still points remote releases at the stills card.
struct AndroidCardSlotTests {
    private static let slotOne: UInt32 = 0x0001_0001
    private static let slotTwo: UInt32 = 0x0002_0001

    private func twoCardServer(
        activeSlot: FakeZRSlotDescriptor? = nil
    ) throws -> FakeZRServer {
        var options = FakeZRServer.Options()
        options.storageCards = [
            FakeZRStorageCard(
                storageID: Self.slotOne, totalCapacityBytes: 512_000_000_000,
                freeSpaceBytes: 100_000_000_000, freeSpaceInImages: 300),
            FakeZRStorageCard(
                storageID: Self.slotTwo, totalCapacityBytes: 256_000_000_000,
                freeSpaceBytes: 200_000_000_000, freeSpaceInImages: 900),
        ]
        options.slotDescriptors[PTPPropertyCode.primarySlot.rawValue] =
            FakeZRSlotDescriptor(current: 1, values: [1, 2])
        if let activeSlot {
            options.slotDescriptors[PTPPropertyCode.activeSlot.rawValue] = activeSlot
        }
        return try FakeZRServer(options: options)
    }

    private func connect(to server: FakeZRServer) throws -> PTPIPClientSession {
        try PTPIPClientSession.connect(
            host: "127.0.0.1", port: server.port, timeoutMilliseconds: 2_000)
    }

    @Test func aPulledCardDoesNotKeepItsCountOnTheShotsCounter() throws {
        let server = try twoCardServer()
        defer { server.stop() }
        let session = try connect(to: server)
        defer { session.disconnect() }

        let seeded = session.refreshAndroidPropertySnapshot(.bootstrap)
        #expect(seeded.properties.stillsCardShots == 300)
        #expect(seeded.properties.shotsRemaining == 300)

        server.setStorageCards([])
        let emptied = session.refreshAndroidPropertySnapshot(.bootstrap)
        #expect(emptied.storageSlots.isEmpty)
        #expect(emptied.properties.stillsCardShots == nil)
        #expect(emptied.properties.shotsRemaining == emptied.properties.cameraShotsRemaining)
    }

    @Test func aPhotoFlipDuringLiveViewPointsReleasesAtTheStillsCard() throws {
        let server = try twoCardServer(
            activeSlot: FakeZRSlotDescriptor(current: 2, values: [1, 2]))
        defer { server.stop() }
        let session = try connect(to: server)
        defer { session.disconnect() }

        // Connected in video: the storage read does not touch ActiveSlot.
        _ = session.refreshAndroidPropertySnapshot(.bootstrap)
        let activeSlotWrites = {
            server.receivedPropertyWrites().filter {
                $0.property == PTPPropertyCode.activeSlot.rawValue
            }
        }
        #expect(activeSlotWrites().isEmpty)

        let firstFrame = DispatchSemaphore(value: 0)
        try session.startLiveView(onFrame: { _, _ in firstFrame.signal() }, onEnded: {})
        defer { session.stopLiveView() }
        #expect(firstFrame.wait(timeout: .now() + .seconds(5)) == .success)

        server.setCameraProperty(.liveViewSelector, data: Data([0]))
        let flipped = session.refreshAndroidPropertySnapshot(.selector)
        #expect(flipped.properties.captureSelector == .photo)
        // The flip's value queue drains in bounded chunks; one storage read follows it.
        for _ in 0..<12 where activeSlotWrites().isEmpty {
            _ = session.refreshAndroidPropertySnapshot(.next(isRecording: false))
        }
        #expect(activeSlotWrites().map(\.data) == [Data([1])])
        #expect(activeSlotWrites().first?.operation == .setDevicePropValue)

        // Later ticks while streaming do not repeat the storage read.
        let storageReads = server.receivedOperations().filter { $0 == .getStorageInfo }.count
        for _ in 0..<4 {
            _ = session.refreshAndroidPropertySnapshot(.next(isRecording: false))
        }
        #expect(server.receivedOperations().filter { $0 == .getStorageInfo }.count == storageReads)
    }

    @Test func aFailedStorageReadAfterAPhotoFlipIsRetriedOnALaterTick() throws {
        let server = try twoCardServer(
            activeSlot: FakeZRSlotDescriptor(current: 2, values: [1, 2]))
        defer { server.stop() }
        let session = try connect(to: server)
        defer { session.disconnect() }
        _ = session.refreshAndroidPropertySnapshot(.bootstrap)
        let activeSlotWrites = {
            server.receivedPropertyWrites().filter {
                $0.property == PTPPropertyCode.activeSlot.rawValue
            }
        }

        let firstFrame = DispatchSemaphore(value: 0)
        try session.startLiveView(onFrame: { _, _ in firstFrame.signal() }, onEnded: {})
        defer { session.stopLiveView() }
        #expect(firstFrame.wait(timeout: .now() + .seconds(5)) == .success)

        // The body is busy for the flip's first storage read (both cards refused).
        server.rejectStorageInfoReads(2)
        server.setCameraProperty(.liveViewSelector, data: Data([0]))
        _ = session.refreshAndroidPropertySnapshot(.selector)
        var storageAttempts = 0
        for _ in 0..<12 where activeSlotWrites().isEmpty {
            _ = session.refreshAndroidPropertySnapshot(.next(isRecording: false))
            storageAttempts = server.receivedOperations().filter { $0 == .getStorageInfo }.count
        }
        #expect(activeSlotWrites().map(\.data) == [Data([1])])
        // Bootstrap read two cards, the refused attempt two, the retry two.
        #expect(storageAttempts == 6)
    }
}
