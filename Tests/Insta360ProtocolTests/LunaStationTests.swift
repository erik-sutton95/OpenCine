import Foundation
import XCTest

@testable import Insta360Protocol

private func hex(_ value: String) -> Data {
    let clean = value.filter { !$0.isWhitespace }
    return Data(
        stride(from: 0, to: clean.count, by: 2).map { offset in
            let start = clean.index(clean.startIndex, offsetBy: offset)
            return UInt8(clean[start..<clean.index(start, offsetBy: 2)], radix: 16)!
        })
}

/// Station mode (the camera joins a router or a phone hotspot). Wire shapes follow the
/// official app's encoders (`SetWifiMode(place_holder = 1, wifi_mode, country_code)`,
/// `SetWifiConnectionInfo { WifiConnectionInfo { ssid = 1, password = 3 } }`) and the plaintext
/// lengths of the 2026-10-01 router-join take on firmware 1.1.15 (147: 8 bytes, 112 and 215:
/// 29 bytes for an 11-byte name and a 12-byte password). Kotlin twin: `LunaStationWireTest`.
final class LunaStationTests: XCTestCase {
    func testWiFiModeRequestsMatchTheOfficialEncoder() throws {
        let station = try LunaProtocol.wifiModeRequest(.station, countryCode: "US")
        XCTAssertEqual(station.wireCode, 147)
        XCTAssertTrue(station.requiresEncryption)
        XCTAssertEqual(station.body, hex("08011001 1a025553"))
        XCTAssertEqual(station.body.count, 8, "the captured station switch is 8 plaintext bytes")
        // proto3 leaves the default access point mode out, as the official encoder does.
        XCTAssertEqual(try LunaProtocol.wifiModeRequest(.accessPoint, countryCode: nil).body, hex("0801"))
        XCTAssertEqual(try LunaProtocol.wifiModeRequest(.station, countryCode: nil).body, hex("08011001"))
        // Only a two-letter region code is passed on.
        XCTAssertEqual(try LunaProtocol.wifiModeRequest(.station, countryCode: "united").body, hex("08011001"))
    }

    func testStationJoinAndRememberCarryTheNetworkNameAndPassword() throws {
        let join = try LunaProtocol.stationJoinRequest(ssid: "Studio", password: "synthetic1")
        XCTAssertEqual(join.wireCode, 112)
        XCTAssertTrue(join.requiresEncryption)
        XCTAssertEqual(join.body, hex("0a14 0a06") + Data("Studio".utf8) + hex("1a0a") + Data("synthetic1".utf8))
        let remember = try LunaProtocol.stationRememberRequest(ssid: "Studio", password: "synthetic1")
        XCTAssertEqual(remember.wireCode, 215)
        XCTAssertTrue(remember.requiresEncryption)
        XCTAssertEqual(remember.body, join.body)
        let captured = try LunaProtocol.stationJoinRequest(
            ssid: String(repeating: "n", count: 11), password: String(repeating: "p", count: 12))
        XCTAssertEqual(captured.body.count, 29, "the captured join is 29 plaintext bytes")
        // An open network sends no password field.
        XCTAssertEqual(
            try LunaProtocol.stationJoinRequest(ssid: "Open", password: "").body,
            hex("0a06 0a04") + Data("Open".utf8))
    }

    func testStationJoinRejectsNetworksTheCameraCannotJoin() {
        XCTAssertThrowsError(try LunaProtocol.stationJoinRequest(ssid: "", password: "synthetic1"))
        XCTAssertThrowsError(
            try LunaProtocol.stationJoinRequest(ssid: String(repeating: "a", count: 33), password: "synthetic1"))
        XCTAssertThrowsError(try LunaProtocol.stationJoinRequest(ssid: "Studio", password: "short"))
        XCTAssertThrowsError(
            try LunaProtocol.stationJoinRequest(ssid: "Studio", password: String(repeating: "p", count: 64)))
        XCTAssertThrowsError(try LunaProtocol.stationJoinRequest(ssid: "St\u{0}udio", password: "synthetic1"))
        XCTAssertTrue(LunaProtocol.acceptsStationNetwork(ssid: "Studio", password: "synthetic1"))
        XCTAssertTrue(LunaProtocol.acceptsStationNetwork(ssid: "Open", password: ""))
        XCTAssertFalse(LunaProtocol.acceptsStationNetwork(ssid: "Studio", password: "short"))
    }

    func testPhoneInfoNamesThisPhone() throws {
        let request = try LunaProtocol.phoneInfoRequest(
            .ios, manufacturer: "Apple", model: "iPhone", osVersion: "27.0")
        XCTAssertEqual(request.wireCode, 220)
        XCTAssertTrue(request.requiresEncryption)
        XCTAssertEqual(
            request.body,
            hex("0801 1205") + Data("Apple".utf8) + hex("1a06") + Data("iPhone".utf8) + hex("2204")
                + Data("27.0".utf8))
        XCTAssertEqual(
            try LunaProtocol.phoneInfoRequest(.android, manufacturer: "", model: "", osVersion: "").body,
            hex("0802"))
    }

    /// The 8232 notification of the router-join take: result 0, then the network the camera joined
    /// (name, empty BSSID, password, result and auth fields). Values here are synthetic.
    func testJoinResultNotificationReadsSuccessAndFailureWithoutLeakingThePassword() throws {
        let info = hex("0a06") + Data("Studio".utf8) + hex("1200 1a0a") + Data("synthetic1".utf8) + hex("2800 3000")
        let joined = try LunaProtocol.stationJoinResult(hex("0800 12") + Data([UInt8(info.count)]) + info)
        XCTAssertEqual(joined.outcome, .joined)
        XCTAssertEqual(joined.ssid, "Studio")
        XCTAssertNil(joined.address)
        XCTAssertFalse(String(describing: joined).contains("synthetic1"))
        XCTAssertFalse(String(reflecting: joined).contains("synthetic1"))
        // proto3: an empty body is result 0.
        XCTAssertEqual(try LunaProtocol.stationJoinResult(Data()).outcome, .joined)
        XCTAssertEqual(try LunaProtocol.stationJoinResult(hex("0803")).outcome, .wrongPassword)
        XCTAssertEqual(try LunaProtocol.stationJoinResult(hex("0806")).outcome, .networkNotFound)
        XCTAssertEqual(try LunaProtocol.stationJoinResult(hex("0801")).outcome, .failed(1))
        let addressed = hex("0a06") + Data("Studio".utf8) + hex("2208") + Data("10.0.0.9".utf8)
        XCTAssertEqual(
            try LunaProtocol.stationJoinResult(hex("12") + Data([UInt8(addressed.count)]) + addressed).address,
            "10.0.0.9")
        XCTAssertEqual(LunaProtocol.stationJoinResultCode, 8232)
    }

    func testCountryCodeComesFromTheCredentialReadsChannelList() throws {
        func blob(_ field: Int, _ value: Data) throws -> Data { try ProtoMessage.blob(field: field, value: value) }
        let wifi = try blob(36, blob(1, Data("LUNA-TEST".utf8)) + blob(2, Data("synthetic-password".utf8)))
        let channels = try blob(37, blob(1, Data("DK".utf8)) + blob(2, hex("01060b")))
        XCTAssertEqual(try LunaProtocol.wifiCountryCode(response: hex("0a0324252b") + blob(2, wifi + channels)), "DK")
        XCTAssertNil(try LunaProtocol.wifiCountryCode(response: hex("0a0324252b") + blob(2, wifi)))
    }
}
