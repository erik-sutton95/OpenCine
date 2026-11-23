import Foundation
import OpenCineCore
import OpenCineDJI
import Testing

@testable import OpenCineDJIApple

/// The livestream provisioning sequence over a scripted link. SIMULATED: no Bluetooth; every reply
/// is scripted and every pause is recorded, never slept.
@MainActor @Suite struct DJICameraStreamPublisherTests {
    enum Reply {
        case payload([UInt8])
        case none
    }

    @MainActor final class Link: DJILivestreamLink {
        var sequence: UInt16 = 100
        var sent: [Duml.Frame] = []
        /// Replies per `set/id`, in order; a missing entry answers `00` (a join `00 00`).
        var replies: [String: [Reply]] = [:]
        var closed = false

        func next() -> UInt16 {
            sequence &+= 1
            return sequence
        }

        func exchange(_ frame: Duml.Frame, timeout: TimeInterval) async throws -> Duml.Frame {
            sent.append(frame)
            let key = String(format: "%02X/%02X", frame.cmdSet, frame.cmdId)
            var queue = replies[key] ?? []
            let reply = queue.isEmpty ? Reply.payload(key == "07/47" ? [0, 0] : [0]) : queue.removeFirst()
            replies[key] = queue
            switch reply {
            case .none: throw MultiviewFailure.timeout
            case .payload(let bytes):
                return Duml.Frame(sender: 8, receiver: 2, seq: frame.seq, flags: 0x80, cmdSet: frame.cmdSet,
                    cmdId: frame.cmdId, payload: bytes)
            }
        }

        func closeAndWait() async { closed = true }

        var names: [String] { sent.map { String(format: "%02X/%02X", $0.cmdSet, $0.cmdId) } }
    }

    static let url = "rtmp://172.20.10.1:1935/live/0123456789abcdef0123456789abcdef"
    static let password = "hunter2-wifi"

    final class Record: @unchecked Sendable {
        var log: [String] = []
        var pauses: [Duration] = []
    }

    func publisher(_ link: Link, model: String = "Osmo Pocket 4 Pro", record: Record = Record()) -> DJICameraStreamPublisher {
        DJICameraStreamPublisher(
            link: link, model: CameraModel(name: model), log: { record.log.append($0) },
            sleep: { record.pauses.append($0) })
    }

    func start(_ publisher: DJICameraStreamPublisher, codec: LivestreamCommands.Codec = .hevc) async throws {
        try await publisher.start(
            url: Self.url, ssid: "es_iphone16", password: Self.password, frameRate: 30, codec: codec)
    }

    @Test func startSendsTheProvenSequence() async throws {
        let link = Link()
        let record = Record()
        try await start(publisher(link, record: record))
        #expect(link.names == ["02/8E", "02/E1", "07/47", "08/78", "02/8E"])
        #expect(link.sent[0].payload == LivestreamCommands.end(seq: 0).payload)
        #expect(link.sent[4].payload == LivestreamCommands.start(seq: 0).payload)
        let preset = LivestreamCommands.preset(frameRate: 30, bitrateKbps: 6000)
        let configure = try LivestreamCommands.configureJSON(url: Self.url, preset: preset, codec: .hevc, seq: 0)
        #expect(link.sent[3].payload == configure.payload)
        #expect(record.pauses == [.seconds(1)])
        #expect(!link.closed)
    }

    @Test func pocket3ConfiguresTheDirectAddress() async throws {
        let link = Link()
        try await start(publisher(link, model: "Osmo Pocket 3"), codec: .h264)
        let preset = LivestreamCommands.preset(frameRate: 30, bitrateKbps: 6000)
        #expect(link.sent[3].payload == (try LivestreamCommands.configureDirectURL(url: Self.url, preset: preset, seq: 0)).payload)
    }

    @Test func joinRetriesOn01FFThenSucceeds() async throws {
        let link = Link()
        link.replies["07/47"] = [.payload([0x01, 0xFF]), .payload([0x00, 0x00])]
        let record = Record()
        try await start(publisher(link, record: record))
        #expect(link.names == ["02/8E", "02/E1", "07/47", "07/47", "08/78", "02/8E"])
        #expect(record.pauses == [.seconds(1), .seconds(MulticamJoinPolicy.retryDelaySeconds)])
    }

    @Test func aRejectedJoinStopsBeforeConfiguring() async {
        let link = Link()
        link.replies["07/47"] = [.payload([0x01, 0x02])]
        await #expect(throws: DJICameraStreamError.joinRefused([0x01, 0x02])) { try await start(publisher(link)) }
        #expect(link.names == ["02/8E", "02/E1", "07/47"])
    }

    @Test func startRefusalCarriesTheReply() async {
        let link = Link()
        link.replies["02/8E"] = [.payload([0]), .payload([0xD6])]
        await #expect(throws: DJICameraStreamError.startRefused([0xD6])) { try await start(publisher(link)) }
    }

    @Test func aCameraThatStopsAnsweringIsNoReply() async {
        let link = Link()
        link.replies["02/E1"] = [.none]
        await #expect(throws: DJICameraStreamError.noReply) { try await start(publisher(link)) }
        // The cleanup end needs no reply.
        let quiet = Link()
        quiet.replies["02/8E"] = [.none]
        await #expect(throws: Never.self) { try await start(publisher(quiet)) }
    }

    @Test func endAlwaysClosesTheLink() async {
        let link = Link()
        link.replies["02/8E"] = [.none]
        await publisher(link).end()
        #expect(link.names == ["02/8E"])
        #expect(link.sent[0].payload == LivestreamCommands.end(seq: 0).payload)
        #expect(link.closed)
    }

    @Test func logHoldsNoSecret() async throws {
        let link = Link()
        let record = Record()
        let publisher = publisher(link, record: record)
        try await start(publisher)
        await publisher.end()
        let text = record.log.joined(separator: "\n")
        #expect(!record.log.isEmpty)
        #expect(!text.contains(Self.password))
        #expect(!text.contains("0123456789abcdef0123456789abcdef"))
        #expect(!text.contains("01234"))
        #expect(text.contains("0123****"))
    }
}
