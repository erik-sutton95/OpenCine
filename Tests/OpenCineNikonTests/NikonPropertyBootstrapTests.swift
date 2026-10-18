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

    @Test("Each per-codec tone descriptor is reported after the codecs, by the body's own values")
    func movieToneDescriptors() async {
        let link = BootstrapLink()
        link.toneEnum = [0, 2, 1, 9]
        var tones: [PTPPropertyCode: [NikonMovieTone]] = [:]
        await NikonPropertyBootstrap(link: link).run(
            isCurrent: { true },
            receive: { observation in
                if case .movieTones(let property, let offered) = observation {
                    tones[property] = offered
                }
            })
        #expect(Set(tones.keys) == Set(NikonMovieToneCapability.toneProperties))
        #expect(tones[.movieH265ToneMode] == [.sdr, .hlg, .nLog])
        let file = link.calls.firstIndex(of: "file")!
        let tone = link.calls.firstIndex(of: "descriptor \(PTPPropertyCode.movieH265ToneMode)")!
        #expect(tone > file)
    }

    @Test("Stabilization bootstrap preserves pending and read-only empty descriptor facts")
    func stabilizationDescriptorFacts() async throws {
        let link = BootstrapLink()
        // Use the actual property identity in a standard scalar UINT8 empty enumeration.
        let code = PTPPropertyCode.movieVibrationReduction.rawValue
        let bytes = [UInt8(code & 255), UInt8((code >> 8) & 255), 2, 0, 0, 0, 0, 2, 0, 0]
        let descriptor = try #require(
            NikonScalarPropertyDescriptor.parse(
                Data(bytes), property: code, valueByteCount: 1))
        link.descriptorObservation = .init(outcome: .described, descriptor: descriptor)
        var received: [NikonDescriptorObservation] = []
        await NikonPropertyBootstrap(link: link).run(isCurrent: { true }) {
            if case .descriptor(.movieVibrationReduction, let evidence) = $0 {
                received.append(evidence)
            }
        }
        #expect(received.map(\.outcome) == [.pending, .described])
        #expect(received.last?.capability.support == .supported)
        #expect(received.last?.capability.access == .readOnly)
        #expect(received.last?.capability.offer == [])
        #expect(received.last?.descriptor?.form == .enumeration([]))
    }

    @Test("Known discovery omission stays missing with unknown support and sends no describe")
    func discoveryOmissionIsNotUnsupported() async {
        let link = BootstrapLink()
        link.omittedProperties = [.movieVibrationReduction, .electronicVR]
        var received: [NikonDescriptorObservation] = []
        await NikonPropertyBootstrap(link: link).observeStabilizationDescriptors(
            isCurrent: { true },
            receive: {
                if case .descriptor(_, let observation) = $0 { received.append(observation) }
            })
        #expect(received.map(\.outcome) == [.missing, .missing])
        #expect(
            received.allSatisfy { $0.capability.support == .unknown && $0.capability.offer == nil })
        #expect(link.calls.isEmpty)
    }

    @Test("Retirement during stabilization describe drops the completed observation")
    func retirementDropsDescriptor() async {
        let link = BootstrapLink()
        var current = true
        link.afterDescriptor = { current = false }
        var outcomes: [NikonDescriptorReadOutcome] = []
        await NikonPropertyBootstrap(link: link).run(isCurrent: { current }) {
            if case .descriptor(_, let evidence) = $0 { outcomes.append(evidence.outcome) }
        }
        #expect(outcomes == [.pending])
        #expect(link.calls.last == "scalar movieVibrationReduction")
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
    var toneEnum: [UInt32] = []
    var descriptorObservation = NikonDescriptorObservation(outcome: .malformed)
    var afterDescriptor: () -> Void = {}
    func observeCameraPropertyDescriptor(
        _ property: PTPPropertyCode, valueByteCount: Int
    ) async -> NikonDescriptorObservation {
        calls.append("scalar \(property)")
        afterDescriptor()
        return descriptorObservation
    }
    var omittedProperties: Set<PTPPropertyCode> = []
    func supportsProperty(_ property: PTPPropertyCode) -> Bool {
        !omittedProperties.contains(property)
    }
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
        return NikonMovieToneCapability.toneProperties.contains(property) ? toneEnum : []
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
