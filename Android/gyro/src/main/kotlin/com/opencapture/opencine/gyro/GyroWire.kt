package com.opencapture.opencine.gyro

import java.util.Base64
import org.json.JSONArray
import org.json.JSONObject

/** Why the ring calibration cannot accept a reading for the current step. */
enum class GyroCalibrationBlock(private val wire: String) {
    /** No camera is connected. */
    CAMERA_DISCONNECTED("cameraDisconnected"),

    /** The camera is recording; calibration needs a resting rig. */
    RECORDING("recording"),

    /** The rig is inside the target zone but the phone is not still. */
    MOVING("moving"),

    /** The camera reports no level, or its reading is too far from the phone's clock. */
    WAITING_FOR_CAMERA("waitingForCamera");

    internal companion object {
        fun fromWire(value: String): GyroCalibrationBlock =
            entries.firstOrNull { it.wire == value }
                ?: error("Unknown gyro calibration block: $value")
    }
}

/** Why an in-progress ring calibration was discarded. */
enum class GyroCalibrationInvalidation(internal val wire: String) {
    /** The active camera body changed. */
    CAMERA_CHANGED("cameraChanged"),

    /** Recording started before the ring finished. */
    RECORDING_STARTED("recordingStarted"),

    /** The camera connection ended before the ring finished. */
    CONNECTION_ENDED("connectionEnded");

    internal companion object {
        fun fromWire(value: String): GyroCalibrationInvalidation =
            entries.firstOrNull { it.wire == value }
                ?: error("Unknown gyro calibration invalidation: $value")
    }
}

/** The phase the ring calibration screen renders. */
enum class GyroRingPhase(private val wire: String) {
    /** Not started, or cancelled. */
    INTRO("intro"),

    /** Aiming for the step; the hold fills from 0 to 1 over the hold duration. */
    POSING("posing"),

    /** A block prevents progress on the step; the step resumes when the block clears. */
    BLOCKED("blocked"),

    /** The verification pose failed; the next reading restarts at the level step. */
    RETRYING("retrying"),

    /** The in-progress calibration was discarded for the reason. */
    INVALIDATED("invalidated"),

    /** All three poses verified and the mount rotation is ready to save. */
    COMPLETE("complete");

    internal companion object {
        fun fromWire(value: String): GyroRingPhase =
            entries.firstOrNull { it.wire == value }
                ?: error("Unknown gyro ring phase: $value")
    }
}

/** One completed transition reported by the ring calibration. */
enum class GyroRingEvent(private val wire: String) {
    /** A pose was captured; `completedSteps` counts it and `step` is the next pose. */
    STEP_CAPTURED("stepCaptured"),

    /** The third pose did not verify; the ring restarted at the level step. */
    VERIFICATION_FAILED("verificationFailed"),

    /** The third pose verified and produced the mount rotation. */
    COMPLETED("completed");

    internal companion object {
        fun fromWire(value: String): GyroRingEvent =
            entries.firstOrNull { it.wire == value } ?: error("Unknown gyro ring event: $value")
    }
}

/**
 * One ring-calibration reply. [calibrationJSON] is the calibration object re-serialized to a
 * string (or null), so the platform persists exactly what the shared solver returned.
 */
data class GyroRingState(
    val phase: GyroRingPhase,
    val step: Int?,
    val inZone: Boolean?,
    val hold: Double?,
    val block: GyroCalibrationBlock?,
    val invalidation: GyroCalibrationInvalidation?,
    val completedSteps: Int,
    val event: GyroRingEvent?,
    val calibrationJSON: String?,
)

/** Decodes a `GyroRingCalibrationWire` reply. */
fun decodeRingReply(json: String): GyroRingState {
    val reply = JSONObject(json)
    return GyroRingState(
        phase = GyroRingPhase.fromWire(reply.getString("phase")),
        step = reply.nullableInt("step"),
        inZone = reply.nullableBoolean("inZone"),
        hold = reply.nullableDouble("hold"),
        block = reply.nullableString("block")?.let { GyroCalibrationBlock.fromWire(it) },
        invalidation =
            reply.nullableString("invalidation")?.let { GyroCalibrationInvalidation.fromWire(it) },
        completedSteps = reply.getInt("completedSteps"),
        event = reply.nullableString("event")?.let { GyroRingEvent.fromWire(it) },
        calibrationJSON =
            if (reply.isNull("calibration")) null else reply.getJSONObject("calibration").toString(),
    )
}

/** Why a stabilization write was sent. */
enum class GyroWritePurpose(internal val wire: String) {
    /** Turn stabilization off for the armed session. */
    TURN_OFF("turnOff"),

    /** Restore the values saved before arming. */
    RESTORE("restore");

    internal companion object {
        fun fromWire(value: String): GyroWritePurpose =
            entries.firstOrNull { it.wire == value }
                ?: error("Unknown gyro write purpose: $value")
    }
}

/** A plain notice the host shows after a failed camera write. */
enum class GyroArmingNotice(private val wire: String) {
    /** Turning stabilization off was refused. */
    TURN_OFF_FAILED("turnOffFailed"),

    /** Restoring the saved stabilization values was refused. */
    RESTORE_FAILED("restoreFailed");

    internal companion object {
        fun fromWire(value: String): GyroArmingNotice =
            entries.firstOrNull { it.wire == value }
                ?: error("Unknown gyro arming notice: $value")
    }
}

/** One step of the arming setup sheet. */
sealed interface GyroArmingStep {
    /** Offer to turn camera stabilization off; null when lens switch knowledge is unavailable. */
    data class Stabilization(val lensHasVRSwitch: Boolean?) : GyroArmingStep

    /** Offer ring calibration; a saved calibration enables the skip link. */
    data class Calibration(val hasSavedCalibration: Boolean) : GyroArmingStep
}

/** One ordered side effect a host applies after an arming call. */
sealed interface GyroArmingEffect {
    /** Write these camera stabilization values. */
    data class WriteStabilization(
        val values: Map<String, String>,
        val purpose: GyroWritePurpose,
    ) : GyroArmingEffect

    /** Present the setup sheet with these steps. */
    data class PresentSetup(val steps: List<GyroArmingStep>) : GyroArmingEffect

    /** Persist this exact `restores` array, serialized as a string. */
    data class PersistPendingRestores(val json: String) : GyroArmingEffect

    /** An armed session started. */
    data object SessionStarted : GyroArmingEffect

    /** The armed session ended. */
    data object SessionEnded : GyroArmingEffect

    /** Show this notice. */
    data class Notice(val notice: GyroArmingNotice) : GyroArmingEffect
}

/** One arming reply: effects to apply in order, plus the machine's current flags. */
data class GyroArmingReply(
    val effects: List<GyroArmingEffect>,
    val isArmed: Boolean,
    val stabilizationWarning: Boolean,
)

/** Decodes a `GyroArmingWire` reply. */
fun decodeArmingReply(json: String): GyroArmingReply {
    val reply = JSONObject(json)
    val encoded = reply.getJSONArray("effects")
    val effects =
        (0 until encoded.length()).map { index ->
            val effect = encoded.getJSONObject(index)
            when (val kind = effect.getString("kind")) {
                "writeStabilization" ->
                    GyroArmingEffect.WriteStabilization(
                        values = effect.getJSONObject("values").toStringMap(),
                        purpose = GyroWritePurpose.fromWire(effect.getString("purpose")),
                    )
                "presentSetup" ->
                    GyroArmingEffect.PresentSetup(
                        steps =
                            effect.getJSONArray("steps").mapObjects { step ->
                                when (val stepKind = step.getString("kind")) {
                                    "stabilization" ->
                                        GyroArmingStep.Stabilization(
                                            lensHasVRSwitch = step.nullableBoolean("lensHasVRSwitch"),
                                        )
                                    "calibration" ->
                                        GyroArmingStep.Calibration(
                                            hasSavedCalibration =
                                                step.getBoolean("hasSavedCalibration"),
                                        )
                                    else -> error("Unknown gyro arming step: $stepKind")
                                }
                            },
                    )
                "persistPendingRestores" ->
                    GyroArmingEffect.PersistPendingRestores(
                        effect.getJSONArray("restores").toString(),
                    )
                "sessionStarted" -> GyroArmingEffect.SessionStarted
                "sessionEnded" -> GyroArmingEffect.SessionEnded
                "notice" ->
                    GyroArmingEffect.Notice(
                        GyroArmingNotice.fromWire(effect.getString("notice")),
                    )
                else -> error("Unknown gyro arming effect: $kind")
            }
        }
    return GyroArmingReply(
        effects = effects,
        isArmed = reply.getBoolean("isArmed"),
        stabilizationWarning = reply.getBoolean("stabilizationWarning"),
    )
}

/**
 * Encodes [inputs] with the Swift `GyroArmingInputs` field names. Nullable observations stay
 * present as JSON null so the shared machine distinguishes unknown from false.
 */
fun encodeArmingInputs(inputs: GyroArmingInputs): String {
    val encoded =
        JSONObject()
            .put("toggleOn", inputs.toggleOn)
            .put(
                "camera",
                inputs.camera?.let { camera ->
                    JSONObject()
                        .put("id", camera.id)
                        .put("name", camera.name)
                        .put("automaticRestoreEligible", camera.automaticRestoreEligible)
                } ?: JSONObject.NULL,
            )
            .put("hostEligible", inputs.hostEligible)
            .put("videoMode", inputs.videoMode ?: JSONObject.NULL)
            .put("recording", inputs.recording ?: JSONObject.NULL)
            .put(
                "stabilization",
                inputs.stabilization?.let { stabilization ->
                    JSONObject()
                        .put("values", JSONObject(stabilization.values))
                        .put("lensHasVRSwitch", stabilization.lensHasVRSwitch ?: JSONObject.NULL)
                } ?: JSONObject.NULL,
            )
            .put(
                "settings",
                JSONArray(
                    inputs.settings.map { setting ->
                        JSONObject()
                            .put("key", setting.key)
                            .put("title", setting.title)
                            .put("offValue", setting.offValue)
                    },
                ),
            )
            .put("providesLevel", inputs.providesLevel)
            .put("hasSavedCalibration", inputs.hasSavedCalibration)
    return encoded.toString()
}

/** One ordered file operation the platform applies after a logging reply. */
sealed interface GyroLogUpdate {
    /** Persist the descriptor and open an app-private partial file. */
    data class Opened(val descriptor: JSONObject) : GyroLogUpdate

    /** Append bytes to the identified partial file in the order returned. */
    data class Appended(val id: String, val bytes: ByteArray) : GyroLogUpdate

    /** Record the first mount movement for the take so stores persist it immediately. */
    data class MountMoved(val id: String, val offsetSeconds: Double) : GyroLogUpdate

    /** Flush, close and retain the summary, marking interrupted logs honestly. */
    data class Finished(val summary: JSONObject) : GyroLogUpdate
}

/** One logging reply: ordered updates plus the take session's current facts. */
data class GyroLogReply(
    val updates: List<GyroLogUpdate>,
    val active: Boolean,
    val gapWarning: Boolean,
    val finished: Boolean,
    val termination: String?,
    val hasSamples: Boolean,
)

/** Decodes a `GyroLoggingWire` reply, including the `mountMoved` update. */
fun decodeLogReply(json: String): GyroLogReply {
    val reply = JSONObject(json)
    val encoded = reply.getJSONArray("updates")
    val updates =
        (0 until encoded.length()).map { index ->
            val update = encoded.getJSONObject(index)
            when (val kind = update.getString("kind")) {
                "opened" -> GyroLogUpdate.Opened(update.getJSONObject("descriptor"))
                "appended" ->
                    GyroLogUpdate.Appended(
                        id = update.getString("id"),
                        bytes = Base64.getDecoder().decode(update.getString("data")),
                    )
                "mountMoved" ->
                    GyroLogUpdate.MountMoved(
                        id = update.getString("id"),
                        offsetSeconds = update.getDouble("offsetSeconds"),
                    )
                "finished" -> GyroLogUpdate.Finished(update.getJSONObject("summary"))
                else -> error("Unknown gyro log update: $kind")
            }
        }
    return GyroLogReply(
        updates = updates,
        active = reply.getBoolean("active"),
        gapWarning = reply.getBoolean("gapWarning"),
        finished = reply.getBoolean("finished"),
        termination = reply.nullableString("termination"),
        hasSamples = reply.getBoolean("hasSamples"),
    )
}

private fun JSONObject.nullableString(name: String): String? =
    if (isNull(name)) null else getString(name)

private fun JSONObject.nullableInt(name: String): Int? =
    if (isNull(name)) null else getInt(name)

private fun JSONObject.nullableDouble(name: String): Double? =
    if (isNull(name)) null else getDouble(name)

private fun JSONObject.nullableBoolean(name: String): Boolean? =
    if (isNull(name)) null else getBoolean(name)

private fun JSONObject.toStringMap(): Map<String, String> =
    buildMap {
        val keys = keys()
        while (keys.hasNext()) {
            val key = keys.next()
            put(key, getString(key))
        }
    }

private fun <T> JSONArray.mapObjects(transform: (JSONObject) -> T): List<T> =
    (0 until length()).map { index -> transform(getJSONObject(index)) }
