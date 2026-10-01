import Foundation
import XCTest
@testable import Insta360Protocol

private func hex(_ value: String) -> Data {
    let clean = value.filter { !$0.isWhitespace }
    return Data(stride(from: 0, to: clean.count, by: 2).map { offset in
        let start = clean.index(clean.startIndex, offsetBy: offset)
        return UInt8(clean[start..<clean.index(start, offsetBy: 2)], radix: 16)!
    })
}

// Sanitized captured fixtures, shared with tools/test_ucd2.py. No camera/client
// identifiers, passwords or private key material occur anywhere in these tests.
private let getOptions = hex("55434432010c04100f0000000800020100008000000830080f080b7c008e7c")
private let greeting = hex("55434432010c050100000000112834b2")
private let liveStart = hex("55434432010c0452150000000100024d000080000010012080f702382b500e6001e497c1ce")

/// Independent original bit-round implementation, used only to make malformed
/// synthetic wire inputs without depending on the production packet builder.
private func referenceChecksum(_ data: Data) -> UInt32 {
    var value: UInt32 = 0xFFFF_FFFF
    for byte in data {
        value ^= UInt32(byte)
        for _ in 0..<32 {
            value = (value << 1) ^ (value & 0x8000_0000 == 0 ? 0 : 0x04C1_1DB7)
        }
    }
    return value
}

private func checked(_ data: Data) -> Data {
    var result = data
    let checksum = referenceChecksum(data)
    for shift in stride(from: 0, to: 32, by: 8) { result.append(UInt8(truncatingIfNeeded: checksum >> shift)) }
    return result
}

private func syntheticFrame(type: UInt8 = 4, payload: Data = Data(), extension extra: Data = Data()) -> Data {
    var packet = Data([0x55, 0x43, 0x44, 0x32, 1, UInt8(12 + extra.count), type, 0])
    for shift in stride(from: 0, to: 32, by: 8) { packet.append(UInt8(truncatingIfNeeded: payload.count >> shift)) }
    return checked(packet + extra + payload)
}

private func integer(_ field: Int, _ value: UInt64) throws -> Data { try ProtoMessage.integer(field: field, value: value) }
private func blob(_ field: Int, _ value: Data) throws -> Data { try ProtoMessage.blob(field: field, value: value) }

final class UCD2Tests: XCTestCase {
    func testCapturedChecksumsAndMessages() throws {
        XCTAssertEqual(UCD2Checksum.compute(getOptions.dropLast(4)), 0x7C8E_007C)
        let frame = try UCD2Frame(validating: getOptions)
        let message = try XCTUnwrap(frame.plainMessage())
        XCTAssertEqual(message.code, 8)
        XCTAssertEqual(message.identifier, 1)
        XCTAssertEqual(message.identifierFlags, 0x8000_0000)
        XCTAssertEqual(message.contentType, 2)
        XCTAssertEqual(message.reserved, 0)
        XCTAssertEqual(message.body, hex("0830080f080b"))
        XCTAssertEqual(message.payload, frame.payload)
        XCTAssertEqual(try UCD2Frame.plain(type: 4, sequence: 0x10, payload: message.payload).raw, getOptions)
    }

    func testCapturedLiveRequestAndHeartbeatEncodeExactly() throws {
        XCTAssertEqual(try LunaProtocol.startLiveRequest.plainFrame(identifier: 77, sequence: 0x52).raw, liveStart)
        XCTAssertEqual(try LunaProtocol.heartbeat(sequence: 1).raw, greeting)
        XCTAssertEqual(LunaProtocol.tcpPreface, hex("11000000060000affaaffaaffaaffaaffa"))
    }

    func testStreamingChecksumIndependentVector() {
        let data = Data((0..<65_536).map { UInt8(truncatingIfNeeded: $0) })
        XCTAssertEqual(UCD2Checksum.compute(data), 0x582A_0F28)
        for count in [0, 1, 7, 257] {
            XCTAssertEqual(UCD2Checksum.compute(data.prefix(count)), referenceChecksum(Data(data.prefix(count))))
        }
    }

    func testAllFragmentationPointsAndCoalescedFrames() throws {
        for split in 1..<getOptions.count {
            var parser = try UCD2Reassembler()
            XCTAssertEqual(parser.feed(getOptions.prefix(split)), [])
            let frames = parser.feed(getOptions.dropFirst(split) + greeting + liveStart)
            XCTAssertEqual(frames.map(\.raw), [getOptions, greeting, liveStart])
            XCTAssertEqual(parser.pendingByteCount, 0)
            XCTAssertEqual(parser.badChecksums, 0)
        }
        var byteParser = try UCD2Reassembler()
        let frames = (getOptions + liveStart).flatMap { byteParser.feed(Data([$0])) }
        XCTAssertEqual(frames.map(\.raw), [getOptions, liveStart])
    }

    func testNonZeroBasedDataSlices() throws {
        let padded = Data([0, 0, 0]) + getOptions
        let slice = padded.dropFirst(3)
        XCTAssertEqual(try UCD2Frame(validating: slice).plainMessage()?.code, 8)
        var parser = try UCD2Reassembler()
        XCTAssertEqual(parser.feed(slice).map(\.raw), [getOptions])
        let proto = try ProtoMessage((Data([0]) + hex("0803")).dropFirst())
        XCTAssertEqual(try proto.unsigned(1), 3)
    }

    func testCorruptionAndNoiseRecoverWithExactDiagnostics() throws {
        var damaged = getOptions
        damaged[21] ^= 1
        var parser = try UCD2Reassembler()
        XCTAssertEqual(parser.feed(Data("noise".utf8) + damaged + liveStart).map(\.raw), [liveStart])
        XCTAssertEqual(parser.badChecksums, 1)
        XCTAssertEqual(parser.discardedBytes, 5 + damaged.count)
        XCTAssertEqual(parser.pendingByteCount, 0)
    }

    func testOversizedAndInvalidHeadersCannotHoldFollowingFrame() throws {
        let tooLarge = hex("55434432010c0400ffffffff")
        let badVersion = hex("55434432020c040000000000")
        let shortHeader = hex("55434432010b040000000000")
        for header in [tooLarge, badVersion, shortHeader] {
            var parser = try UCD2Reassembler(maximumFrameSize: 128)
            XCTAssertEqual(parser.feed(header + greeting).map(\.raw), [greeting])
            XCTAssertEqual(parser.rejectedHeaders, 1)
        }
    }

    func testLargeInputIsProcessedWithBoundedPendingState() throws {
        var parser = try UCD2Reassembler(maximumFrameSize: 128)
        let input = Data(repeating: 0, count: 20_000) + Data(repeating: 0x55, count: 1_000)
            + (0..<100).reduce(into: Data()) { result, _ in result.append(getOptions) }
            + liveStart.prefix(17)
        XCTAssertEqual(parser.feed(input).count, 100)
        XCTAssertEqual(parser.pendingByteCount, 17)
        XCTAssertLessThanOrEqual(parser.pendingByteCount, parser.maximumFrameSize)
        XCTAssertEqual(parser.feed(liveStart.dropFirst(17)).map(\.raw), [liveStart])
    }

    func testStrictFrameAndMessageValidation() throws {
        for raw in [Data(), getOptions.dropLast(), getOptions + greeting, checked(hex("55434432010b040000000000"))] {
            XCTAssertThrowsError(try UCD2Frame(validating: raw))
        }
        var corrupted = greeting
        corrupted[15] ^= 1
        XCTAssertThrowsError(try UCD2Frame(validating: corrupted)) { XCTAssertEqual($0 as? LunaProtocolError, .invalidChecksum) }
        XCTAssertThrowsError(try UCD2Frame.plain(type: 1, sequence: 0, payload: Data(repeating: 0, count: 17), maximumSize: 32))
        XCTAssertThrowsError(try UCD2Reassembler(maximumFrameSize: 15))
        XCTAssertThrowsError(try UCD2Frame(validating: syntheticFrame(payload: Data(repeating: 0, count: 8))).plainMessage())
        XCTAssertThrowsError(try UCD2Message(code: 8, identifier: 0x4000_0000))
        XCTAssertThrowsError(try UCD2Message(code: 8, identifier: 1, identifierFlags: 1))
        XCTAssertThrowsError(try LunaProtocol.startLiveRequest.message(identifier: 0))
    }

    func testIndependentScheme3EnvelopeFixture() throws {
        // Independent Node/WebCrypto vector from tools/test_luna_wire.py. No
        // crypto is executed here; only exact AAD/nonce/tag/ciphertext placement.
        let aad = hex("55434432012b04010d000000")
        let nonce = hex("000102030405060708090a0b")
        let tag = hex("7173624439c47060d937e9e93c8385a0")
        let ciphertext = hex("dd28d4cce260a45d70b8a9e399")
        let raw = checked(aad + hex("401d03") + nonce + tag + ciphertext)
        let frame = try UCD2Frame(validating: raw)
        XCTAssertTrue(frame.isScheme3Encrypted)
        XCTAssertThrowsError(try frame.plainMessage())
        let envelope = try frame.scheme3Envelope()
        XCTAssertEqual(envelope.associatedData, aad)
        XCTAssertEqual(envelope.nonce, nonce)
        XCTAssertEqual(envelope.tag, tag)
        XCTAssertEqual(envelope.ciphertext, ciphertext)
        XCTAssertEqual(try UCD2Frame.scheme3AssociatedData(sequence: 1, plaintextLength: 13), aad)
        XCTAssertEqual(try UCD2Frame.scheme3(sequence: 1, ciphertext: ciphertext, nonce: nonce, tag: tag).raw, raw)
        XCTAssertThrowsError(try UCD2Frame.scheme3(sequence: 1, ciphertext: ciphertext, nonce: Data(), tag: tag))
        XCTAssertThrowsError(try UCD2Frame.scheme3(sequence: 1, ciphertext: ciphertext, nonce: nonce, tag: Data()))
        let unknown = try UCD2Frame(validating: syntheticFrame(payload: ciphertext, extension: Data([0, 0, 0])))
        XCTAssertThrowsError(try unknown.plainMessage())
        XCTAssertThrowsError(try unknown.scheme3Envelope())
    }

    func testResponseMatchingEncryptionAndCameraFailure() throws {
        let response = try UCD2Message(code: 200, identifier: 2, body: hex("12020801"))
        XCTAssertEqual(try response.successfulResponseBody(for: 2, encrypted: true, requiresEncryption: true), hex("12020801"))
        XCTAssertThrowsError(try response.successfulResponseBody(for: 1, encrypted: true, requiresEncryption: true))
        XCTAssertThrowsError(try response.successfulResponseBody(for: 2, encrypted: false, requiresEncryption: true)) {
            XCTAssertEqual($0 as? LunaProtocolError, .responseEncryptionMismatch)
        }
        let error = try UCD2Message(code: 500, identifier: 2)
        XCTAssertThrowsError(try error.successfulResponseBody(for: 2, encrypted: false, requiresEncryption: false)) {
            XCTAssertEqual($0 as? LunaProtocolError, .cameraRejectedRequest)
        }
        let async = try UCD2Message(code: 8209, identifier: 2)
        XCTAssertThrowsError(try async.successfulResponseBody(for: 2, encrypted: false, requiresEncryption: false))
        XCTAssertThrowsError(try LunaProtocol.wifiCredentialsRequest.plainFrame(identifier: 1, sequence: 1))
    }

    func testUnknownMessageFlagsAndReservedBytesRoundTrip() throws {
        let message = try UCD2Message(code: 8215, identifier: 123, body: Data([8, 1]), contentType: 7,
                                      identifierFlags: 0xC000_0000, reserved: 0xABCD)
        XCTAssertEqual(try UCD2Message(payload: message.payload), message)
    }

    func testCounterWrapsSequenceAndKeepsRequestIDsIndependent() {
        var counter = LunaRequestCounter()
        XCTAssertEqual(counter.nextIdentifier(), 1)
        for expected in 1...255 { XCTAssertEqual(counter.nextSequence(), UInt8(expected)) }
        XCTAssertEqual(counter.nextSequence(), 0)
        XCTAssertEqual(counter.nextSequence(), 1)
        XCTAssertEqual(counter.nextIdentifier(), 2)
    }
}

final class ProtobufTests: XCTestCase {
    func testIntegerLimitsAndAllSupportedWireTypes() throws {
        for value: UInt64 in [0, 127, 128, 16_384, .max] {
            XCTAssertEqual(try ProtoMessage(integer(1, value)).unsigned(1), value)
        }
        let data = try integer(1, 3) + blob(2, Data([1, 2, 3])) + hex("1900010203040506072500010203")
        let fields = try ProtoMessage(data).fields
        XCTAssertEqual(fields.count, 4)
        XCTAssertEqual(fields[2].value, .fixed64(hex("0001020304050607")))
        XCTAssertEqual(fields[3].value, .fixed32(hex("00010203")))
    }

    func testMalformedVarintsLengthsTagsAndGroups() {
        let fixtures = ["0880", "120561", "00", "0b", "09616263", "08ffffffffffffffffff02",
                        "08ffffffffffffffffff81", "12ffffffffffffffffff01", "8080808010", "0e"]
        for fixture in fixtures { XCTAssertThrowsError(try ProtoMessage(hex(fixture)), fixture) }
        for number in [0, -1, 1 << 29, Int.max] {
            XCTAssertThrowsError(try ProtoMessage.integer(field: number, value: 1))
        }
        XCTAssertThrowsError(try ProtoMessage(hex("0801"), maximumBytes: 1))
        XCTAssertThrowsError(try ProtoMessage(hex("08010802"), maximumFields: 1))
    }

    func testSingularDefaultsDuplicateLastAndStrictKnownTypes() throws {
        XCTAssertEqual(try ProtoMessage(Data()).unsigned(1, default: 0), 0)
        XCTAssertEqual(try ProtoMessage(hex("08010800")).unsigned(1), 0)
        XCTAssertThrowsError(try ProtoMessage(hex("0a000800")).unsigned(1))
        XCTAssertThrowsError(try ProtoMessage(Data()).bytes(2))
        XCTAssertNil(try ProtoMessage(Data()).optionalBytes(2))
        XCTAssertThrowsError(try ProtoMessage(hex("0801")).bytes(1))
        XCTAssertThrowsError(try ProtoMessage(hex("0a01ff")).string(1))
    }

    func testPackedAndUnpackedCapabilities() throws {
        XCTAssertEqual(try LunaProtocol.encryptionSchemes(response: hex("0a03030201")), [3, 2, 1])
        XCTAssertEqual(try LunaProtocol.encryptionSchemes(response: hex("080308020801")), [3, 2, 1])
        XCTAssertEqual(try LunaProtocol.encryptionSchemes(response: hex("08030a020201")), [3, 2, 1])
        XCTAssertThrowsError(try LunaProtocol.encryptionSchemes(response: Data()))
        XCTAssertThrowsError(try LunaProtocol.encryptionSchemes(response: hex("0a0180")))
        XCTAssertThrowsError(try LunaProtocol.encryptionSchemes(response: hex("0d00000000")))
        XCTAssertThrowsError(try ProtoMessage(hex("0a03030201")).repeatedUnsigned(1, maximumValues: 2))
    }
}

final class LunaCommandTests: XCTestCase {
    // Public NIST P-256 generator; not an owner's key.
    let generator = hex("046b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c2964fe342e2fe1a7f9b8ee7eb4a7c0f9e162bce33576b315ececbb6406837bf51f5")

    func testMinimalBootstrapCommandBodiesAndEncryptionPolicy() throws {
        XCTAssertEqual(try LunaProtocol.deviceInformationRequest(includeSerial: true).body, hex("0830080f081e"))
        XCTAssertEqual(try LunaProtocol.deviceInformationRequest(encrypted: true).body, hex("0830081e"))
        XCTAssertTrue(try LunaProtocol.deviceInformationRequest(encrypted: true).requiresEncryption)
        XCTAssertEqual(LunaProtocol.wifiCredentialsRequest.body, hex("08240825082b"))
        XCTAssertTrue(LunaProtocol.wifiCredentialsRequest.requiresEncryption)
        XCTAssertEqual(LunaProtocol.encryptionCapabilitiesRequest.command, .encryptionCapabilities)
        XCTAssertEqual(LunaProtocol.requestAuthorization.body, hex("0801"))
        let exchange = try LunaProtocol.keyExchangeRequest(publicKey: generator)
        XCTAssertEqual(exchange.command, .keyExchange)
        XCTAssertEqual(exchange.body, try integer(1, 3) + blob(2, generator))
        XCTAssertFalse(exchange.requiresEncryption)
        XCTAssertThrowsError(try LunaProtocol.getOptions([]))
        XCTAssertThrowsError(try LunaProtocol.getOptions([0]))
        XCTAssertEqual(try LunaProtocol.getPhotographyOptions([73]).body, hex("08491007"))
        XCTAssertEqual(try LunaProtocol.getPhotographyOptions([73]).command, .getPhotographyOptions)
        XCTAssertEqual(
            try LunaProtocol.setPhotographyOptions(types: [73], nested: integer(73, 1)).body,
            hex("0a01491203c804011807"))
        XCTAssertEqual(
            try LunaProtocol.setPhotographyOptions(types: [73], nested: integer(73, 0)).body,
            hex("0a01491203c804001807"))
        let raw = LunaRequest(code: 9, body: hex("0a01491203c804011807"))
        XCTAssertEqual(raw.wireCode, 9)
        XCTAssertEqual(raw.command, .setPhotographyOptions)
        XCTAssertEqual(try raw.message(identifier: 1).code, 9)
    }

    func testGimbalControlMatchesOfficialAppVirtualRC() throws {
        XCTAssertEqual(ProtoMessage.zigzag32(99), 198)
        XCTAssertEqual(ProtoMessage.zigzag32(-99), 197)
        XCTAssertEqual(try LunaProtocol.gimbalMove(upDown: 0, leftRight: 99).body, hex("0801120310c6012004"))
        XCTAssertEqual(try LunaProtocol.gimbalMove(upDown: 99, leftRight: 0).body, hex("0801120308c6012004"))
        XCTAssertEqual(try LunaProtocol.gimbalMove(upDown: -99, leftRight: 0).body, hex("0801120308c5012004"))
        XCTAssertEqual(try LunaProtocol.gimbalRecenterRequest().body, hex("08021200"))
        XCTAssertEqual(try LunaProtocol.gimbalFlipRequest().body, hex("08031200"))
        XCTAssertEqual(try LunaProtocol.gimbalReleaseRequest().body, hex("080112002004"))
        XCTAssertEqual(try LunaProtocol.gimbalMove(upDown: 0, leftRight: 99).command, .gimbalControl)
        XCTAssertThrowsError(try LunaProtocol.gimbalMove(upDown: 100, leftRight: 0))
        XCTAssertThrowsError(try LunaProtocol.gimbalMove(upDown: 0, leftRight: -100))
        XCTAssertEqual(try LunaProtocol.gimbalStick(pan: 1, tilt: 0).body, hex("0801120310c6012004"))
        XCTAssertEqual(try LunaProtocol.gimbalStick(pan: 0, tilt: 1).body, hex("0801120308c6012004"))
    }

    func testCapturedControlBodies() throws {
        XCTAssertEqual(LunaProtocol.takePictureRequest.command, .takePicture)
        XCTAssertEqual(LunaProtocol.takePictureRequest.body, Data())
        XCTAssertEqual(LunaProtocol.startCaptureRequest.body, hex("0801"))
        XCTAssertEqual(LunaProtocol.stopCaptureRequest.command, .stopCapture)
        XCTAssertEqual(try LunaProtocol.setColorMode(.iLog).command, .setPhotographyOptions)
        let ev = try ProtoMessage(try LunaProtocol.setPhotographyOptions(
            types: [7], nested: integer(7, 6)).body)
        XCTAssertEqual(try ProtoMessage(ev.bytes(2)).unsigned(7), 6)
        XCTAssertEqual(try ProtoMessage.double(field: 53, value: 2.0), hex("a9030000000000000040"))
        XCTAssertEqual(try ProtoMessage(try ProtoMessage.double(field: 53, value: 6.0)).double(53), 6.0)
        XCTAssertEqual(try LunaProtocol.deleteFiles("/storage_internal/DCIM/Camera01/IMG.jpg").command, .deleteFiles)
        XCTAssertEqual(
            try LunaProtocol.fileListURIs(try blob(1, Data("/storage_internal/DCIM/Camera01/VID.mp4".utf8))),
            ["/storage_internal/DCIM/Camera01/VID.mp4"])
        XCTAssertEqual(try LunaProtocol.setVideoSubMode(.slowMotion).command, .setOptions)
    }

    func testScreenEnvelopeRoundTrip() throws {
        let fixture = hex("003412cdab11000052c963b1010b000100004030201003000000677569")
        let envelope = try ScreenWire.decodeEnvelope(fixture)
        XCTAssertEqual(envelope.kind, 0)
        XCTAssertEqual(envelope.source, 0x1234)
        XCTAssertEqual(envelope.destination, 0xABCD)
        XCTAssertEqual(try envelope.encode(), fixture)
        let hello = try ScreenWire.kind2Hello(flag: 0, transaction: 1, conversation: 2, tail: 8)
        let decoded = try ScreenWire.decodeKind2(try ScreenWire.decodeEnvelope(hello))
        XCTAssertEqual(decoded.flag, 0)
        XCTAssertEqual(decoded.transaction, 1)
        XCTAssertEqual(decoded.conversation, 2)
        XCTAssertEqual(decoded.tail, 8)
    }

    func testKeyExchangeSuccessIsOneAndEncodingMustBeUncompressed() throws {
        XCTAssertEqual(try LunaProtocol.cameraPublicKey(response: integer(1, 1) + blob(2, generator)), generator)
        for status: UInt64 in [0, 2, 3, 4, 5, 100] {
            XCTAssertThrowsError(try LunaProtocol.cameraPublicKey(response: integer(1, status) + blob(2, generator))) {
                XCTAssertEqual($0 as? LunaProtocolError, .keyExchangeRejected(status))
            }
        }
        XCTAssertThrowsError(try LunaProtocol.cameraPublicKey(response: blob(2, generator)))
        for invalid in [Data(), Data([4]) + Data(repeating: 0, count: 64), Data([2]) + Data(repeating: 1, count: 32)] {
            XCTAssertThrowsError(try LunaProtocol.keyExchangeRequest(publicKey: invalid))
            XCTAssertThrowsError(try LunaProtocol.cameraPublicKey(response: integer(1, 1) + blob(2, invalid)))
        }
    }

    func testOwnIdentityIsRepeatedAndAuthorizationZeroDefaultsToSuccess() throws {
        let identity = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
        let request = try LunaProtocol.authorizationCheck(identity: identity)
        let body = try ProtoMessage(request.body)
        XCTAssertEqual(try body.string(1), identity.uuidString)
        XCTAssertEqual(try body.string(3), identity.uuidString)
        XCTAssertEqual(try body.unsigned(2), 1)
        XCTAssertFalse(request.requiresEncryption)
        XCTAssertEqual(try LunaProtocol.authorizationStatus(response: Data()), .authorized)
        XCTAssertEqual(try LunaProtocol.authorizationStatus(response: hex("0801")), .approvalRequired)
        XCTAssertThrowsError(try LunaProtocol.authorizationStatus(response: hex("0802")))
        XCTAssertThrowsError(try LunaProtocol.authorizationStatus(response: hex("0a00")))
    }

    func testAuthorizationNotificationResultAndOperationValidation() throws {
        try LunaProtocol.validateAuthorizationNotification(UCD2Message(code: 8209, identifier: 0, body: hex("0800")))
        try LunaProtocol.validateAuthorizationNotification(UCD2Message(code: 8209, identifier: 0))
        try LunaProtocol.validateAuthorizationNotification(UCD2Message(code: 8228, identifier: 0, body: hex("1001")))
        // Empty proto3 body is a successful approval (result 0, omitted operation).
        try LunaProtocol.validateAuthorizationNotification(UCD2Message(code: 8209, identifier: 7))
        XCTAssertThrowsError(try LunaProtocol.validateAuthorizationNotification(UCD2Message(code: 8209, identifier: 0, body: hex("0801"))))
        XCTAssertThrowsError(try LunaProtocol.validateAuthorizationNotification(UCD2Message(code: 8209, identifier: 0, body: hex("1002"))))
        XCTAssertThrowsError(try LunaProtocol.validateAuthorizationNotification(UCD2Message(code: 200, identifier: 0)))
    }

    func testDeviceInformationRequiresExpectedModelAndCompleteNestedResponse() throws {
        let options = try blob(48, Data(LunaProtocol.model.utf8)) + blob(30, Data("test-only".utf8))
        let info = try LunaProtocol.deviceInformation(response: hex("0a02301e") + blob(2, options))
        XCTAssertEqual(info.model, LunaProtocol.model)
        XCTAssertEqual(info.firmware, "test-only")
        XCTAssertNil(info.serial)
        XCTAssertThrowsError(try LunaProtocol.deviceInformation(response: blob(2, blob(48, Data("other".utf8)) + blob(30, Data("test".utf8)))))
        XCTAssertEqual(try LunaProtocol.deviceInformation(response: integer(1, 48) + integer(1, 30) + blob(2, options)), info)
        XCTAssertThrowsError(try LunaProtocol.deviceInformation(response: hex("0d00000000") + blob(2, options)))
        XCTAssertThrowsError(try LunaProtocol.deviceInformation(response: blob(2, options) + Data([0x80])))
    }

    func testCredentialsNestedShapeValidationAndRedaction() throws {
        func response(ssid: Data = Data("synthetic-ssid".utf8), password: Data = Data("synthetic-password".utf8)) throws -> Data {
            try blob(2, blob(36, blob(1, ssid) + blob(2, password)))
        }
        let credentials = try LunaProtocol.wifiCredentials(response: hex("0a0324252b") + response())
        XCTAssertEqual(credentials.ssid, "synthetic-ssid")
        XCTAssertEqual(credentials.password, "synthetic-password")
        XCTAssertEqual(String(describing: credentials), "LunaWiFiCredentials(<redacted>)")
        XCTAssertFalse(String(reflecting: credentials).contains("synthetic"))
        XCTAssertThrowsError(try LunaProtocol.wifiCredentials(response: response(ssid: Data())))
        XCTAssertThrowsError(try LunaProtocol.wifiCredentials(response: response(ssid: Data(repeating: 65, count: 33))))
        XCTAssertThrowsError(try LunaProtocol.wifiCredentials(response: response(password: Data("short".utf8))))
        XCTAssertThrowsError(try LunaProtocol.wifiCredentials(response: response(password: Data(repeating: 0xFF, count: 8))))
        XCTAssertThrowsError(try LunaProtocol.wifiCredentials(response: blob(2, blob(36, blob(1, Data("ssid".utf8))))))
        XCTAssertEqual(try LunaProtocol.wifiCredentials(response: integer(1, 36) + response()), credentials)
        XCTAssertThrowsError(try LunaProtocol.wifiCredentials(response: hex("0a0180") + response()))
    }

    func testMediaHeaderTimestampAndUnknownSubstreams() throws {
        let nal = hex("00000001260100010203") // Synthetic, not a decodable picture.
        let frame = try UCD2Frame(validating: syntheticFrame(type: 1, payload: hex("200807060504030201") + nal))
        let packet = try LunaMediaPacket(frame: frame)
        XCTAssertEqual(packet.subtype, 0x20)
        XCTAssertEqual(packet.timestamp, 0x0102_0304_0506_0708)
        XCTAssertEqual(packet.hevcAnnexB, nal)
        let unknown = try LunaMediaPacket(frame: UCD2Frame(validating: syntheticFrame(type: 1, payload: hex("300000000000000000") + nal)))
        XCTAssertNil(unknown.hevcAnnexB)
        XCTAssertEqual(unknown.bytes, nal)
        XCTAssertThrowsError(try LunaMediaPacket(frame: UCD2Frame(validating: syntheticFrame(type: 1, payload: Data(repeating: 0, count: 8)))))
        XCTAssertThrowsError(try LunaMediaPacket(frame: UCD2Frame(validating: syntheticFrame(type: 1, payload: hex("200000000000000000")))))
        XCTAssertThrowsError(try LunaMediaPacket(frame: UCD2Frame(validating: greeting)))
    }
}
