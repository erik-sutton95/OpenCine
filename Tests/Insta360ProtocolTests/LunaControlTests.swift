import Foundation
import XCTest
@testable import Insta360Protocol

// Every hex constant below is a protobuf body copied from the official Insta360
// iOS app (2.33.0) talking to Luna Ultra v1.0.288 (captures/20260910T215020…
// reconnect and the 20260916 official-* takes). Camera serials, GPS, client
// UUIDs and calibration strings are not included.

private func hex(_ value: String) -> Data {
    let clean = value.filter { !$0.isWhitespace }
    return Data(stride(from: 0, to: clean.count, by: 2).map { offset in
        let start = clean.index(clean.startIndex, offsetBy: offset)
        return UInt8(clean[start..<clean.index(start, offsetBy: 2)], radix: 16)!
    })
}

private func blob(_ field: Int, _ value: Data) throws -> Data { try ProtoMessage.blob(field: field, value: value) }
private func float(_ bits: UInt32) -> Double { Double(Float(bitPattern: bits)) }

final class LunaOfficialSetTests: XCTestCase {
    func testPhotographySetsMatchOfficialBytes() throws {
        let cases: [(LunaRequest, String)] = [
            (try LunaProtocol.setGimbalFollowSpeed(.fast), "0a015b1211a20100aa0100f80101c00501da050210031807"),
            (try LunaProtocol.setGimbalMode(.fpv), "0a015b1211a20100aa0100f80101c00501da050220011807"),
            (try LunaProtocol.setGimbalMode(.rollLock), "0a015b1211a20100aa0100f80101c00501da050220021807"),
            (try LunaProtocol.setGimbalMode(.rollAndTiltLock), "0a015b1211a20100aa0100f80101c00501da050220031807"),
            (try LunaProtocol.setGimbalMode(.fpvVertical), "0a015b1211a20100aa0100f80101c00501da050220041807"),
            (try LunaProtocol.setVideoExposure(program: .isoPriority, iso: 160),
             "0a0215641214a20100aa0105080110a001f80101c00501a006021807"),
            (try LunaProtocol.setVideoExposure(program: .automatic),
             "0a021564120fa20100aa0100f80101c00501a006021807"),
            (try LunaProtocol.setVideoExposure(program: .shutterPriority, shutterSeconds: 0.02),
             "0a031518641221a20100aa010b0802197b14ae47e17a943fc00180e7ffff0ff80101c00501a006021807"),
            (try LunaProtocol.setVideoExposure(program: .shutterPriority, shutterSeconds: 1.0 / 5000),
             "0a031518641221a20100aa010b0802192d431cebe2362a3fc00180e7ffff0ff80101c00501a006021807"),
            (try LunaProtocol.setVideoExposure(program: .manual, shutterSeconds: 0.02),
             "0a031518641221a20100aa010b0803197b14ae47e17a943fc00180e7ffff0ff80101c00501a006021807"),
            (try LunaProtocol.setExposureBias(0.3), "0a0107120e3806a20100aa0100f80101c005011807"),
            (try LunaProtocol.setColorMode(.standard), "0a0123120fa20100aa0100f80101980201c005011807"),
            (try LunaProtocol.setColorMode(.iLog), "0a0123120fa20100aa0100f80101980202c005011807"),
            (try LunaProtocol.setColorMode(.dolbyVision), "0a0123120fa20100aa0100f80101980205c005011807"),
            (try LunaProtocol.setZoomScale(1), "0a01351216a20100aa0100f80101a903000000000000f03fc005011807"),
            (try LunaProtocol.setZoomScale(2), "0a01351216a20100aa0100f80101a9030000000000000040c005011807"),
            (try LunaProtocol.setZoomScale(3), "0a01351216a20100aa0100f80101a9030000000000000840c005011807"),
            (try LunaProtocol.setZoomScale(6), "0a01351216a20100aa0100f80101a9030000000000001840c005011807"),
            (try LunaProtocol.setRecordResolution(52), "0a021f3f120ca20100aa0100f80134c005011807"),
            (try LunaProtocol.setRecordResolution(48), "0a021f3f120ca20100aa0100f80130c005011807"),
            (try LunaProtocol.setRecordResolution(24), "0a021f3f120ca20100aa0100f80118c005011807"),
            (try LunaProtocol.setRecordResolution(454), "0a021f3f120da20100aa0100f801c603c005011807"),
            (try LunaProtocol.setRecordResolution(211), "0a021f3f120da20100aa0100f801d301c005011807"),
            (try LunaProtocol.setWhiteBalanceKelvin(2000), "0a01271210a20100aa0100f80101b802d00fc005011807"),
            (try LunaProtocol.setWhiteBalanceKelvin(2400), "0a01271210a20100aa0100f80101b802e012c005011807"),
            (try LunaProtocol.setWhiteBalanceAuto(), "0a0127120ca20100aa0100f80101c005011807"),
            (try LunaProtocol.setSharpness(2), "0a0106120e3002a20100aa0100f80101c005011807"),
            (try LunaProtocol.setTapFocus(x: float(0x3ED8_6FB6), y: float(0x3D5E_0A00),
                                          width: float(0x3E1E_412A), height: float(0x3E8C_ABB3)),
             "0a015e1225a20100aa0100f80101c00501f20516080115b66fd83e1d000a5e3d252a411e3e2db3ab8c3e1807"),
            (try LunaProtocol.setTapFocus(x: float(0x3E8B_A2E9), y: 0,
                                          width: float(0x3E1E_412A), height: float(0x3E32_4079)),
             "0a015e1220a20100aa0100f80101c00501f20511080115e9a28b3e252a411e3e2d7940323e1807"),
        ]
        for (request, expected) in cases {
            XCTAssertEqual(request.command, .setPhotographyOptions)
            XCTAssertEqual(request.body, hex(expected), expected)
        }
    }

    /// fw 1.1.15 verified on the camera (docs/research/luna-fw-1.1.15-verification.md).
    func testAutofocusAndMeteringSets() throws {
        XCTAssertEqual(try LunaProtocol.setAFMode(.single).body, hex("0a015d120fa20100aa0100f80101c00501e805011807"))
        XCTAssertEqual(try LunaProtocol.setAFMode(.continuous).body, hex("0a015d120fa20100aa0100f80101c00501e805031807"))
        XCTAssertEqual(try LunaProtocol.setAFMode(.productShowcase, functionMode: 6).body,
                       hex("0a015d120fa20100aa0100f80101c00501e805061806"))
        XCTAssertEqual(try LunaProtocol.setFaceMetering(true).body, hex("0a012e120fa20100aa0100f80101f00201c005011807"))
        // Matrix is an explicit 0; the camera stores it.
        XCTAssertEqual(try LunaProtocol.setFaceMetering(false).body, hex("0a012e120fa20100aa0100f80101f00200c005011807"))
        // A requested 46 that proto3 omits reads as Matrix; an unrequested one stays unknown.
        XCTAssertEqual(try LunaPhotographySettings(response: hex("082e1200")).faceMetering, false)
        XCTAssertNil(try LunaPhotographySettings(response: hex("085d1200")).faceMetering)
        XCTAssertEqual(try LunaPhotographySettings(response: hex("082e085d1206f00200e80506")).autofocus,
                       .productShowcase)
    }

    func testSourceBackedSetsUseSameShape() throws {
        XCTAssertEqual(try LunaProtocol.setPhotographyValue(.gammaMode, 17).body,
                       hex("0a0112120f900111a20100aa0100f80101c005011807"))
        let manual = try LunaSettingsProbe.nested(LunaProtocol.setManualExposure(iso: 400, shutterSeconds: 0.01))
        XCTAssertEqual(manual.videoExposure?.exposureProgram, .manual)
        XCTAssertEqual(manual.videoExposure?.iso, 400)
        XCTAssertEqual(manual.videoExposure?.shutterSeconds, 0.01)
        // fw v1.1.15 regression: the ISO top-limit sentinel converted this to
        // program 2 and dropped ISO 400. Types 21,100 were stored as sent.
        XCTAssertNil(manual.isoTopLimit)
        XCTAssertEqual(try LunaProtocol.setManualExposure(iso: 400, shutterSeconds: 0.02).body,
                       hex("0a021564121da20100aa010e0803109003197b14ae47e17a943ff80101c00501a006021807"))
        // sint32: negative EV encodes as zigzag, not a clamped zero.
        XCTAssertEqual(try LunaSettingsProbe.nested(LunaProtocol.setExposureBias(-1.0)).exposureBiasTenths, -10)
        XCTAssertEqual(try LunaSettingsProbe.nested(LunaProtocol.setExposureBias(-0.3)).exposureBiasStops, -0.3)
        XCTAssertThrowsError(try LunaProtocol.setExposureBias(5))
        XCTAssertThrowsError(try LunaProtocol.setZoomScale(0.5))
        // fw v1.1.15 regression: omitted FOV 33 was ignored (stayed 1); explicit 0 stored.
        XCTAssertEqual(try LunaProtocol.setPhotographyValue(.fovType, 0).body,
                       hex("0a0121120fa20100aa0100f80101880200c005011807"))
        // fw v1.1.15 stores up to 15x; 15.5 and 20 are ignored by the camera.
        XCTAssertEqual(try LunaSettingsProbe.nested(LunaProtocol.setZoomScale(15)).zoom, 15)
        XCTAssertThrowsError(try LunaProtocol.setZoomScale(15.5))
        XCTAssertThrowsError(try LunaProtocol.setVideoExposure(program: .shutterPriority, shutterSeconds: 0))
        XCTAssertThrowsError(try LunaProtocol.setTapFocus(x: 1.5, y: 0))
    }

    func testShootingModesMatchOfficialDeviceSets() throws {
        let cases: [(LunaShootingMode, String)] = [
            (.video, "0a0129120c08012880f702d00201900503"),
            (.timelapse, "0a0129120f08012880f702c80202d00201900503"),
            (.timeShift, "0a0129120f08012880f702c80204d00201900503"),
            (.slowMotion, "0a0129120f08012880f702c80209d00201900503"),
            (.pureVideo, "0a0129120f08012880f702c8020bd00201900503"),
            (.photo, "0a0128120c08012880f702d00201900503"),
            (.pano, "0a0128120f08012880f702c00208d00201900503"),
        ]
        for (mode, expected) in cases {
            let request = try mode.request()
            XCTAssertEqual(request.command, .setOptions)
            XCTAssertEqual(request.body, hex(expected), "\(mode)")
        }
        XCTAssertEqual(LunaShootingMode.timeShift.functionMode, .timeShift)
        XCTAssertEqual(LunaShootingMode.pano.functionMode.rawValue, 67)
        XCTAssertEqual(LunaShootingMode(photoSubMode: 100, videoSubMode: 9), .slowMotion)
        XCTAssertEqual(LunaShootingMode(photoSubMode: 0, videoSubMode: 100), .photo)
        XCTAssertNil(LunaShootingMode(photoSubMode: 100, videoSubMode: 7))
    }

    func testFirmware1115CaptureBodiesPerMode() throws {
        let stop = "0a196a0230019a0100aa0100ba0100d20100e20200ba0400820a00"
        XCTAssertEqual(try LunaProtocol.startCaptureRequest(for: .video).body, hex("0801"))
        XCTAssertEqual(try LunaProtocol.startCaptureRequest(for: .timeShift).body, hex("0804"))
        XCTAssertEqual(try LunaProtocol.startCaptureRequest(for: .slowMotion).body, hex("0809"))
        XCTAssertEqual(try LunaProtocol.stopCaptureRequest(for: .video).body, hex(stop + "1001"))
        XCTAssertEqual(try LunaProtocol.stopCaptureRequest(for: .slowMotion).body, hex(stop + "1009"))
        XCTAssertEqual(try LunaProtocol.stopCaptureRequest(for: .video).command, .stopCapture)
        let lapseStart = try LunaProtocol.startCaptureRequest(for: .timelapse)
        XCTAssertEqual(lapseStart.command, .startTimelapse)
        XCTAssertEqual(lapseStart.body, hex("0801"))
        let lapseStop = try LunaProtocol.stopCaptureRequest(for: .timelapse)
        XCTAssertEqual(lapseStop.command, .stopTimelapse)
        XCTAssertEqual(lapseStop.body, hex("080112196a0230019a0100aa0100ba0100d20100e20200ba0400820a00"))
    }

    func testDeepTrackStreamFrames() throws {
        // Captured 0x85 media payloads (fw 1.1.15): idle before tracking, then locked.
        func packet(_ payload: String) throws -> LunaMediaPacket {
            try LunaMediaPacket(frame: UCD2Frame.plain(type: UCD2Frame.mediaType, sequence: 0, payload: hex(payload)))
        }
        let idle = try XCTUnwrap(try packet(
            "85f83881020000000008c0919ac69c011005180022140d8988e03e1519357c3e1defee1e3e25dc14a33e").trackFrame)
        XCTAssertEqual(idle.state, .idle)
        let locked = try XCTUnwrap(try packet(
            "852a4c83020000000008908886879d011002180022140d2222b23e15316af83e1dabaa1a3e25b6608b3e").trackFrame)
        XCTAssertEqual(locked.state, .tracking)
        XCTAssertEqual(locked.x, 0.348, accuracy: 0.001)
        XCTAssertEqual(locked.y, 0.485, accuracy: 0.001)
        XCTAssertEqual(locked.width, 0.151, accuracy: 0.001)
        XCTAssertEqual(locked.height, 0.272, accuracy: 0.001)
        XCTAssertNil(try packet("40ea4a830200000000277576f01b78843f").trackFrame)
    }

    func testFirmware1115PhotoModeWrites() throws {
        let photo = LunaFunctionMode.normalImage.rawValue
        let still = try ProtoMessage(LunaProtocol.setVideoExposure(
            program: .shutterPriority, shutterSeconds: 1.0 / 8000, functionMode: photo).body)
        let video = try ProtoMessage(LunaProtocol.setVideoExposure(
            program: .shutterPriority, shutterSeconds: 1.0 / 8000).body)
        XCTAssertEqual(try still.bytes(1), hex("141518" + "64"))
        XCTAssertEqual(try video.bytes(1), hex("151864"))
        let ev = try ProtoMessage(LunaProtocol.setExposureBias(1, functionMode: photo).body)
        XCTAssertEqual(try ev.bytes(1), hex("074d"))
        XCTAssertEqual(
            try ProtoMessage(LunaProtocol.setRecordResolution(27).body).bytes(1), hex("1f3f23"))
        XCTAssertEqual(LunaVideoResolution(rawValue: 443)?.framesPerSecond, 30)
        XCTAssertEqual(LunaVideoResolution(rawValue: 444)?.height, 2688)
    }

    func testGimbalAbsoluteAngle() throws {
        let set = try LunaProtocol.gimbalSetAngle(pitch: 10, yaw: -20)
        XCTAssertEqual(set.command, .gimbalControl)
        XCTAssertEqual(set.body, hex("08052a0a15000020411d0000a0c1"))
        XCTAssertEqual(try LunaProtocol.gimbalSetAngle(pitch: 0, yaw: 0).body, hex("08052a00"))
        XCTAssertEqual(try LunaProtocol.gimbalGetAngleRequest().body, hex("0806"))
        let reply = try LunaGimbalAngle(response: hex("080015000000001da57100c125738a04c0"))
        XCTAssertEqual(reply.grf, 0)
        XCTAssertEqual(reply.roll, 0)
        XCTAssertEqual(reply.pitch, -8.03, accuracy: 0.01)
        XCTAssertEqual(reply.yaw, -2.07, accuracy: 0.01)
        XCTAssertEqual(try LunaGimbalAngle(response: Data()), LunaGimbalAngle(pitch: 0, yaw: 0))
        XCTAssertThrowsError(try LunaProtocol.gimbalSetAngle(pitch: .nan, yaw: 0))
    }

    func testGimbalTrackingCaptureAndMediaRequests() throws {
        XCTAssertEqual(try LunaProtocol.gimbalMove(upDown: 99, leftRight: 0).body, hex("0801120308c6012004"))
        XCTAssertEqual(try LunaProtocol.gimbalControl(action: .move, upDown: 99, field4: 4).body,
                       hex("0801120308c6012004"))
        XCTAssertEqual(try LunaProtocol.gimbalControl(action: .move, field4: 4).body, hex("080112002004"))
        XCTAssertEqual(try LunaProtocol.gimbalControl(action: .move, upDown: 99, leftRight: 41, field4: 4).body,
                       hex("0801120508c60110522004"))
        let track = try LunaProtocol.openTracking(
            x: float(0x3F05_3C82), y: 0, width: float(0x3E04_A790), height: float(0x3E68_09A7),
            timestampMilliseconds: 1_789_558_454_687)
        XCTAssertEqual(track.command, .openTracking)
        XCTAssertEqual(track.body, hex("089ff3fbcf8a3415823c053f2590a7043e2da709683e"))
        XCTAssertEqual(LunaProtocol.cancelTrackingRequest.body, Data())
        XCTAssertEqual(try LunaProtocol.takePicture(mode: .gimbalPano).body, hex("0805"))
        XCTAssertEqual(try LunaProtocol.takePicture(mode: .normal).body, Data())
        XCTAssertEqual(LunaProtocol.stopLiveRequest.body, Data())
        XCTAssertEqual(LunaProtocol.startCaptureRequest.body, hex("0801"))

        let jpg = "/storage_internal/DCIM/Camera01/IMG_20260916_133503_003.jpg"
        XCTAssertEqual(try LunaProtocol.deleteFiles(jpg).body,
                       hex("0a3b2f73746f726167655f696e7465726e616c2f4443494d2f43616d65726130312f494d475f32303236303931365f3133333530335f3030332e6a7067"))
        XCTAssertEqual(try LunaProtocol.fileExtraRequest(jpg, extraType: .thumbnail).body,
                       try blob(1, Data(jpg.utf8)) + hex("1002"))
        XCTAssertEqual(try LunaProtocol.fileListRequest().body, hex("080218ffffffff072002"))
        XCTAssertEqual(try LunaProtocol.fileListRequest(location: 3).body, hex("080218ffffffff072003"))
        XCTAssertEqual(try LunaProtocol.fileListRequest(mediaType: .dng, location: 3).body, hex("080318ffffffff072003"))
        XCTAssertEqual(try LunaProtocol.fileListRequest(mediaType: .insData).body, hex("080618ffffffff072002"))
        XCTAssertEqual(try LunaProtocol.fileInfoListRequest(location: 2).body, hex("0802"))
        XCTAssertEqual(try LunaProtocol.fileInfoListRequest().body, Data())
        XCTAssertEqual(try LunaProtocol.fileInfoListRequest().command, .getFileInfoList)
    }

    func testOfficialStatusPollsArePacked() throws {
        XCTAssertEqual(try LunaProtocol.statusRequest().body, hex("0a050b1455b401"))
        XCTAssertEqual(try LunaProtocol.shootingModeRequest().body, hex("0a0d2928417c8401528701a901ad01"))
        XCTAssertEqual(try LunaProtocol.storageListRequest().body, hex("0a04b001b101"))
        XCTAssertEqual(try LunaProtocol.remainingTimeRequest().body, hex("0a01631007"))
        XCTAssertEqual(try LunaProtocol.remainingTimeRequest(functionMode: 67).body, hex("0a01631043"))
        let fullGet = hex("0a381f15070d271848531217212b221c262a12122e474735361d373a253b3f3e06493d4b4c464e4f51565758595a5b6a6d23645b5c5d65030468100c")
        let types = try ProtoMessage(fullGet).repeatedUnsigned(1).map(UInt32.init)
        XCTAssertEqual(try LunaProtocol.getPhotographyOptions(types, mode: 12, packed: true).body, fullGet)
        XCTAssertEqual(LunaProtocol.timelapseOptionsRequest.body, hex("0801"))
        XCTAssertEqual(LunaProtocol.darkEISStatusRequest.command.rawValue, 157)
    }
}

/// Decodes a request's nested PhotographyOptions using the reply parser.
private enum LunaSettingsProbe {
    static func nested(_ request: LunaRequest) throws -> LunaPhotographySettings {
        try LunaPhotographySettings(response: try blob(2, ProtoMessage(request.body).bytes(2)))
    }
}

final class LunaStatusDecodeTests: XCTestCase {
    func testVideoModePhotographyReply() throws {
        let reply = hex("""
            081f08150807080d0827081808480853081208170821082b0822081c0826082a08120812082e0847084708350836081d0837083a08
            25083b083f083e08060849083d084b084c0846084e084f08510856085708580859085a085b086a086d08230864085b085c085d0865
            080308040868129e0130013800900100aa010d08001000190000000000000000c00180e7ffff0fe8013cf801d301880200900201980202
            a80200b80200f00201a903000000000000f03fb00300d00301d80300e80300f00300f80300b80400c00400b00501ba05040800100
            0c80500d2050c0d0000000015000000002000da05080802100218032002e20512080010001800200028003000380040004800e80503
            a00601c00603
            """)
        let s = try LunaPhotographySettings(response: reply)
        XCTAssertEqual(s.types.first, 31)
        XCTAssertEqual(s.sharpness, 1)
        XCTAssertEqual(s.exposureBiasTenths, 0)
        XCTAssertEqual(s.exposureBiasStops, 0)
        XCTAssertEqual(s.filter, 0)
        XCTAssertEqual(s.videoExposure, try LunaExposure(hex("08001000190000000000000000")))
        XCTAssertEqual(s.videoExposure?.exposureProgram, .automatic)
        XCTAssertEqual(s.isoTopLimit, LunaProtocol.officialISOTopLimit)
        XCTAssertEqual(s.recordResolution, 211)
        XCTAssertEqual(s.videoResolution?.width, 7680)
        XCTAssertEqual(s.videoResolution?.aspectLabel, "16:9")
        XCTAssertEqual(s.fov, 0)
        XCTAssertEqual(s.color, .iLog)
        XCTAssertEqual(s.whiteBalanceKelvin, 0)
        XCTAssertEqual(s.isAutoWhiteBalance, true)
        XCTAssertEqual(s.zoom, 1.0)
        XCTAssertEqual(s.iLog, false)
        XCTAssertNil(s.colorRecovery)
        XCTAssertEqual(s.gimbal, LunaGimbalOptions(rcSpeed: 2, followSpeed: 2, trackSensitivity: 3, mode: 2))
        XCTAssertEqual(s.gimbal?.gimbalMode, .rollLock)
        XCTAssertEqual(s.gimbalStatus?.stall, false)
        XCTAssertEqual(s.afMode, 3)
        XCTAssertEqual(s.autofocus, .continuous)
        XCTAssertEqual(s.faceMetering, true)
        XCTAssertEqual(s.iq3AMode, 1)
        XCTAssertEqual(s.filterStrength, 3)
        XCTAssertNil(s.functionMode)
    }

    func testPhotoModeReplyAndRemainingTime() throws {
        let photo = try LunaPhotographySettings(response: hex("""
            081a08140807082708180819081b082e083508360822083b083f084d0847085508590846085b08230864085d0865080308040828126538
            00a2010d08001000190000000000000000c00180e7ffff0fc80100d00100d80101900201980202b80200c0021ff00201a90300000000
            0000f03fb00300d80300f80300b80400e80401aa050408001001c80500da05080802100218032002e80503a00601
            """))
        XCTAssertEqual(photo.stillExposure?.program, 0)
        XCTAssertEqual(photo.color, .iLog)
        XCTAssertEqual(photo.photoResolution, 31)
        XCTAssertEqual(LunaPhotoSize(rawValue: 31)?.width, 7680)
        XCTAssertEqual(LunaPhotoSize(rawValue: 34)?.aspectLabel, "4:3")
        XCTAssertNil(photo.videoExposure)

        let remaining = try LunaPhotographySettings(response: hex("0863120f9a060508b91710029a060408001003"))
        XCTAssertEqual(remaining.remainingRecordTime,
                       [LunaRemainingTime(seconds: 3001, location: 2), LunaRemainingTime(seconds: 0, location: 3)])
        // SET success reply lists the applied types.
        XCTAssertEqual(try LunaPhotographySettings(response: hex("081508180864")).types, [21, 24, 100])
    }

    func testResolutionTable() {
        let expected: [UInt64: (Int, Int, Double, String)] = [
            24: (3840, 2160, 30, "16:9"), 43: (1280, 720, 30, "16:9"), 48: (3840, 2160, 25, "16:9"),
            52: (1920, 1080, 25, "16:9"), 211: (7680, 4320, 25, "16:9"), 214: (3840, 2160, 120, "16:9"),
            454: (1728, 3072, 25, "9:16"), 31: (4000, 3000, 30, "4:3"), 1: (2560, 1280, 30, "2:1"),
        ]
        for (raw, (w, h, fps, label)) in expected {
            let r = LunaVideoResolution(rawValue: raw)
            XCTAssertEqual(r?.width, w, "\(raw)")
            XCTAssertEqual(r?.height, h, "\(raw)")
            XCTAssertEqual(r?.framesPerSecond, fps, "\(raw)")
            XCTAssertEqual(r?.aspectLabel, label, "\(raw)")
        }
        XCTAssertEqual(LunaVideoResolution.index.count, 478)  // pinned schema + 443/444 from fw 1.1.15
        XCTAssertNil(LunaVideoResolution(rawValue: 503))
        XCTAssertEqual(LunaVideoResolution.rawValue(width: 3840, height: 2160, framesPerSecond: 25), 48)
        XCTAssertEqual(LunaVideoResolution.rawValue(width: 1728, height: 3072, framesPerSecond: 25), 454)
    }

    func testDeviceStatusBatteryStorageAndMode() throws {
        let reconnect = try LunaDeviceStatus(response: hex(
            "080b0814085508b40112265a06080010102000a201120800108080b0d9bb01188080f88bbc012002a20b06080010421801"))
        XCTAssertEqual(reconnect.battery?.percent, 16)
        XCTAssertEqual(reconnect.battery?.isCharging, false)
        XCTAssertEqual(reconnect.storage?.freeBytes, 50_384_863_232)
        XCTAssertEqual(reconnect.storage?.totalBytes, 50_490_900_480)
        XCTAssertEqual(reconnect.storage?.location, 2)
        XCTAssertEqual(reconnect.storage?.isUsable, true)
        XCTAssertEqual(reconnect.screenBattery?.percent, 66)
        XCTAssertEqual(reconnect.screenConnection, 1)

        let charging = try LunaDeviceStatus(response: hex(
            "080b0814085508b40112265a06080110642000a201120800108080b0d9bb01188080f88bbc012002a20b06080110631801"))
        XCTAssertEqual(charging.battery, try LunaBattery(hex("080110642000")))
        XCTAssertEqual(charging.battery?.percent, 100)
        XCTAssertEqual(charging.battery?.isCharging, true)
        XCTAssertEqual(charging.screenBattery?.percent, 99)
        XCTAssertEqual(charging.screenBattery?.isCharging, true)

        let list = try LunaDeviceStatus(response: hex("""
            080b0814085508440861085208b00108b10112495a06080010102000a201120800108080b0d9bb01188080f88bbc012002a00400900503
            880601820b120800108080b0d9bb01188080f88bbc012002820b080801100018002003880b02
            """))
        XCTAssertEqual(list.storageList.count, 2)
        XCTAssertEqual(list.storageList[1].cardState, 1)
        XCTAssertEqual(list.storageList[1].location, 3)
        XCTAssertEqual(list.storageList[1].isUsable, false)
        XCTAssertEqual(list.cardLocationLastUpdate, 2)

        let video = try LunaDeviceStatus(response: hex(
            "082908280841087c08840108520887011221c00264c80200880401900503e2070c080010001800200028003000a00801b80800"))
        XCTAssertEqual(video.shootingMode, .video)
        let photo = try LunaDeviceStatus(response: hex(
            "082908280841087c08840108520887011221c00200c80264880401900503e2070c080010001800200028003000a00801b80800"))
        XCTAssertEqual(photo.shootingMode, .photo)
    }

    func testCaptureStatus() throws {
        let idle = try LunaCaptureStatus(captureStatusResponse: hex("0a06080010005000"))
        XCTAssertTrue(idle.isIdle)
        XCTAssertFalse(idle.isRecording)
        let recording = try LunaCaptureStatus(captureStatusResponse: hex("0a06080110005005"))
        XCTAssertTrue(recording.isRecording)
        XCTAssertEqual(recording.submode, 5)
        XCTAssertEqual(recording.captureSeconds, 0)
        let photo = try LunaCaptureStatus(captureStatusResponse: hex("0a06080410005000"))
        XCTAssertFalse(photo.isRecording)
        XCTAssertFalse(photo.isIdle)
        XCTAssertTrue(try LunaCaptureStatus(captureStatusResponse: Data()).isIdle)
    }

    func testNotifications() throws {
        func n(_ code: UInt16, _ body: String) throws -> LunaNotification {
            try LunaNotification(message: UCD2Message(code: code, identifier: 1, body: hex(body)))
        }
        XCTAssertEqual(try n(8198, "08001002"), .storage(cardState: 0, location: 2, kind: 0))
        XCTAssertEqual(try n(8234, "080110800a18d00520192801320c080010001800200028003000"),
                       .liveStream(LunaLiveStreamParameters(encodeType: 1, width: 1280, height: 720,
                                                            framesPerSecond: 25, flowStateBase: true)))
        XCTAssertEqual(try n(8234, "080110d00518800a20192801320c080010001800200028003000"),
                       .liveStream(LunaLiveStreamParameters(encodeType: 1, width: 720, height: 1280,
                                                            framesPerSecond: 25, flowStateBase: true)))
        XCTAssertEqual(try n(8248, "18012801323d2f746d702f696e732f696e735f6576656e745f747261636b5f6578706f72745f3230323630393136543132323434325f3134303632353130342e746172"),
                       .trackExport(uri: "/tmp/ins/ins_event_track_export_20260916T122442_140625104.tar", succeeded: true))
        let timeShift = try n(8275, "086410041803")
        XCTAssertEqual(timeShift, .subMode(photo: 100, video: 4, sensor: 3))
        XCTAssertEqual(timeShift.shootingMode, .timeShift)
        XCTAssertEqual(try n(8275, "080810641801").shootingMode, .pano)
        XCTAssertEqual(try n(8298, "08001001"), .livePhoto(errorCode: 0, mode: 1))
        XCTAssertEqual(try n(8308, "0a0408011063"), .screenBattery(try LunaBattery(hex("08011063"))))
        XCTAssertEqual(try n(8315, "0804100218052000"), .tracking(state: 4, endReason: 2, detectCountdown: 5))
        XCTAssertEqual(try n(8317, ""), .afSceneChange)

        guard case let .photographyChanged(change) = try n(8293, "081f1204f801c6031807") else {
            return XCTFail("8293")
        }
        XCTAssertEqual(change.types, [31])
        XCTAssertEqual(change.recordResolution, 454)
        XCTAssertEqual(change.functionMode, 7)
        // fw v1.1.15: 8334 carries the same shape for filter group changes (18, 104).
        guard case let .photographyChanged(filter) = try n(8334, "081208681206900101c006021807") else {
            return XCTFail("8334")
        }
        XCTAssertEqual(filter.types, [18, 104])
        XCTAssertEqual(filter.filter, 1)
        XCTAssertEqual(filter.filterStrength, 2)

        guard case let .captureStatus(pano) = try n(8208, "08203800880113900105") else { return XCTFail("8208") }
        XCTAssertEqual(pano.state, 32)
        XCTAssertEqual(pano.panoFramesTotal, 19)
        XCTAssertEqual(pano.panoFramesDone, 5)
        guard case let .captureStatus(saving) = try n(8208, "080110003802") else { return XCTFail("8208") }
        XCTAssertTrue(saving.isRecording)
        XCTAssertEqual(saving.submode, 2)

        // Source-backed shapes (never captured): battery 8195 and gimbal 8302.
        XCTAssertEqual(try n(8195, "0a0408011032"), .battery(try LunaBattery(hex("08011032"))))
        guard case let .gimbalStatus(gimbal) = try n(8302, "080110011800200028003000380040004800") else {
            return XCTFail("8302")
        }
        XCTAssertTrue(gimbal.rollLimit && gimbal.pitchLimit)
        XCTAssertFalse(gimbal.yawLimit)
        XCTAssertEqual(try n(8199, "0801"), .unknown(code: 8199, body: hex("0801")))
    }

    func testMediaListInfoStopAndThumbnail() throws {
        let list = try LunaProtocol.fileList(response: hex("""
            0a3b2f73746f726167655f696e7465726e616c2f4443494d2f43616d65726130312f4c52565f32303236303931365f3132343232395f
            3030322e6c72760a3b2f73746f726167655f696e7465726e616c2f4443494d2f43616d65726130312f5649445f32303236303931365f
            3132343232395f3030322e6d70340a3b2f73746f726167655f696e7465726e616c2f4443494d2f43616d65726130312f494d475f3230
            3236303931365f3133333530335f3030332e6a70670a3b2f73746f726167655f696e7465726e616c2f4443494d2f43616d6572613031
            2f494d475f32303236303931365f3132343231395f3030312e6a70671004
            """))
        XCTAssertEqual(list.totalCount, 4)
        XCTAssertEqual(list.uris[1], "/storage_internal/DCIM/Camera01/VID_20260916_124229_002.mp4")
        XCTAssertEqual(try LunaProtocol.fileList(response: hex("1000")).uris, [])

        let video = LunaMediaFile(uri: list.uris[1], metadata: nil)
        XCTAssertEqual(video.proxyURI, list.uris[0])
        XCTAssertEqual(video.httpURL()?.absoluteString,
                       "http://192.168.42.1/storage_internal/DCIM/Camera01/VID_20260916_124229_002.mp4")
        XCTAssertNil(LunaMediaFile(uri: list.uris[2], metadata: nil).proxyURI)

        let path = hex("0a3b2f73746f726167655f696e7465726e616c2f4443494d2f43616d65726130312f5649445f32303236303931365f3132343232395f3030322e6d7034")
        let metadata = hex("""
            38c5b4d5e5d5cd0448ecf3f37d50139a010608803c10e021a00119b201087374616e64617264d20132080010001a2a2f4443494d2f4361
            6d65726130312f5649445f32303236303931365f3132343232395f3030322e6d70342000e805b89901a00802
            """)
        let files = try LunaProtocol.fileInfoList(response: blob(1, path + blob(2, metadata)))
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files[0].uri, video.uri)
        let m = try XCTUnwrap(files[0].metadata)
        XCTAssertEqual(m.creationStamp, 20_260_916_124_229)
        XCTAssertEqual(m.creationDate?.hour, 12)
        XCTAssertEqual(m.creationDate?.second, 29)
        XCTAssertEqual(m.fileSize, 264_042_988)
        XCTAssertEqual(m.durationSeconds, 19)
        XCTAssertEqual(m.durationMilliseconds, 19_640)
        XCTAssertEqual(m.width, 7680)
        XCTAssertEqual(m.height, 4320)
        XCTAssertEqual(m.frameRate, 25)
        XCTAssertEqual(m.gammaMode, "standard")
        XCTAssertEqual(m.subMediaType, 0)
        XCTAssertEqual(m.codec, 2)

        let stopped = try LunaProtocol.stoppedVideo(response: blob(1, path))
        XCTAssertEqual(stopped?.uri, video.uri)
        XCTAssertNil(try LunaProtocol.stoppedVideo(response: Data()))

        // Real 40-byte header of a 1280x720 video thumbnail; pixels zero-filled.
        let header = hex("0100000028181500010000000100000000050000d0020000" + String(repeating: "00", count: 16))
        let thumbnail = try LunaThumbnail(response: header + Data(count: 1280 * 720 * 3 / 2))
        XCTAssertEqual(thumbnail.width, 1280)
        XCTAssertEqual(thumbnail.height, 720)
        XCTAssertEqual(thumbnail.nv12.count, 1_382_400)
        XCTAssertThrowsError(try LunaThumbnail(response: header + Data(count: 10)))
        XCTAssertThrowsError(try LunaThumbnail(response: metadata))

        // The camera sends this reply with content type 1 (raw), not 2 (protobuf).
        let reply = try UCD2Message(code: 200, identifier: 24, body: header + Data(count: 1280 * 720 * 3 / 2),
                                    contentType: 1)
        let body = try UCD2Message(payload: reply.payload)
            .successfulResponseBody(for: 24, encrypted: false, requiresEncryption: false)
        XCTAssertEqual(try LunaThumbnail(response: body), thumbnail)
        let unknownType = try UCD2Message(code: 200, identifier: 24, body: body, contentType: 7)
        XCTAssertThrowsError(try unknownType.successfulResponseBody(for: 24, encrypted: false, requiresEncryption: false))
    }

    func testSmallReplies() throws {
        XCTAssertEqual(try LunaProtocol.darkEISStatus(response: hex("0801")), 1)
        let timelapse = try LunaProtocol.timelapseOptions(response: hex("0a05080010e807"))
        XCTAssertEqual(timelapse.durationSeconds, 0)
        XCTAssertEqual(timelapse.intervalMilliseconds, 1000)
        XCTAssertEqual(ProtoMessage.unzigzag32(ProtoMessage.zigzag32(-99)), -99)
        XCTAssertEqual(try ProtoMessage(ProtoMessage.float(field: 2, value: 0.5)).float(2), 0.5)
    }
}

/// ExtraMetadata field 61 from a fw 1.1.15 clip (docs/research/luna-fw-1.1.15-verification.md, Audio).
final class LunaAudioModeTests: XCTestCase {
    func testClipAudioMode() throws {
        // Observed: a clip recorded in Wind Reduction carries 61 = 20 (e8 03 14).
        XCTAssertEqual(try LunaFileMetadata(hex("e80314")).audioMode, .windReduction)
        XCTAssertEqual(try LunaFileMetadata(hex("e80315")).audioMode, .voiceEnhancement)
        XCTAssertEqual(try LunaFileMetadata(hex("e80318")).audioMode, .originalAudio)
        let other = try LunaFileMetadata(hex("e80302"))
        XCTAssertEqual(other.audioModeRaw, 2)
        XCTAssertNil(other.audioMode)
        XCTAssertNil(try LunaFileMetadata(Data()).audioModeRaw)
        XCTAssertEqual(LunaAudioMode.allCases.map(\.label), ["Wind Reduction", "Voice Enhancement", "Original Audio"])
    }
}

final class LunaClockTests: XCTestCase {
    func testSetClockMatchesOfficialConnect() throws {
        // official-fw1115/01-connect: types 12, 13, 175 and 12:1790315162 13:7200 175:'Europe/Stockholm'
        // (the official app also re-sends its cached 1, 5, 42 and 82; the camera applies only the types).
        let request = try LunaProtocol.setClockRequest(
            unixSeconds: 1_790_315_162, timeZoneSeconds: 7200, zone: "Europe/Stockholm")
        XCTAssertEqual(request.command, .setOptions)
        XCTAssertEqual(
            request.body,
            hex("0a040c0daf01 121c 609a95d8d506 68a038 fa0a10") + Data("Europe/Stockholm".utf8))
        // West of GMT is a negative int32: ten-byte two's-complement varint.
        let west = try LunaProtocol.setClockRequest(unixSeconds: 1, timeZoneSeconds: -3600, zone: "")
        XCTAssertEqual(west.body, hex("0a040c0daf01 1210 6001 68f0e3ffffffffffffff01 fa0a00"))
    }

    func testSyncTimeAccurate() throws {
        let first = try LunaProtocol.syncTimeAccurateRequest(unixMilliseconds: 1_790_758_255_639, count: 0)
        XCTAssertEqual(first.wireCode, 214)
        XCTAssertEqual(first.body, hex("0a09 08ef9af3d506 10ff04"))
        let second = try LunaProtocol.syncTimeAccurateRequest(unixMilliseconds: 1_790_758_255_639, count: 1)
        XCTAssertEqual(second.body, hex("0a09 08ef9af3d506 10ff04 1001"))
    }
}
