import Foundation
import OpenCineGyro
import Testing

@testable import OpenCineGyroAndroid

/// Reference poses for the wire tests, independent of the solver's basis construction.
private enum DriftWireRig {
    static let cameraDown = GyroVector3(x: -1, y: 0, z: 0)
    static let leftAxis = GyroVector3(x: 0, y: 1, z: 0)
    static let mountAxis = GyroVector3(x: 0.3, y: -0.5, z: 0.8)
    static let mountDegrees = 37.0

    static func rotate(_ vector: GyroVector3, axis: GyroVector3, degrees: Double) -> GyroVector3 {
        let length = (axis.x * axis.x + axis.y * axis.y + axis.z * axis.z).squareRoot()
        let unit = GyroVector3(x: axis.x / length, y: axis.y / length, z: axis.z / length)
        let angle = degrees * .pi / 180
        let cross = GyroVector3(
            x: unit.y * vector.z - unit.z * vector.y,
            y: unit.z * vector.x - unit.x * vector.z,
            z: unit.x * vector.y - unit.y * vector.x)
        let dot = unit.x * vector.x + unit.y * vector.y + unit.z * vector.z
        let cosine = cos(angle)
        let sine = sin(angle)
        return GyroVector3(
            x: vector.x * cosine + cross.x * sine + unit.x * dot * (1 - cosine),
            y: vector.y * cosine + cross.y * sine + unit.y * dot * (1 - cosine),
            z: vector.z * cosine + cross.z * sine + unit.z * dot * (1 - cosine))
    }

    static func phoneDown(tiltDegrees: Double) -> GyroVector3 {
        let tilted = rotate(cameraDown, axis: leftAxis, degrees: tiltDegrees)
        return rotate(tilted, axis: mountAxis, degrees: mountDegrees)
    }

    static func calibration() throws -> GyroMountCalibration {
        let tiltUp = rotate(cameraDown, axis: leftAxis, degrees: 35)
        let mixed = rotate(
            rotate(cameraDown, axis: leftAxis, degrees: 30),
            axis: GyroVector3(x: 0, y: 0, z: 1), degrees: 25)
        func pose(_ camera: GyroVector3) -> GyroCalibrationPose {
            GyroCalibrationPose(
                phoneDown: rotate(camera, axis: mountAxis, degrees: mountDegrees),
                cameraDown: camera)
        }
        return try GyroMountCalibration.solve(
            first: pose(cameraDown), second: pose(tiltUp), validation: pose(mixed))
    }

    static func calibrationJSON() throws -> String {
        String(decoding: try JSONEncoder().encode(try calibration()), as: UTF8.self)
    }
}

@Suite("Android gyro drift wire")
struct GyroDriftWireTests {
    @Test func invalidCalibrationJSONReturnsNil() {
        let wire = GyroDriftWire()
        #expect(wire.create(calibrationJSON: "") == nil)
        #expect(wire.create(calibrationJSON: "{}") == nil)
        #expect(wire.create(calibrationJSON: "not json") == nil)
        #expect(
            wire.create(calibrationJSON: String(repeating: "0", count: 5_000)) == nil)
    }

    @Test func driftConfirmsThroughTheWire() throws {
        let wire = GyroDriftWire()
        let owner = try #require(
            wire.create(calibrationJSON: try DriftWireRig.calibrationJSON()))
        defer { wire.close(owner: owner) }
        let tilted = DriftWireRig.phoneDown(tiltDegrees: 3)
        var confirmations = 0
        for step in 0...100 {
            let timestamp = Double(step) * 0.02
            wire.observeCamera(
                owner: owner, hasLevel: true, x: DriftWireRig.cameraDown.x,
                y: DriftWireRig.cameraDown.y, z: DriftWireRig.cameraDown.z,
                timestamp: timestamp)
            let confirmed = wire.observePhone(
                owner: owner, x: tilted.x, y: tilted.y, z: tilted.z, timestamp: timestamp,
                rotationRate: 0, accelerationG: 1)
            if step == 50 {
                #expect(confirmed)
                confirmations += 1
            } else {
                #expect(!confirmed)
            }
        }
        #expect(confirmations == 1)

        wire.reset(owner: owner)
        #expect(
            !wire.observePhone(
                owner: owner, x: tilted.x, y: tilted.y, z: tilted.z,
                timestamp: 2.02, rotationRate: 0, accelerationG: 1))
    }

    @Test func missingCameraLevelNeverPresentsDown() throws {
        let wire = GyroDriftWire()
        let owner = try #require(
            wire.create(calibrationJSON: try DriftWireRig.calibrationJSON()))
        defer { wire.close(owner: owner) }
        let tilted = DriftWireRig.phoneDown(tiltDegrees: 3)
        for step in 0...100 {
            let timestamp = Double(step) * 0.02
            wire.observeCamera(
                owner: owner, hasLevel: false, x: 0, y: 0, z: 0, timestamp: timestamp)
            #expect(
                !wire.observePhone(
                    owner: owner, x: tilted.x, y: tilted.y, z: tilted.z, timestamp: timestamp,
                    rotationRate: 0, accelerationG: 1))
        }
        for step in 101...200 {
            let timestamp = Double(step) * 0.02
            wire.observeCamera(
                owner: owner, hasLevel: true, x: 0, y: 0, z: 0, timestamp: timestamp)
            #expect(
                !wire.observePhone(
                    owner: owner, x: tilted.x, y: tilted.y, z: tilted.z, timestamp: timestamp,
                    rotationRate: 0, accelerationG: 1))
        }
    }

    @Test func retiredOwnerIsQuiet() throws {
        let wire = GyroDriftWire()
        let owner = try #require(
            wire.create(calibrationJSON: try DriftWireRig.calibrationJSON()))
        wire.close(owner: owner)
        wire.observeCamera(owner: owner, hasLevel: true, x: -1, y: 0, z: 0, timestamp: 0)
        wire.reset(owner: owner)
        #expect(
            !wire.observePhone(
                owner: owner, x: -1, y: 0, z: 0, timestamp: 0, rotationRate: 0,
                accelerationG: 1))
    }
}
