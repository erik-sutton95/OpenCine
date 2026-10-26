import Foundation
import OpenCineGyro

/// Maps Nikon camera observations and property writes to the shared gyro adapter values.
public enum NikonGyroCamera {
    /// Key for the movie vibration reduction property.
    public static let movieVRKey = "movieVR"
    /// Key for the electronic vibration reduction property.
    public static let electronicVRKey = "electronicVR"

    /// Stabilization controls gyro capture turns off and later restores.
    public static let settings = [
        GyroStabilizationSetting(key: movieVRKey, title: "IBIS", offValue: "OFF"),
        GyroStabilizationSetting(key: electronicVRKey, title: "Electronic VR", offValue: "OFF"),
    ]

    /// Reads known stabilization values; an entirely unread snapshot remains unknown.
    public static func stabilization(
        from snapshot: PTPCameraPropertySnapshot
    ) -> GyroStabilizationState? {
        var values: [String: String] = [:]
        values[movieVRKey] = snapshot.vibrationReduction
        values[electronicVRKey] = snapshot.electronicVR
        guard !values.isEmpty else { return nil }
        return GyroStabilizationState(values: values, lensHasVRSwitch: nil)
    }

    /// Encodes known values in movie VR then electronic VR order.
    public static func writes(for values: [String: String]) -> [PTPCameraPropertyWrite] {
        var writes: [PTPCameraPropertyWrite] = []
        if let value = values[movieVRKey],
            let write = PTPCameraPropertyWrite.vibrationReduction(label: value)
        {
            writes.append(write)
        }
        if let value = values[electronicVRKey],
            let on = PTPCameraPropertyDecoders.onOffCode(for: value)
        {
            writes.append(PTPCameraPropertyWrite.electronicVR(on: on == 1))
        }
        return writes
    }

    /// Converts a measured virtual-horizon reading into physical camera down.
    public static func cameraDown(from level: PTPLevelAngles?) -> GyroVector3? {
        guard let level, level.hasPitch else { return nil }
        return GyroCameraGravity.down(
            rollDegrees: PTPLevelAngles.signedDegrees(level.roll),
            pitchDegrees: PTPLevelAngles.signedDegrees(level.pitch))
    }

    /// Reports movie mode only when the camera selector has been read.
    public static func videoMode(from snapshot: PTPCameraPropertySnapshot) -> Bool? {
        snapshot.captureSelector.map { $0 == .video }
    }

    /// Uses the body serial when available, with a model-scoped fallback.
    public static func identity(
        _ identity: NativeCameraIdentity
    ) -> GyroCameraIdentity {
        GyroCameraIdentity(
            id: identity.serialNumber.isEmpty
                ? "nikon-model-\(identity.model)" : "nikon-\(identity.serialNumber)",
            name: identity.displayName,
            automaticRestoreEligible: !identity.serialNumber.isEmpty)
    }
}
