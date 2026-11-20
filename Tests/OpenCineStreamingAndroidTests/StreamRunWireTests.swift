import Foundation
import OpenCineCore
@testable import OpenCineStreaming
import Testing

@testable import OpenCineStreamingAndroid

/// The Android wire over `StreamRun`: what the Kotlin shell receives for each input.
@Suite struct StreamRunWireTests {
    private static let format =
        #"{"width":1280,"height":720,"fpsNum":30,"fpsDen":1,"videoBitrateBps":3000000,"keyframeIntervalSeconds":2,"audioBitrateBps":160000,"audioSampleRate":48000,"audioChannels":2}"#

    private func json(_ text: String) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    private func owner(_ wire: StreamRunWire, key: String = "SECRETKEY") throws -> String {
        let reply = try json(
            wire.create(
                presetID: "custom", enteredServerURL: "rtmps://live.example.com/app", streamKey: key,
                formatJSON: Self.format, nowNs: 0))
        return try #require(reply["owner"] as? String)
    }

    @Test func encodesEveryActionInOrderThenTheStatus() {
        let status = StreamRun.Status(
            phase: .reconnecting(attempt: 2), liveSince: MonotonicInstant(.nanoseconds(5)),
            sentBitrateBps: 7, videoBitrateBps: 3_000_000, droppedVideoGroups: 1, droppedAudioPackets: 2,
            health: .offline)
        let bytes = StreamRunWire.encode(
            [
                .connect(host: "h", port: 443), .write([9, 8]), .disconnect, .setVideoBitrate(258),
                .requestKeyframe, .wake(at: MonotonicInstant(.nanoseconds(1_000_000_001))),
            ], status: status)
        let expected: [UInt8] =
            [1, 0x01, 0xBB, 0, 1, 0x68]
            + [2, 0, 0, 0, 2, 9, 8]
            + [3]
            + [4, 0, 0, 1, 2]
            + [5]
            + [6, 0, 0, 0, 0, 0x3B, 0x9A, 0xCA, 0x01]
            + [127, 2, 0, 0, 0, 2, 0, 0, 0]
            + [0, 0, 0, 0, 0, 0, 0, 5]
            + [0, 0, 0, 7, 0, 0x2D, 0xC6, 0xC0, 0, 0, 0, 1, 0, 0, 0, 2, 2]
        #expect(bytes == expected)
    }

    @Test func endedStatusCarriesTheReason() {
        let status = StreamRun.Status(
            phase: .ended(.refused(reason: "No")), liveSince: nil, sentBitrateBps: 0, videoBitrateBps: 0,
            droppedVideoGroups: 0, droppedAudioPackets: 0, health: .offline)
        let bytes = StreamRunWire.encode([], status: status)
        #expect(Array(bytes.prefix(12)) == [127, 3, 0, 0, 0, 0, 2, 0, 2, 0x4E, 0x6F, 0xFF])
    }

    @Test func startRepliesConnectThenStatus() throws {
        let wire = StreamRunWire()
        let id = try owner(wire)
        let reply = wire.start(owner: id)
        let connect: [UInt8] = [1, 0x01, 0xBB, 0, 16] + Array("live.example.com".utf8)
        #expect(Array(reply.prefix(connect.count)) == connect)
        #expect(reply[connect.count] == 127)
        #expect(reply[connect.count + 1] == 0)
    }

    @Test func connectedWritesTheHandshake() throws {
        let wire = StreamRunWire()
        let id = try owner(wire)
        _ = wire.start(owner: id)
        let reply = wire.connected(owner: id, nowNs: 1)
        #expect(Array(reply.prefix(5)) == [2, 0, 0, 0x06, 0x01])
        #expect(reply[5] == 3)
        #expect(reply[5 + 1537] == 127)
    }

    @Test func wakeCarriesNanoseconds() throws {
        let wire = StreamRunWire()
        let id = try owner(wire)
        _ = wire.start(owner: id)
        _ = wire.connected(owner: id, nowNs: 0)
        let reply = wire.connectionLost(owner: id, nowNs: 500)
        #expect(Array(reply.prefix(10)) == [3, 6, 0, 0, 0, 0, 0x3B, 0x9A, 0xCB, 0xF4])
        #expect(reply[10] == 127)
        #expect(Array(reply[11...15]) == [2, 0, 0, 0, 1])
    }

    @Test func unknownOwnerRepliesEnded() throws {
        let wire = StreamRunWire()
        for reply in [
            wire.start(owner: "nobody"), wire.tick(owner: "nobody", nowNs: 1),
            wire.publishAudio(owner: "nobody", raw: [1], presentMs: 0, nowNs: 1),
        ] {
            #expect(Array(reply.prefix(7)) == [127, 3, 0, 0, 0, 0, 1])
        }
        let id = try owner(wire)
        wire.close(owner: id)
        #expect(Array(wire.stop(owner: id, nowNs: 2).prefix(7)) == [127, 3, 0, 0, 0, 0, 1])
    }

    @Test func stopClosesTheRun() throws {
        let wire = StreamRunWire()
        let id = try owner(wire)
        _ = wire.start(owner: id)
        let reply = wire.stop(owner: id, nowNs: 3)
        #expect(reply.first == 3)
        #expect(Array(reply[1...7]) == [127, 3, 0, 0, 0, 0, 1])
    }

    @Test func badDestinationNamesTheError() throws {
        let wire = StreamRunWire()
        let cases: [(String, String, String, String)] = [
            ("custom", "https://live.example.com/app", "k", "notRTMPS"),
            ("custom", "rtmps://live.example.com", "k", "invalidServerURL"),
            ("custom", "rtmps://live.example.com/app", "  ", "emptyKey"),
            ("custom", "rtmps://live.example.com/app", "rtmps://x/y", "keyLooksLikeURL"),
            ("instagram", "rtmp://live.example.com/app", "k", "notRTMPS"),
            ("nope", "rtmps://live.example.com/app", "k", "unknownPreset"),
        ]
        for (preset, server, key, error) in cases {
            let created = try json(
                wire.create(
                    presetID: preset, enteredServerURL: server, streamKey: key, formatJSON: Self.format, nowNs: 0))
            #expect(created["error"] as? String == error)
            let checked = try json(wire.checkDestination(presetID: preset, enteredServerURL: server, streamKey: key))
            #expect(checked["error"] as? String == error)
        }
        let badFormat = try json(
            wire.create(presetID: "twitch", enteredServerURL: "", streamKey: "k", formatJSON: "{}", nowNs: 0))
        #expect(badFormat["error"] as? String == "invalidFormat")
    }

    @Test func tlsFollowsTheScheme() throws {
        let wire = StreamRunWire()
        let preset = try json(
            wire.create(presetID: "twitch", enteredServerURL: "", streamKey: "k", formatJSON: Self.format, nowNs: 0))
        #expect(preset["tls"] as? Bool == true)
        let checked = try json(
            wire.checkDestination(presetID: "custom", enteredServerURL: "rtmps://live.example.com/app", streamKey: "k"))
        #expect(checked["ok"] as? Bool == true)
        #expect(checked["tls"] as? Bool == true)
        let plain = try json(
            wire.checkDestination(presetID: "custom", enteredServerURL: "rtmp://live.example.com/app", streamKey: "k"))
        #expect(plain["ok"] as? Bool == true)
        #expect(plain["tls"] as? Bool == false)
        let plainRun = try json(
            wire.create(
                presetID: "custom", enteredServerURL: "RTMP://live.example.com/app", streamKey: "k",
                formatJSON: Self.format, nowNs: 0))
        #expect(plainRun["tls"] as? Bool == false)
        let id = try #require(plainRun["owner"] as? String)
        let connect: [UInt8] = [1, 0x07, 0x8F, 0, 16] + Array("live.example.com".utf8)
        #expect(Array(wire.start(owner: id).prefix(connect.count)) == connect)
    }

    @Test func presetsEndWithCustom() throws {
        let presets = try #require(
            JSONSerialization.jsonObject(with: Data(StreamRunWire().presetsJSON().utf8)) as? [[String: Any]])
        #expect(presets.map { $0["id"] as? String } == (StreamServicePreset.all + [.custom]).map(\.id))
        let instagram = try #require(presets.first { $0["id"] as? String == "instagram" })
        #expect(instagram["portrait"] as? Bool == true)
        #expect(instagram["requiresServerEntry"] as? Bool == true)
        #expect(instagram["serverURL"] is NSNull)
        let twitch = try #require(presets.first)
        #expect(twitch["maxVideoBitrateBps"] as? Int == 6_000_000)
        #expect(twitch["allowsPlainRTMP"] as? Bool == false)
        #expect(presets.last?["allowsPlainRTMP"] as? Bool == true)
        #expect((twitch["keyHint"] as? String)?.isEmpty == false)
    }

    @Test func formatFollowsTheSourceAndPreset() throws {
        let wire = StreamRunWire()
        let hd = try json(
            try #require(
                wire.formatJSON(
                    presetID: "youtube", selectedWidth: 1280, selectedHeight: 720, fpsNum: 25, fpsDen: 1,
                    connected: [1920, 1080])))
        #expect(hd["width"] as? Int == 1920)
        #expect(hd["fpsNum"] as? Int == 25)
        #expect(hd["videoBitrateBps"] as? Int == 6_000_000)
        let vertical = try json(
            try #require(
                wire.formatJSON(
                    presetID: "instagram", selectedWidth: 1280, selectedHeight: 720, fpsNum: 0, fpsDen: 0,
                    connected: [])))
        #expect(vertical["width"] as? Int == 720)
        #expect(vertical["height"] as? Int == 1280)
        #expect(vertical["fpsNum"] as? Int == 30)
        #expect(wire.formatJSON(presetID: "nope", selectedWidth: 1, selectedHeight: 1, fpsNum: 0, fpsDen: 0, connected: []) == nil)
        let created = try json(
            wire.create(
                presetID: "custom", enteredServerURL: "rtmps://h/a", streamKey: "k",
                formatJSON: try #require(
                    wire.formatJSON(
                        presetID: "twitch", selectedWidth: 1280, selectedHeight: 720, fpsNum: 30, fpsDen: 1,
                        connected: [])), nowNs: 0))
        #expect(created["owner"] is String)
    }

    @Test func canStreamFollowsTheRoute() {
        let wire = StreamRunWire()
        #expect(["usbCable", "captureCard", "sharedWiFi", "deviceHotspot"].allSatisfy(wire.canStream(route:)))
        #expect(!wire.canStream(route: "cameraWiFi"))
        #expect(!wire.canStream(route: ""))
    }

    @Test func keyIsInNoReplyOrJSON() throws {
        let wire = StreamRunWire()
        let key = "SECRETKEY"
        let created = wire.create(
            presetID: "custom", enteredServerURL: "rtmps://live.example.com/app", streamKey: key,
            formatJSON: Self.format, nowNs: 0)
        #expect(!created.contains(key))
        let id = try owner(wire, key: key)
        var replies = [wire.start(owner: id), wire.connected(owner: id, nowNs: 0)]
        replies.append(wire.connectionLost(owner: id, nowNs: 1))
        for reply in replies {
            #expect(reply.firstRange(of: Array(key.utf8)) == nil)
        }
        #expect(!wire.checkDestination(presetID: "custom", enteredServerURL: "rtmps://h/a", streamKey: key).contains(key))
    }
}
