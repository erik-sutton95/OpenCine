// JNI exports of the Kotlin class com.opencapture.opencine.gyro.GyroNative (Android `:gyro`).
// The class name, package and member names are the native contract: change both sides in step
// and compare `llvm-nm -D` of an app's `.so` with the `external fun`s. Coarse boundary: strings,
// byte arrays and primitives only. Compiles empty on Darwin.
#if os(Android)

    import Foundation
    import OpenCineGyro
    import OpenCineJNISupport

    // MARK: - Logging and recovery

    /// `GyroNative.loggingCreate(appName): String` allocates one motion capture owner.
    @_cdecl("Java_com_opencapture_opencine_gyro_GyroNative_loggingCreate")
    public func gyroNativeLoggingCreate(
        _ env: UnsafeMutablePointer<JNIEnv?>, _: jobject?, appName: jstring?
    ) -> jstring? {
        guard let appName = swiftString(env, appName) else { return nil }
        return javaString(env, GyroLoggingWire.shared.create(appName: appName))
    }

    /// `GyroNative.loggingIngest(owner, bytes): String?` delivers one bounded sensor batch.
    @_cdecl("Java_com_opencapture_opencine_gyro_GyroNative_loggingIngest")
    public func gyroNativeLoggingIngest(
        _ env: UnsafeMutablePointer<JNIEnv?>, _: jobject?, owner: jstring?, bytes: jbyteArray?
    ) -> jstring? {
        guard let owner = swiftString(env, owner),
            let bytes = swiftBytes(env, bytes, maximumCount: 512 * 32),
            let reply = GyroLoggingWire.shared.ingest(owner: owner, bytes: bytes)
        else { return nil }
        return javaString(env, reply)
    }

    /// `GyroNative.loggingObserve(owner, recording, timestamp, dateSeconds, cameraLabel,
    /// calibrationJSON): String?` delivers a camera-authoritative record observation.
    @_cdecl("Java_com_opencapture_opencine_gyro_GyroNative_loggingObserve")
    public func gyroNativeLoggingObserve(
        _ env: UnsafeMutablePointer<JNIEnv?>, _: jobject?, owner: jstring?, recording: jboolean,
        timestamp: jdouble, dateSeconds: jdouble, cameraLabel: jstring?,
        calibrationJSON: jstring?
    ) -> jstring? {
        guard let owner = swiftString(env, owner), let label = swiftString(env, cameraLabel),
            let calibration = swiftString(env, calibrationJSON),
            let reply = GyroLoggingWire.shared.observe(
                owner: owner, recording: recording != 0, timestamp: timestamp,
                dateSeconds: dateSeconds, cameraLabel: label, calibrationJSON: calibration)
        else { return nil }
        return javaString(env, reply)
    }

    /// `GyroNative.loggingMountMoved(owner, timestamp): String?` marks a mount movement.
    @_cdecl("Java_com_opencapture_opencine_gyro_GyroNative_loggingMountMoved")
    public func gyroNativeLoggingMountMoved(
        _ env: UnsafeMutablePointer<JNIEnv?>, _: jobject?, owner: jstring?, timestamp: jdouble
    ) -> jstring? {
        guard let owner = swiftString(env, owner),
            let reply = GyroLoggingWire.shared.mountMoved(owner: owner, timestamp: timestamp)
        else { return nil }
        return javaString(env, reply)
    }

    /// `GyroNative.loggingPoll(owner, timestamp): String?` advances sample-health deadlines.
    @_cdecl("Java_com_opencapture_opencine_gyro_GyroNative_loggingPoll")
    public func gyroNativeLoggingPoll(
        _ env: UnsafeMutablePointer<JNIEnv?>, _: jobject?, owner: jstring?, timestamp: jdouble
    ) -> jstring? {
        guard let owner = swiftString(env, owner),
            let reply = GyroLoggingWire.shared.poll(owner: owner, timestamp: timestamp)
        else { return nil }
        return javaString(env, reply)
    }

    /// `GyroNative.loggingFinish(owner, reason): String?` finalizes motion files without sending
    /// camera commands.
    @_cdecl("Java_com_opencapture_opencine_gyro_GyroNative_loggingFinish")
    public func gyroNativeLoggingFinish(
        _ env: UnsafeMutablePointer<JNIEnv?>, _: jobject?, owner: jstring?, reason: jstring?
    ) -> jstring? {
        guard let owner = swiftString(env, owner), let reason = swiftString(env, reason),
            let reply = GyroLoggingWire.shared.finish(owner: owner, reason: reason)
        else { return nil }
        return javaString(env, reply)
    }

    /// `GyroNative.loggingClose(owner): Unit` releases the finished Android owner.
    @_cdecl("Java_com_opencapture_opencine_gyro_GyroNative_loggingClose")
    public func gyroNativeLoggingClose(
        _ env: UnsafeMutablePointer<JNIEnv?>, _: jobject?, owner: jstring?
    ) {
        if let owner = swiftString(env, owner) { GyroLoggingWire.shared.close(owner: owner) }
    }

    /// `GyroNative.recoveryCreate(): String` starts one streaming partial-file recovery owner.
    @_cdecl("Java_com_opencapture_opencine_gyro_GyroNative_recoveryCreate")
    public func gyroNativeRecoveryCreate(
        _ env: UnsafeMutablePointer<JNIEnv?>, _: jobject?
    ) -> jstring? {
        javaString(env, GyroLoggingWire.shared.recoveryCreate())
    }

    /// `GyroNative.recoveryAccept(owner, bytes): Long` returns the valid prefix length, or -1.
    @_cdecl("Java_com_opencapture_opencine_gyro_GyroNative_recoveryAccept")
    public func gyroNativeRecoveryAccept(
        _ env: UnsafeMutablePointer<JNIEnv?>, _: jobject?, owner: jstring?, bytes: jbyteArray?
    ) -> jlong {
        guard let owner = swiftString(env, owner),
            let bytes = swiftBytes(env, bytes, maximumCount: 65_536),
            let length = GyroLoggingWire.shared.recoveryAccept(owner: owner, bytes: bytes)
        else { return -1 }
        return length
    }

    /// `GyroNative.recoveryFinish(owner, descriptorJSON, mountMovedOffset): String?` completes
    /// recovery with the original descriptor and releases its owner.
    @_cdecl("Java_com_opencapture_opencine_gyro_GyroNative_recoveryFinish")
    public func gyroNativeRecoveryFinish(
        _ env: UnsafeMutablePointer<JNIEnv?>, _: jobject?, owner: jstring?,
        descriptorJSON: jstring?, mountMovedOffset: jdouble
    ) -> jstring? {
        guard let owner = swiftString(env, owner),
            let descriptor = swiftString(env, descriptorJSON),
            let reply = GyroLoggingWire.shared.recoveryFinish(
                owner: owner, descriptorJSON: descriptor, mountMovedOffset: mountMovedOffset)
        else { return nil }
        return javaString(env, reply)
    }

    // MARK: - Ring calibration

    /// `GyroNative.ringCreate(): String` allocates one calibration screen owner.
    @_cdecl("Java_com_opencapture_opencine_gyro_GyroNative_ringCreate")
    public func gyroNativeRingCreate(
        _ env: UnsafeMutablePointer<JNIEnv?>, _: jobject?
    ) -> jstring? {
        javaString(env, GyroRingCalibrationWire.shared.create())
    }

    /// `GyroNative.ringStart(owner, cameraConnected, recording): String?` starts or restarts the
    /// ring; recording is -1 unknown, 0 not recording, 1 recording.
    @_cdecl("Java_com_opencapture_opencine_gyro_GyroNative_ringStart")
    public func gyroNativeRingStart(
        _ env: UnsafeMutablePointer<JNIEnv?>, _: jobject?, owner: jstring?,
        cameraConnected: jboolean, recording: jint
    ) -> jstring? {
        guard let owner = swiftString(env, owner),
            let reply = GyroRingCalibrationWire.shared.start(
                owner: owner, cameraConnected: cameraConnected != 0,
                recording: Int(recording))
        else { return nil }
        return javaString(env, reply)
    }

    /// `GyroNative.ringUpdateCamera(owner, connected, recording): String?` tracks camera state.
    @_cdecl("Java_com_opencapture_opencine_gyro_GyroNative_ringUpdateCamera")
    public func gyroNativeRingUpdateCamera(
        _ env: UnsafeMutablePointer<JNIEnv?>, _: jobject?, owner: jstring?, connected: jboolean,
        recording: jint
    ) -> jstring? {
        guard let owner = swiftString(env, owner),
            let reply = GyroRingCalibrationWire.shared.updateCamera(
                owner: owner, connected: connected != 0, recording: Int(recording))
        else { return nil }
        return javaString(env, reply)
    }

    /// `GyroNative.ringObserve(owner, phoneX, phoneY, phoneZ, phoneTimestamp, hasCameraLevel,
    /// cameraX, cameraY, cameraZ, cameraTimestamp): String?` feeds one simultaneous reading;
    /// the camera level is physical down in camera axes.
    @_cdecl("Java_com_opencapture_opencine_gyro_GyroNative_ringObserve")
    public func gyroNativeRingObserve(
        _ env: UnsafeMutablePointer<JNIEnv?>, _: jobject?, owner: jstring?, phoneX: jdouble,
        phoneY: jdouble, phoneZ: jdouble, phoneTimestamp: jdouble, hasCameraLevel: jboolean,
        cameraX: jdouble, cameraY: jdouble, cameraZ: jdouble, cameraTimestamp: jdouble
    ) -> jstring? {
        guard let owner = swiftString(env, owner),
            let reply = GyroRingCalibrationWire.shared.observe(
                owner: owner, phoneX: phoneX, phoneY: phoneY, phoneZ: phoneZ,
                phoneTimestamp: phoneTimestamp, hasCameraLevel: hasCameraLevel != 0,
                cameraX: cameraX, cameraY: cameraY, cameraZ: cameraZ,
                cameraTimestamp: cameraTimestamp)
        else { return nil }
        return javaString(env, reply)
    }

    /// `GyroNative.ringInvalidate(owner, reason): String?` discards the ring and reports why.
    @_cdecl("Java_com_opencapture_opencine_gyro_GyroNative_ringInvalidate")
    public func gyroNativeRingInvalidate(
        _ env: UnsafeMutablePointer<JNIEnv?>, _: jobject?, owner: jstring?, reason: jstring?
    ) -> jstring? {
        guard let owner = swiftString(env, owner), let reason = swiftString(env, reason),
            let reply = GyroRingCalibrationWire.shared.invalidate(owner: owner, reason: reason)
        else { return nil }
        return javaString(env, reply)
    }

    /// `GyroNative.ringCancel(owner): String?` returns the ring to its intro phase.
    @_cdecl("Java_com_opencapture_opencine_gyro_GyroNative_ringCancel")
    public func gyroNativeRingCancel(
        _ env: UnsafeMutablePointer<JNIEnv?>, _: jobject?, owner: jstring?
    ) -> jstring? {
        guard let owner = swiftString(env, owner),
            let reply = GyroRingCalibrationWire.shared.cancel(owner: owner)
        else { return nil }
        return javaString(env, reply)
    }

    /// `GyroNative.ringClose(owner): Unit` releases a calibration screen's transient samples.
    @_cdecl("Java_com_opencapture_opencine_gyro_GyroNative_ringClose")
    public func gyroNativeRingClose(
        _ env: UnsafeMutablePointer<JNIEnv?>, _: jobject?, owner: jstring?
    ) {
        if let owner = swiftString(env, owner) { GyroRingCalibrationWire.shared.close(owner: owner) }
    }

    /// `GyroNative.calibrationValidate(calibrationJSON): Boolean` checks a stored rotation.
    @_cdecl("Java_com_opencapture_opencine_gyro_GyroNative_calibrationValidate")
    public func gyroNativeCalibrationValidate(
        _ env: UnsafeMutablePointer<JNIEnv?>, _: jobject?, calibrationJSON: jstring?
    ) -> jboolean {
        guard let json = swiftString(env, calibrationJSON) else { return 0 }
        return jboolean(GyroRingCalibrationWire.shared.validate(calibrationJSON: json) ? 1 : 0)
    }

    // MARK: - Drift

    /// `GyroNative.driftCreate(calibrationJSON): String?` starts a detector for one calibration.
    @_cdecl("Java_com_opencapture_opencine_gyro_GyroNative_driftCreate")
    public func gyroNativeDriftCreate(
        _ env: UnsafeMutablePointer<JNIEnv?>, _: jobject?, calibrationJSON: jstring?
    ) -> jstring? {
        guard let json = swiftString(env, calibrationJSON),
            let owner = GyroDriftWire.shared.create(calibrationJSON: json)
        else { return nil }
        return javaString(env, owner)
    }

    /// `GyroNative.driftObserveCamera(owner, hasLevel, x, y, z, timestamp)` records the newest
    /// camera down reading in camera axes.
    @_cdecl("Java_com_opencapture_opencine_gyro_GyroNative_driftObserveCamera")
    public func gyroNativeDriftObserveCamera(
        _ env: UnsafeMutablePointer<JNIEnv?>, _: jobject?, owner: jstring?, hasLevel: jboolean,
        x: jdouble, y: jdouble, z: jdouble, timestamp: jdouble
    ) {
        guard let owner = swiftString(env, owner) else { return }
        GyroDriftWire.shared.observeCamera(
            owner: owner, hasLevel: hasLevel != 0, x: x, y: y, z: z, timestamp: timestamp)
    }

    /// `GyroNative.driftObservePhone(owner, x, y, z, timestamp, rotationRate, accelerationG):
    /// Boolean` records one phone reading and reports the confirming reading exactly once.
    @_cdecl("Java_com_opencapture_opencine_gyro_GyroNative_driftObservePhone")
    public func gyroNativeDriftObservePhone(
        _ env: UnsafeMutablePointer<JNIEnv?>, _: jobject?, owner: jstring?, x: jdouble,
        y: jdouble, z: jdouble, timestamp: jdouble, rotationRate: jdouble,
        accelerationG: jdouble
    ) -> jboolean {
        guard let owner = swiftString(env, owner) else { return 0 }
        let confirmed = GyroDriftWire.shared.observePhone(
            owner: owner, x: x, y: y, z: z, timestamp: timestamp, rotationRate: rotationRate,
            accelerationG: accelerationG)
        return jboolean(confirmed ? 1 : 0)
    }

    /// `GyroNative.driftReset(owner)` clears drift confirmation and its disagreement run.
    @_cdecl("Java_com_opencapture_opencine_gyro_GyroNative_driftReset")
    public func gyroNativeDriftReset(
        _ env: UnsafeMutablePointer<JNIEnv?>, _: jobject?, owner: jstring?
    ) {
        if let owner = swiftString(env, owner) { GyroDriftWire.shared.reset(owner: owner) }
    }

    /// `GyroNative.driftClose(owner)` releases a drift monitor session.
    @_cdecl("Java_com_opencapture_opencine_gyro_GyroNative_driftClose")
    public func gyroNativeDriftClose(
        _ env: UnsafeMutablePointer<JNIEnv?>, _: jobject?, owner: jstring?
    ) {
        if let owner = swiftString(env, owner) { GyroDriftWire.shared.close(owner: owner) }
    }

    // MARK: - Arming

    /// `GyroNative.armingCreate(pendingRestoresJSON): String` resumes with the owed restores.
    @_cdecl("Java_com_opencapture_opencine_gyro_GyroNative_armingCreate")
    public func gyroNativeArmingCreate(
        _ env: UnsafeMutablePointer<JNIEnv?>, _: jobject?, pendingRestoresJSON: jstring?
    ) -> jstring? {
        let restores = swiftString(env, pendingRestoresJSON) ?? ""
        return javaString(env, GyroArmingWire.shared.create(pendingRestoresJSON: restores))
    }

    /// `GyroNative.armingUpdate(owner, inputsJSON): String?` evaluates one observation set.
    @_cdecl("Java_com_opencapture_opencine_gyro_GyroNative_armingUpdate")
    public func gyroNativeArmingUpdate(
        _ env: UnsafeMutablePointer<JNIEnv?>, _: jobject?, owner: jstring?, inputsJSON: jstring?
    ) -> jstring? {
        guard let owner = swiftString(env, owner), let inputs = swiftString(env, inputsJSON),
            let reply = GyroArmingWire.shared.update(owner: owner, inputsJSON: inputs)
        else { return nil }
        return javaString(env, reply)
    }

    /// `GyroNative.armingChooseTurnOff(owner): String?` records the operator's turn-off choice.
    @_cdecl("Java_com_opencapture_opencine_gyro_GyroNative_armingChooseTurnOff")
    public func gyroNativeArmingChooseTurnOff(
        _ env: UnsafeMutablePointer<JNIEnv?>, _: jobject?, owner: jstring?
    ) -> jstring? {
        guard let owner = swiftString(env, owner),
            let reply = GyroArmingWire.shared.chooseTurnOff(owner: owner)
        else { return nil }
        return javaString(env, reply)
    }

    /// `GyroNative.armingChooseKeepOn(owner): String?` records the operator's keep-on choice.
    @_cdecl("Java_com_opencapture_opencine_gyro_GyroNative_armingChooseKeepOn")
    public func gyroNativeArmingChooseKeepOn(
        _ env: UnsafeMutablePointer<JNIEnv?>, _: jobject?, owner: jstring?
    ) -> jstring? {
        guard let owner = swiftString(env, owner),
            let reply = GyroArmingWire.shared.chooseKeepOn(owner: owner)
        else { return nil }
        return javaString(env, reply)
    }

    /// `GyroNative.armingWriteFinished(owner, purpose, succeeded): String?` records the outcome
    /// of the last stabilization write of the given purpose.
    @_cdecl("Java_com_opencapture_opencine_gyro_GyroNative_armingWriteFinished")
    public func gyroNativeArmingWriteFinished(
        _ env: UnsafeMutablePointer<JNIEnv?>, _: jobject?, owner: jstring?, purpose: jstring?,
        succeeded: jboolean
    ) -> jstring? {
        guard let owner = swiftString(env, owner), let purpose = swiftString(env, purpose),
            let reply = GyroArmingWire.shared.writeFinished(
                owner: owner, purpose: purpose, succeeded: succeeded != 0)
        else { return nil }
        return javaString(env, reply)
    }

    /// `GyroNative.armingClose(owner)` releases an arming monitor session.
    @_cdecl("Java_com_opencapture_opencine_gyro_GyroNative_armingClose")
    public func gyroNativeArmingClose(
        _ env: UnsafeMutablePointer<JNIEnv?>, _: jobject?, owner: jstring?
    ) {
        if let owner = swiftString(env, owner) { GyroArmingWire.shared.close(owner: owner) }
    }

    // MARK: - Camera gravity adapter

    /// `GyroNative.cameraDown(roll, pitch): String?` converts measured level angles to physical
    /// down in camera axes for Kotlin adapters, or null when the angles cannot determine down.
    @_cdecl("Java_com_opencapture_opencine_gyro_GyroNative_cameraDown")
    public func gyroNativeCameraDown(
        _ env: UnsafeMutablePointer<JNIEnv?>, _: jobject?, roll: jdouble, pitch: jdouble
    ) -> jstring? {
        guard let down = GyroCameraGravity.down(rollDegrees: roll, pitchDegrees: pitch),
            let json = GyroWireJSON.string(down)
        else { return nil }
        return javaString(env, json)
    }

#endif
