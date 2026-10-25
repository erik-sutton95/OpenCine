import Foundation
import OpenCineGyro

/// The JSON boundary shared by every Android gyro wire.
///
/// Each reply is one compact JSON object whose keys are sorted, so the Kotlin shell cannot depend
/// on dictionary order and tests can compare exact strings. Values the shared native contract
/// marks as nullable are emitted as explicit JSON null, never omitted.
enum GyroWireJSON {
    /// Largest accepted calibration payload, in UTF-8 bytes.
    static let maximumCalibrationBytes = 4_096
    /// Largest accepted descriptor, restore list or inputs payload, in UTF-8 bytes.
    static let maximumPayloadBytes = 65_536

    /// Encodes a reply object with sorted keys; nil when the object is not valid JSON.
    static func string(_ object: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(object),
            let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Encodes a Codable value as compact JSON text with sorted keys.
    static func string<Value: Encodable>(_ value: Value) -> String? {
        guard let data = try? encoder().encode(value) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Encodes a Codable value as JSON objects and arrays for embedding in a reply.
    static func object<Value: Encodable>(_ value: Value) -> Any? {
        guard let data = try? encoder().encode(value) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    /// Encodes a gyro log descriptor or summary with the millisecond date wire format.
    static func loggingObject<Value: Encodable>(_ value: Value) -> Any? {
        guard let data = try? loggingEncoder().encode(value) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    /// Encodes a gyro log descriptor or summary as compact JSON text with sorted keys.
    static func loggingString<Value: Encodable>(_ value: Value) -> String? {
        guard let data = try? loggingEncoder().encode(value) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Decodes the original descriptor a recovery owner reports, or nil when malformed.
    static func decodeDescriptor(_ json: String) -> GyroLogDescriptor? {
        guard let data = data(json, maximum: maximumPayloadBytes) else { return nil }
        return try? loggingDecoder().decode(GyroLogDescriptor.self, from: data)
    }

    /// Decodes one bounded mount calibration; nil for malformed or oversized JSON.
    static func decodeCalibration(_ json: String) -> GyroMountCalibration? {
        guard let data = data(json, maximum: maximumCalibrationBytes) else { return nil }
        return try? JSONDecoder().decode(GyroMountCalibration.self, from: data)
    }

    /// Decodes the owed restores a host persisted before the app process ended.
    static func decodePendingRestores(_ json: String) -> [GyroPendingRestore]? {
        guard let data = data(json, maximum: maximumPayloadBytes) else { return nil }
        return try? JSONDecoder().decode([GyroPendingRestore].self, from: data)
    }

    /// Decodes the host observations the arming machine evaluates.
    static func decodeArmingInputs(_ json: String) -> GyroArmingInputs? {
        guard let data = data(json, maximum: maximumPayloadBytes) else { return nil }
        return (try? JSONDecoder().decode(ArmingInputsJSON.self, from: data))?.inputs
    }

    /// Wraps a nullable value for a reply shape that requires the key as JSON null.
    static func optional(_ value: Any?) -> Any { value ?? NSNull() }

    private static func data(_ json: String, maximum: Int) -> Data? {
        guard json.utf8.count <= maximum else { return nil }
        return json.data(using: .utf8)
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static func loggingEncoder() -> JSONEncoder {
        let encoder = encoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }

    private static func loggingDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }
}

/// One arming observation set; the field names are the Kotlin shell's JSON contract.
private struct ArmingInputsJSON: Decodable {
    let toggleOn: Bool
    let camera: GyroCameraIdentity?
    let hostEligible: Bool
    let videoMode: Bool?
    let recording: Bool?
    let stabilization: GyroStabilizationState?
    let settings: [GyroStabilizationSetting]
    let providesLevel: Bool
    let hasSavedCalibration: Bool

    var inputs: GyroArmingInputs {
        GyroArmingInputs(
            toggleOn: toggleOn, camera: camera, hostEligible: hostEligible,
            videoMode: videoMode, recording: recording, stabilization: stabilization,
            settings: settings, providesLevel: providesLevel,
            hasSavedCalibration: hasSavedCalibration)
    }
}
