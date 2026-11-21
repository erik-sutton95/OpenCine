import Foundation

// Bluetooth commands that make an Osmo publish its own RTMP stream (Pocket 3, Pocket 4, Pocket 4 Pro).
//
// Evidence: the OpenPocketCine handbook's Mimo captures of Pocket 3 and Pocket 4 Pro, and a Pocket 4 Pro
// hardware run on 2026-11-21. Wire-format reference, not copied: Moblin (github.com/eerimoq/moblin, MIT
// licence, Copyright (c) Erik Moqvist), `DjiDeviceMessage.swift` `DjiStartStreamingMessagePayload`
// (Pocket 3) and `DjiStartStreamingMessagePayload2` (Pocket 4). Moblin's message type 0x780840 is flags
// 0x40, cmdSet 0x08, cmdId 0x78 here. Goldens: `Fixtures/dji-livestream-frames.tsv`.

/// Livestream provisioning: enter livestream mode, configure the RTMP target, start and end. All go to
/// receiver `08`; the Wi-Fi join between them is `MulticamCommands.join` (receiver `07`).
public enum LivestreamCommands {
    public enum Failure: Error, Equatable { case urlTooLong }

    public enum Codec: String, CaseIterable, Sendable {
        case h264 = "AVC"
        case hevc = "HEVC"
    }

    /// `02/E1 1A`: livestream shooting mode (the same frame as `MulticamCommands.prepare`).
    public static func prepare(seq: UInt16) -> Duml.Frame {
        MulticamCommands.prepare(seq: seq)
    }

    /// `02/8E 01 01 1A 00 01 01`: start publishing (parameter `0x001A`, value 01).
    public static func start(seq: UInt16) -> Duml.Frame {
        frame(0x02, 0x8E, [0x01, 0x01, 0x1A, 0x00, 0x01, 0x01], seq)
    }

    /// `02/8E 01 01 1A 00 01 02`: end publishing. Also the cleanup sent before every start.
    public static func end(seq: UInt16) -> Duml.Frame {
        frame(0x02, 0x8E, [0x01, 0x01, 0x1A, 0x00, 0x01, 0x02], seq)
    }

    /// The nine encoder preset bytes: 1080p (`0A`), bitrate in kbps (u16le), two mode bytes, the
    /// frame-rate code (25 is 2, 30 is 3, others unmapped as 0), three zeros. Pocket 3's Mimo capture
    /// at 1080p, 25 fps, 6000 kbps is `0A 70 17 02 01 02 00 00 00`.
    public static func preset(frameRate: Int, bitrateKbps: UInt16, modeBytes: (UInt8, UInt8) = (0x02, 0x01))
        -> [UInt8]
    {
        let rate: UInt8 =
            switch frameRate {
            case 25: 2
            case 30: 3
            default: 0
            }
        return [0x0A, UInt8(bitrateKbps & 0xFF), UInt8(bitrateKbps >> 8), modeBytes.0, modeBytes.1, rate, 0, 0, 0]
    }

    /// `08/78` version 00 (Pocket 3): `00 [bodyLen u16le] [preset] [urlLen u16le] [url]`.
    public static func configureDirectURL(url: String, preset: [UInt8], seq: UInt16) throws -> Duml.Frame {
        let bytes = Array(url.utf8)
        guard bytes.count <= 0xFF else { throw Failure.urlTooLong }
        let body = preset + le16(bytes.count) + bytes
        return frame(0x08, 0x78, [0x00] + le16(body.count) + body, seq)
    }

    /// `08/78` version 01 (Pocket 4, Pocket 4 Pro): `01 [bodyLen u16le] [preset] [jsonLen u16le] [json]`.
    public static func configureJSON(url: String, preset: [UInt8], codec: Codec, seq: UInt16) throws -> Duml.Frame {
        guard url.utf8.count <= 0xFF else { throw Failure.urlTooLong }
        let json = Array(settingsJSON(url: url, codec: codec).utf8)
        let body = preset + le16(json.count) + json
        return frame(0x08, 0x78, [0x01] + le16(body.count) + body, seq)
    }

    /// The JSON keys in the order the camera was sent them on hardware. Slashes are escaped as
    /// Foundation's JSONEncoder (Moblin's encoder) escapes them. HEVC goes over Enhanced RTMP.
    static func settingsJSON(url: String, codec: Codec) -> String {
        let escaped = url.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "/", with: "\\/")
        return "{\"rtmpAddress\":\"\(escaped)\",\"codec\":\"\(codec.rawValue)\",\"EnhancedRTMP\":\(codec == .hevc),"
            + "\"supportStopLive\":false,\"watermark\":0,\"orientation\":\"landscape\"}"
    }

    private static func le16(_ value: Int) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)]
    }

    private static func frame(_ set: UInt8, _ id: UInt8, _ payload: [UInt8], _ seq: UInt16) -> Duml.Frame {
        Duml.Frame(sender: 2, receiver: 8, seq: seq, flags: 0x40, cmdSet: set, cmdId: id, payload: payload)
    }
}
