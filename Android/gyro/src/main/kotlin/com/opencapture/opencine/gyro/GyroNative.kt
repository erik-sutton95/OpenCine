package com.opencapture.opencine.gyro

import android.util.Log

/**
 * JNI facade for the shared gyro wire: take segmentation, GCSV bytes, ring calibration, drift
 * detection, session arming and camera-down math. The natives are implemented in Swift by
 * OpenCine's OpenCineGyroAndroid target, which an app's Swift Android library links and exports
 * as `Java_com_opencapture_opencine_gyro_GyroNative_<name>`, so this class name, package and
 * member names are the native contract (consumer-rules.pro keeps them). Replies are JSON strings
 * whose shapes [GyroWire] decodes; a nil Swift reply arrives as null.
 *
 * Native contract:
 * - `loggingCreate(appName) -> owner`, `recoveryCreate() -> owner`, `ringCreate() -> owner` and
 *   `armingCreate(pendingRestoresJSON) -> owner` allocate isolated owners.
 * - `loggingIngest(owner, bytes)`, `loggingObserve(owner, recording, timestamp, dateSeconds,
 *   cameraLabel, calibrationJSON)`, `loggingMountMoved(owner, timestamp)`,
 *   `loggingPoll(owner, timestamp)` and `loggingFinish(owner, reason)` return log replies.
 *   `loggingClose(owner)` retires the owner.
 * - `recoveryAccept(owner, bytes) -> Long` returns the valid prefix length, or -1 on failure;
 *   `recoveryFinish(owner, descriptorJSON, mountMovedOffset) -> reply` completes it
 *   (`Double.NaN` means no mount move).
 * - `ringStart(owner, cameraConnected, recording)`, `ringUpdateCamera(owner, connected,
 *   recording)`, `ringObserve(owner, phoneX, phoneY, phoneZ, phoneTimestamp, hasCameraLevel,
 *   cameraX, cameraY, cameraZ, cameraTimestamp)`, `ringInvalidate(owner, reason)` and
 *   `ringCancel(owner)` return ring replies; `ringClose(owner)` retires the owner.
 *   `recording` is -1 unknown, 0, or 1. Camera level crosses the wire as a down vector in
 *   camera axes; a camera that reports roll and pitch converts with `cameraDown` first.
 * - `calibrationValidate(calibrationJSON) -> Boolean`, `driftCreate(calibrationJSON) -> owner`,
 *   `driftObserveCamera(owner, hasLevel, x, y, z, timestamp)`,
 *   `driftObservePhone(owner, x, y, z, timestamp, rotationRate, accelerationG) -> Boolean`,
 *   `driftReset(owner)` and `driftClose(owner)`.
 * - `armingUpdate(owner, inputsJSON)`, `armingChooseTurnOff(owner)`,
 *   `armingChooseKeepOn(owner)` and `armingWriteFinished(owner, purpose, succeeded)` return
 *   arming replies; `armingClose(owner)` retires the owner.
 * - `cameraDown(roll, pitch) -> JSON vector or null` maps a camera level reading to physical
 *   down for a Kotlin adapter.
 *
 * The app calls [load] with its library name once, before any gyro call.
 */
object GyroNative : GyroNativeApi {
    /** True once [load] has loaded the library that implements these natives. */
    @Volatile
    var isAvailable: Boolean = false
        private set

    /** Loads the app's JNI library ([library] without `lib` and `.so`); false when absent. */
    @Synchronized
    fun load(library: String): Boolean {
        if (isAvailable) return true
        isAvailable =
            try {
                System.loadLibrary(library)
                true
            } catch (e: UnsatisfiedLinkError) {
                // JVM unit tests have no `.so` to load and no `android.util.Log` to log with.
                runCatching { Log.e("GyroNative", "lib$library.so did not load", e) }
                false
            }
        return isAvailable
    }

    external override fun loggingCreate(appName: String): String

    external override fun loggingIngest(owner: String, bytes: ByteArray): String?

    external override fun loggingObserve(
        owner: String,
        recording: Boolean,
        timestamp: Double,
        dateSeconds: Double,
        cameraLabel: String,
        calibrationJSON: String,
    ): String?

    external override fun loggingMountMoved(owner: String, timestamp: Double): String?

    external override fun loggingPoll(owner: String, timestamp: Double): String?

    external override fun loggingFinish(owner: String, reason: String): String?

    external override fun loggingClose(owner: String)

    external override fun recoveryCreate(): String

    external override fun recoveryAccept(owner: String, bytes: ByteArray): Long

    external override fun recoveryFinish(
        owner: String,
        descriptorJSON: String,
        mountMovedOffset: Double,
    ): String?

    external override fun ringCreate(): String

    external override fun ringStart(
        owner: String,
        cameraConnected: Boolean,
        recording: Int,
    ): String?

    external override fun ringUpdateCamera(
        owner: String,
        connected: Boolean,
        recording: Int,
    ): String?

    external override fun ringObserve(
        owner: String,
        phoneX: Double,
        phoneY: Double,
        phoneZ: Double,
        phoneTimestamp: Double,
        hasCameraLevel: Boolean,
        cameraX: Double,
        cameraY: Double,
        cameraZ: Double,
        cameraTimestamp: Double,
    ): String?

    external override fun ringInvalidate(owner: String, reason: String): String?

    external override fun ringCancel(owner: String): String?

    external override fun ringClose(owner: String)

    external override fun calibrationValidate(calibrationJSON: String): Boolean

    external override fun driftCreate(calibrationJSON: String): String?

    external override fun driftObserveCamera(
        owner: String,
        hasLevel: Boolean,
        x: Double,
        y: Double,
        z: Double,
        timestamp: Double,
    )

    external override fun driftObservePhone(
        owner: String,
        x: Double,
        y: Double,
        z: Double,
        timestamp: Double,
        rotationRate: Double,
        accelerationG: Double,
    ): Boolean

    external override fun driftReset(owner: String)

    external override fun driftClose(owner: String)

    external override fun armingCreate(pendingRestoresJSON: String): String

    external override fun armingUpdate(owner: String, inputsJSON: String): String?

    external override fun armingChooseTurnOff(owner: String): String?

    external override fun armingChooseKeepOn(owner: String): String?

    external override fun armingWriteFinished(
        owner: String,
        purpose: String,
        succeeded: Boolean,
    ): String?

    external override fun armingClose(owner: String)

    external override fun cameraDown(roll: Double, pitch: Double): String?
}

/**
 * Every native member above, so platform coordinators take a fake in JVM tests and the real
 * [GyroNative] in an app. Signatures are the JNI contract; see [GyroNative].
 */
interface GyroNativeApi {
    fun loggingCreate(appName: String): String

    fun loggingIngest(owner: String, bytes: ByteArray): String?

    fun loggingObserve(
        owner: String,
        recording: Boolean,
        timestamp: Double,
        dateSeconds: Double,
        cameraLabel: String,
        calibrationJSON: String,
    ): String?

    fun loggingMountMoved(owner: String, timestamp: Double): String?

    fun loggingPoll(owner: String, timestamp: Double): String?

    fun loggingFinish(owner: String, reason: String): String?

    fun loggingClose(owner: String)

    fun recoveryCreate(): String

    fun recoveryAccept(owner: String, bytes: ByteArray): Long

    fun recoveryFinish(
        owner: String,
        descriptorJSON: String,
        mountMovedOffset: Double,
    ): String?

    fun ringCreate(): String

    fun ringStart(owner: String, cameraConnected: Boolean, recording: Int): String?

    fun ringUpdateCamera(owner: String, connected: Boolean, recording: Int): String?

    fun ringObserve(
        owner: String,
        phoneX: Double,
        phoneY: Double,
        phoneZ: Double,
        phoneTimestamp: Double,
        hasCameraLevel: Boolean,
        cameraX: Double,
        cameraY: Double,
        cameraZ: Double,
        cameraTimestamp: Double,
    ): String?

    fun ringInvalidate(owner: String, reason: String): String?

    fun ringCancel(owner: String): String?

    fun ringClose(owner: String)

    fun calibrationValidate(calibrationJSON: String): Boolean

    fun driftCreate(calibrationJSON: String): String?

    fun driftObserveCamera(
        owner: String,
        hasLevel: Boolean,
        x: Double,
        y: Double,
        z: Double,
        timestamp: Double,
    )

    fun driftObservePhone(
        owner: String,
        x: Double,
        y: Double,
        z: Double,
        timestamp: Double,
        rotationRate: Double,
        accelerationG: Double,
    ): Boolean

    fun driftReset(owner: String)

    fun driftClose(owner: String)

    fun armingCreate(pendingRestoresJSON: String): String

    fun armingUpdate(owner: String, inputsJSON: String): String?

    fun armingChooseTurnOff(owner: String): String?

    fun armingChooseKeepOn(owner: String): String?

    fun armingWriteFinished(owner: String, purpose: String, succeeded: Boolean): String?

    fun armingClose(owner: String)

    fun cameraDown(roll: Double, pitch: Double): String?
}
