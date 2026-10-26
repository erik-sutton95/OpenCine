package com.opencapture.opencine.gyro

/**
 * A [GyroNativeApi] for JVM tests: every member fails unless the test overrides the few it
 * exercises, because the JVM has no native library behind the real facade.
 */
internal open class TestGyroNativeApi : GyroNativeApi {
    override fun loggingCreate(appName: String): String = unused("loggingCreate")

    override fun loggingIngest(owner: String, bytes: ByteArray): String? = unused("loggingIngest")

    override fun loggingObserve(
        owner: String,
        recording: Boolean,
        timestamp: Double,
        dateSeconds: Double,
        cameraLabel: String,
        calibrationJSON: String,
    ): String? = unused("loggingObserve")

    override fun loggingMountMoved(owner: String, timestamp: Double): String? =
        unused("loggingMountMoved")

    override fun loggingPoll(owner: String, timestamp: Double): String? = unused("loggingPoll")

    override fun loggingFinish(owner: String, reason: String): String? = unused("loggingFinish")

    override fun loggingClose(owner: String): Unit = unused("loggingClose")

    override fun recoveryCreate(): String = unused("recoveryCreate")

    override fun recoveryAccept(owner: String, bytes: ByteArray): Long = unused("recoveryAccept")

    override fun recoveryFinish(
        owner: String,
        descriptorJSON: String,
        mountMovedOffset: Double,
    ): String? = unused("recoveryFinish")

    override fun ringCreate(): String = unused("ringCreate")

    override fun ringStart(owner: String, cameraConnected: Boolean, recording: Int): String? =
        unused("ringStart")

    override fun ringUpdateCamera(owner: String, connected: Boolean, recording: Int): String? =
        unused("ringUpdateCamera")

    override fun ringObserve(
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
    ): String? = unused("ringObserve")

    override fun ringInvalidate(owner: String, reason: String): String? = unused("ringInvalidate")

    override fun ringCancel(owner: String): String? = unused("ringCancel")

    override fun ringClose(owner: String): Unit = unused("ringClose")

    override fun calibrationValidate(calibrationJSON: String): Boolean =
        unused("calibrationValidate")

    override fun driftCreate(calibrationJSON: String): String? = unused("driftCreate")

    override fun driftObserveCamera(
        owner: String,
        hasLevel: Boolean,
        x: Double,
        y: Double,
        z: Double,
        timestamp: Double,
    ): Unit = unused("driftObserveCamera")

    override fun driftObservePhone(
        owner: String,
        x: Double,
        y: Double,
        z: Double,
        timestamp: Double,
        rotationRate: Double,
        accelerationG: Double,
    ): Boolean = unused("driftObservePhone")

    override fun driftReset(owner: String): Unit = unused("driftReset")

    override fun driftClose(owner: String): Unit = unused("driftClose")

    override fun armingCreate(pendingRestoresJSON: String): String = unused("armingCreate")

    override fun armingUpdate(owner: String, inputsJSON: String): String? = unused("armingUpdate")

    override fun armingChooseTurnOff(owner: String): String? = unused("armingChooseTurnOff")

    override fun armingChooseKeepOn(owner: String): String? = unused("armingChooseKeepOn")

    override fun armingWriteFinished(
        owner: String,
        purpose: String,
        succeeded: Boolean,
    ): String? = unused("armingWriteFinished")

    override fun armingClose(owner: String): Unit = unused("armingClose")

    override fun cameraDown(roll: Double, pitch: Double): String? = unused("cameraDown")

    private fun unused(member: String): Nothing =
        error("$member must not be called by this JVM test.")
}
