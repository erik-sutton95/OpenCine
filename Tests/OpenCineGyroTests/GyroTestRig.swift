import Foundation

@testable import OpenCineGyro

/// Reference poses and rotations for the gyro calibration tests, independent of the solver.
enum GyroTestRig {
    /// Rotates a vector about an axis with Rodrigues' formula, rather than the solver's basis
    /// construction, so the tests carry their own reference.
    static func rotate(_ vector: GyroVector3, axis: GyroVector3, degrees: Double) -> GyroVector3 {
        let axis = axis * (1 / axis.length)
        let angle = degrees * .pi / 180
        return vector * cos(angle) + axis.cross(vector) * sin(angle)
            + axis * (axis.dot(vector) * (1 - cos(angle)))
    }

    /// One still pose: the phone reads the camera's gravity direction rotated by the mount.
    static func pose(camera: GyroVector3, axis: GyroVector3, degrees: Double)
        -> GyroCalibrationPose
    {
        GyroCalibrationPose(
            phoneDown: rotate(camera, axis: axis, degrees: degrees), cameraDown: camera)
    }

    /// Solves the default mount from level, 35 degree tilt-up and 30 degree tilt plus 25 degree
    /// lean poses, all seen through one arbitrary phone-to-camera rotation.
    static func solvedCalibration(
        axis: GyroVector3 = GyroVector3(x: 0.3, y: -0.5, z: 0.8), degrees: Double = 37
    ) throws -> GyroMountCalibration {
        let level = GyroVector3(x: -1, y: 0, z: 0)
        let left = GyroVector3(x: 0, y: 1, z: 0)
        let tiltUp = rotate(level, axis: left, degrees: 35)
        let mixed = rotate(rotate(level, axis: left, degrees: 30), axis: GyroVector3(x: 0, y: 0, z: 1),
            degrees: 25)
        return try GyroMountCalibration.solve(
            first: pose(camera: level, axis: axis, degrees: degrees),
            second: pose(camera: tiltUp, axis: axis, degrees: degrees),
            validation: pose(camera: mixed, axis: axis, degrees: degrees))
    }
}
