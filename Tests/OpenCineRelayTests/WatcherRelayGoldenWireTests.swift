import Foundation
import OpenCineRelay
import Testing

/// Golden wire for protocol version 1: every message kind, framed exactly as shipped watchers
/// and hosts send it. Header bytes and the frame blob are exact. JSON bodies are the text a
/// version 1 peer emits; they must decode to the same values, and re-encoding must produce the
/// same JSON object (key order is Foundation's choice, so it is compared as an object).
/// Changing a golden here is a wire break: bump `WatcherRelayProtocol.version` instead.
@Suite struct WatcherRelayGoldenWireTests {
    @Test func versionOneConstants() {
        #expect(WatcherRelayProtocol.version == 1)
        #expect(WatcherRelayProtocol.serviceType == "_opc-mon._tcp")
        #expect(WatcherRelayProtocol.maximumPayloadBytes == 8_388_608)
        #expect(WatcherRelayProtocol.txtCamera == "c" && WatcherRelayProtocol.txtWatchable == "w")
        #expect(WatcherRelayProtocol.hevcCodec == 1)
        #expect(WatcherRelayFraming.headerBytes == 5)
        let kinds: [(WatcherRelayProtocol.Kind, UInt8)] = [
            (.hello, 0x01), (.state, 0x02), (.frame, 0x03), (.controlToken, 0x04),
            (.joinDenied, 0x05), (.requestControl, 0x10), (.releaseControl, 0x11), (.command, 0x12),
        ]
        for (kind, raw) in kinds { #expect(kind.rawValue == raw) }
    }

    @Test func hello() throws {
        try check(
            .hello,
            #"{"version":1,"hostName":"Host","cameraName":"Cam","passcode":"1234","watcherID":"w1"}"#,
            WatcherRelayHello(hostName: "Host", cameraName: "Cam", passcode: "1234", watcherID: "w1"))
        try check(.hello, #"{"version":1,"hostName":"Pat"}"#, WatcherRelayHello(hostName: "Pat"))
    }

    @Test func state() throws {
        try check(
            .state,
            #"{"isRecording":true,"format":"4K 25","color":"Log","zoom":"2×","liveFPS":"25","#
                + #""batteryPercent":80,"cameraName":"Cam","iso":"400","shutter":"1/50","#
                + #""allowsControlRequests":true,"controlOptions":{"isoIndices":[1,2],"#
                + #""shutterDenominators":[50,100],"zoomHundredths":[100,200]},"#
                + #""cameraModel":"Model","isNano":false}"#,
            WatcherRelayState(
                isRecording: true, format: "4K 25", color: "Log", zoom: "2×", liveFPS: "25",
                batteryPercent: 80, cameraName: "Cam", iso: "400", shutter: "1/50",
                allowsControlRequests: true,
                controlOptions: WatcherRelayControlOptions(
                    isoIndices: [1, 2], shutterDenominators: [50, 100], zoomHundredths: [100, 200]),
                cameraModel: "Model", isNano: false))
    }

    @Test func controlToken() throws {
        try check(
            .controlToken, #"{"holderName":"Pat","holderIsRecipient":true}"#,
            WatcherRelayControlToken(holderName: "Pat", holderIsRecipient: true))
    }

    @Test func joinDenied() throws {
        try check(
            .joinDenied, #"{"reason":"Wrong passcode.","passcodeRequired":true}"#,
            WatcherRelayJoinDenied(reason: "Wrong passcode.", passcodeRequired: true))
    }

    @Test func emptyControlRequests() throws {
        for (kind, raw) in [(WatcherRelayProtocol.Kind.requestControl, UInt8(0x10)), (.releaseControl, 0x11)] {
            let wire = Data([0, 0, 0, 1, raw])
            #expect(WatcherRelayFraming.encode(kind: kind, payload: Data()) == wire)
            let decoded = try #require(try WatcherRelayFraming.decode(from: wire))
            #expect(decoded.kind == kind && decoded.payload.isEmpty && decoded.consumedBytes == 5)
        }
    }

    @Test func commands() throws {
        let cases: [(String, WatcherRelayCommand)] = [
            (#"{"toggleRecording":{}}"#, .toggleRecording),
            (#"{"tapFocus":{"cameraX":250,"cameraY":750,"coordinateWidth":1000,"coordinateHeight":1000}}"#,
             .tapFocus(cameraX: 250, cameraY: 750, coordinateWidth: 1000, coordinateHeight: 1000)),
            (#"{"setISO":{"_0":5}}"#, .setISO(5)),
            (#"{"setShutterDenom":{"_0":50}}"#, .setShutterDenom(50)),
            (#"{"setWhiteBalance":{"mode":1,"kelvin":5600,"tint":-3}}"#,
             .setWhiteBalance(mode: 1, kelvin: 5600, tint: -3)),
            (#"{"setColor":{"_0":2}}"#, .setColor(2)),
            (#"{"setZoom":{"_0":150}}"#, .setZoom(150)),
        ]
        for (json, command) in cases { try check(.command, json, command) }
    }

    /// `[u32be metadata length][metadata JSON][Annex-B HEVC]` inside a `.frame` message.
    @Test func frame() throws {
        let meta = #"{"codec":1,"isKeyframe":true,"parameterSets":["AAAAAUA="],"isRecording":true,"#
            + #""extraMirrored":false,"encodedAt":12.5}"#
        let hevc = Data([0, 0, 0, 1, 0x26, 0x01, 0xAF])
        let metaBytes = Data(meta.utf8)
        let blob = bigEndian(metaBytes.count) + metaBytes + hevc
        let wire = bigEndian(blob.count + 1) + Data([0x03]) + blob
        let expected = WatcherRelayFrameMetadata(
            isKeyframe: true, parameterSets: [Data([0, 0, 0, 1, 0x40])], isRecording: true,
            encodedAt: 12.5)

        let decoded = try #require(try WatcherRelayFraming.decode(from: wire))
        #expect(decoded.kind == .frame && decoded.consumedBytes == wire.count)
        let (outMeta, outHevc) = try WatcherRelayFrameBlob.decode(decoded.payload)
        #expect(outMeta == expected)
        #expect(outHevc == hevc)

        let encoded = try WatcherRelayFrameBlob.encode(metadata: expected, hevc: hevc)
        let length = encoded.prefix(4).reduce(0) { $0 << 8 | Int($1) }
        try expectSameJSON(encoded.subdata(in: 4..<(4 + length)), metaBytes)
        #expect(encoded.suffix(hevc.count) == hevc)
        #expect(WatcherRelayFraming.encode(kind: .frame, payload: blob) == wire)
    }

    /// Old and new peers on version 1: a newer peer's extra keys are ignored, an older peer's
    /// missing optional keys decode as nil, and another version is denied before the passcode.
    @Test func oldAndNewClientsOnVersionOne() throws {
        let future = Data(#"{"version":1,"hostName":"A","laterField":true}"#.utf8)
        #expect(try JSONDecoder().decode(WatcherRelayHello.self, from: future)
            == WatcherRelayHello(hostName: "A"))
        let accept = WatcherRelayJoin.hostAccepts(
            hello: WatcherRelayHello(hostName: "A", passcode: "1"), requiredPasscode: "1",
            versionMismatchReason: "Update")
        #expect((try? accept.get()) != nil)
        let v2 = WatcherRelayJoin.hostAccepts(
            hello: WatcherRelayHello(version: 2, hostName: "A", passcode: "1"),
            requiredPasscode: "1", versionMismatchReason: "Update")
        #expect(throws: WatcherRelayJoinDenied(reason: "Update", passcodeRequired: false)) {
            try v2.get()
        }
    }

    private func check<T: Codable & Equatable>(
        _ kind: WatcherRelayProtocol.Kind, _ json: String, _ value: T
    ) throws {
        let body = Data(json.utf8)
        let wire = bigEndian(body.count + 1) + Data([kind.rawValue]) + body
        #expect(WatcherRelayFraming.encode(kind: kind, payload: body) == wire)
        let decoded = try #require(try WatcherRelayFraming.decode(from: wire))
        #expect(decoded.kind == kind && decoded.consumedBytes == wire.count)
        #expect(try JSONDecoder().decode(T.self, from: decoded.payload) == value)
        try expectSameJSON(try JSONEncoder().encode(value), body)
    }

    private func expectSameJSON(_ a: Data, _ b: Data) throws {
        let lhs = try JSONSerialization.jsonObject(with: a) as? NSDictionary
        let rhs = try JSONSerialization.jsonObject(with: b) as? NSDictionary
        #expect(lhs != nil && lhs == rhs, "\(String(decoding: a, as: UTF8.self))")
    }

    private func bigEndian(_ n: Int) -> Data {
        Data([UInt8(n >> 24 & 0xFF), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)])
    }
}

/// Optional means optional: no other Core product imports OpenCineRelay, and it imports
/// Foundation only and names no manufacturer or app. Its Apple shell, OpenCineRelayApple,
/// adds Apple networking and encoding frameworks and nothing else; the watch companion,
/// OpenCineWatch, adds WatchConnectivity, the watch and phone UI frameworks and OpenCineApple.
@Suite struct RelayImportRules {
    @Test func relayIsOptionalAndNeutral() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let brands = try Regex(
            #"\b(dji|osmo|nikon|zcine|insta360|insta|luna|pocket|sony|canon|blackmagic|gopro|openpocketcine|openinstacine)\b"#
        ).ignoresCase()
        let sources = root.appending(path: "Sources")
        for target in try FileManager.default.contentsOfDirectory(atPath: sources.path()) {
            let directory = sources.appending(path: target)
            for name in (try? FileManager.default.contentsOfDirectory(atPath: directory.path())) ?? []
            where name.hasSuffix(".swift") {
                let text = try String(contentsOf: directory.appending(path: name), encoding: .utf8)
                if target == "OpenCineRelay" {
                    for line in text.split(separator: "\n") where line.hasPrefix("import ") {
                        #expect(["import Foundation", "import OpenCineCore"].contains(String(line)), "\(name): \(line)")
                    }
                    #expect(text.firstMatch(of: brands) == nil, "\(name) names a brand")
                } else if target == "OpenCineRelayApple" {
                    var allowed: Set<String> = [
                        "Foundation", "OpenCineRelay", "Network", "Observation", "CoreMedia",
                        "CoreVideo", "VideoToolbox", "os",
                        // The relay passcodes live in the Keychain.
                        "Security",
                    ]
                    if name == "RelayAppleImageEncoder.swift" || name == "RelayAppleImageDecoder.swift"
                        || name == "RelayAppleBroadcastPipeline.swift"
                    {
                        allowed.insert("CoreGraphics")
                    }
                    if name == "RelayAppleImageDecoder.swift" {
                        allowed.insert("CoreImage")
                    }
                    for line in text.split(separator: "\n") {
                        let trimmed = line.trimmingCharacters(in: .whitespaces)
                        guard trimmed.hasPrefix("import ") else { continue }
                        let module = String(trimmed.dropFirst(7))
                        #expect(allowed.contains(module), "\(name): \(trimmed)")
                    }
                    #expect(text.firstMatch(of: brands) == nil, "\(name) names a brand")
                    let first = text.split(separator: "\n").first.map(String.init) ?? ""
                    #expect(
                        first.hasPrefix("#if canImport("), "\(name) is not gated to its platform")
                    #expect(!text.contains("\u{2014}"), "\(name) has an em dash")
                } else if target == "OpenCineWatch" {
                    var allowed: Set<String> = [
                        "Foundation", "OpenCineCore", "OpenCineRelay", "OpenCineApple", "WatchConnectivity", "SwiftUI",
                        "WatchKit", "UIKit", "CoreImage", "CoreVideo", "VideoToolbox", "os",
                    ]
                    if name == "WatchMonitorPresentation.swift" {
                        allowed = ["Foundation", "OpenCineCore"]
                    } else if name == "WatchUIImagePreviewEncoder.swift" {
                        allowed.formUnion(["ImageIO", "UniformTypeIdentifiers"])
                    }
                    for line in text.split(separator: "\n") {
                        let trimmed = line.trimmingCharacters(in: .whitespaces)
                        guard trimmed.hasPrefix("import ") else { continue }
                        let module = String(trimmed.dropFirst(7))
                        #expect(allowed.contains(module), "\(name): \(trimmed)")
                    }
                    #expect(text.firstMatch(of: brands) == nil, "\(name) names a brand")
                    let first = text.split(separator: "\n").first.map(String.init) ?? ""
                    if name == "WatchMonitorPresentation.swift" {
                        #expect(first == "import Foundation", "\(name) is not portable presentation")
                    } else {
                        #expect(first.hasPrefix("#if os("), "\(name) is not gated to its platform")
                    }
                    #expect(!text.contains("\u{2014}"), "\(name) has an em dash")
                } else if target == "OpenCineAppKitApple", name == "MonitorWatcherSource.swift" {
                    let allowed: Set<String> = [
                        "Foundation", "Network", "Observation", "MonitorPresentation",
                        "OpenCineRelay", "OpenCineRelayApple", "OpenCineApple",
                    ]
                    for line in text.split(separator: "\n") {
                        let trimmed = line.trimmingCharacters(in: .whitespaces)
                        guard trimmed.hasPrefix("import ") else { continue }
                        #expect(allowed.contains(String(trimmed.dropFirst(7))), "\(name): \(trimmed)")
                    }
                    #expect(text.firstMatch(of: brands) == nil, "\(name) names a brand")
                    #expect(text.hasPrefix("#if os(iOS)"), "\(name) is not platform-gated")
                    #expect(!text.contains("\u{2014}"), "\(name) has an em dash")
                } else {
                    #expect(!text.contains("OpenCineRelay"), "\(target)/\(name) uses OpenCineRelay")
                }
            }
        }
    }
}
