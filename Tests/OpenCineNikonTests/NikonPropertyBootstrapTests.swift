import Foundation
import Testing

@testable import OpenCineNikon

@MainActor
@Suite("Nikon selector-first monitor bootstrap")
struct NikonPropertyBootstrapTests {
    @Test("Initial reads precede storage and descriptors, and bootstrap never sets the clock")
    func orderedReads() async {
        let link = BootstrapLink()
        let bootstrap = NikonPropertyBootstrap(link: link)
        var observations: [PTPPropertyCode] = []
        await bootstrap.run(
            isCurrent: { true },
            receive: { observation in
                if case .property(let property, _) = observation { observations.append(property) }
            })
        #expect(observations.first == .liveViewSelector)
        let expected = PTPPropertyCode.monitorPollOrder(isRecording: false, captureSelector: .video)
            .filter { $0 != .liveViewSelector }
        #expect(observations.dropFirst().elementsEqual(expected))
        #expect(link.calls.first == "read liveViewSelector")
        #expect(link.calls.firstIndex(of: "storage")! > expected.count)
        #expect(link.calls.last == "read dateTime")
        #expect(link.clockWrites == 0)
        await bootstrap.consumeStagedClock(recording: nil)
        #expect(link.clockWrites == 0)
        await bootstrap.consumeStagedClock(recording: true)
        await bootstrap.consumeStagedClock(recording: false)
        #expect(link.clockWrites == 0)
    }

    @Test("An idle authoritative header permits one clock write after initial reads")
    func idleClockOnce() async {
        let link = BootstrapLink()
        let bootstrap = NikonPropertyBootstrap(link: link)
        await bootstrap.run(isCurrent: { true }, receive: { _ in })
        await bootstrap.consumeStagedClock(recording: false)
        await bootstrap.consumeStagedClock(recording: false)
        #expect(link.clockWrites == 1)
    }

    @Test("Retirement during a read drops its observation and all later bootstrap work")
    func retirementDropsRead() async {
        let link = BootstrapLink()
        var current = true
        link.afterRead = { current = false }
        var observations = 0
        await NikonPropertyBootstrap(link: link).run(
            isCurrent: { current },
            receive: { _ in
                observations += 1
            })
        #expect(observations == 0)
        #expect(link.calls == ["read liveViewSelector"])
        #expect(link.clockWrites == 0)
    }
}

@MainActor
private final class BootstrapLink: NikonBootstrapLink {
    var calls: [String] = []
    var clockWrites = 0
    var afterRead: () -> Void = {}
    func supportsProperty(_ property: PTPPropertyCode) -> Bool { true }
    func readCameraProperty(_ property: PTPPropertyCode) async throws -> Data {
        calls.append("read \(property)")
        afterRead()
        if property == .dateTime {
            return CameraClockSync.encode(
                .init(year: 2000, month: 1, day: 1, hour: 0, minute: 0, second: 0))
        }
        return property == .liveViewSelector ? Data([1]) : Data()
    }
    func writeCameraProperty(_ write: PTPCameraPropertyWrite) async throws {
        if write.property == .dateTime { clockWrites += 1 }
    }
    func changeCameraMode(remote: Bool) async throws { calls.append("mode") }
    func readStorageInfo() async throws -> PTPStorageInfo? {
        calls.append("storage")
        return nil
    }
    func describeCameraPropertyEnum(_ property: PTPPropertyCode, valueByteCount: Int) async throws
        -> [UInt32]
    {
        calls.append("descriptor \(property)")
        return []
    }
    func screenSizeModes() async throws -> [PTPCameraScreenSizeMode] {
        calls.append("screen")
        return []
    }
    func fileTypeModes() async throws -> [PTPCameraFileTypeMode] {
        calls.append("file")
        return []
    }
    func controlOptions(for property: PTPPropertyCode, valueByteCount: Int) async throws -> [String]
    {
        calls.append("options \(property)")
        return []
    }
    func stringEnumOptions(for property: PTPPropertyCode) async throws -> [String] {
        calls.append("string \(property)")
        return []
    }
}
