package com.opencapture.opencine.gyro

import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertIs
import kotlin.test.assertNull
import kotlin.test.assertTrue
import org.json.JSONArray
import org.json.JSONObject

/**
 * The Android wire against the shared Swift reply shapes (Tasks 10's GyroRingCalibrationWire,
 * GyroArmingWire and GyroLoggingWire). The JSON below is what the Swift encoders emit.
 */
class GyroWireTest {
    /** The calibration object a completed ring returns, as GyroMountCalibration encodes it. */
    private val calibrationJSON = """
        {"rotation":[{"x":1,"y":0,"z":0},{"x":0,"y":1,"z":0},{"x":0,"y":0,"z":1}],
        "validationErrorDegrees":1.5,"separationDegrees":60}
    """.trimIndent()

    @Test
    fun ringReplyDecodes() {
        val posing = decodeRingReply(
            """
            {"phase":"posing","step":1,"inZone":true,"hold":1,"block":null,
            "invalidation":null,"completedSteps":1,"event":"stepCaptured","calibration":null}
            """.trimIndent(),
        )
        assertEquals(GyroRingPhase.POSING, posing.phase)
        assertEquals(1, posing.step)
        assertEquals(true, posing.inZone)
        assertEquals(1.0, posing.hold)
        assertNull(posing.block)
        assertNull(posing.invalidation)
        assertEquals(1, posing.completedSteps)
        assertEquals(GyroRingEvent.STEP_CAPTURED, posing.event)
        assertNull(posing.calibrationJSON)

        val blocked = decodeRingReply(
            """
            {"phase":"blocked","step":0,"inZone":null,"hold":null,
            "block":"cameraDisconnected","invalidation":null,"completedSteps":0,
            "event":null,"calibration":null}
            """.trimIndent(),
        )
        assertEquals(GyroRingPhase.BLOCKED, blocked.phase)
        assertEquals(0, blocked.step)
        assertNull(blocked.inZone)
        assertNull(blocked.hold)
        assertEquals(GyroCalibrationBlock.CAMERA_DISCONNECTED, blocked.block)

        val invalidated = decodeRingReply(
            """
            {"phase":"invalidated","step":null,"inZone":null,"hold":null,"block":null,
            "invalidation":"recordingStarted","completedSteps":0,"event":null,
            "calibration":null}
            """.trimIndent(),
        )
        assertEquals(GyroRingPhase.INVALIDATED, invalidated.phase)
        assertEquals(GyroCalibrationInvalidation.RECORDING_STARTED, invalidated.invalidation)

        val complete = decodeRingReply(
            """
            {"phase":"complete","step":null,"inZone":null,"hold":null,"block":null,
            "invalidation":null,"completedSteps":3,"event":"completed",
            "calibration":$calibrationJSON}
            """.trimIndent(),
        )
        assertEquals(GyroRingPhase.COMPLETE, complete.phase)
        assertEquals(3, complete.completedSteps)
        assertEquals(GyroRingEvent.COMPLETED, complete.event)
        val calibration = JSONObject(requireNotNull(complete.calibrationJSON))
        assertEquals(60.0, calibration.getDouble("separationDegrees"))
        assertEquals(3, calibration.getJSONArray("rotation").length())
    }

    @Test
    fun armingEffectsDecodeInOrder() {
        val reply = decodeArmingReply(
            """
            {"effects":[
            {"kind":"writeStabilization","purpose":"turnOff",
             "values":{"stabilization":"off","electronicStabilization":"off"}},
            {"kind":"presentSetup","steps":[
             {"kind":"stabilization","lensHasVRSwitch":true},
             {"kind":"calibration","hasSavedCalibration":false}]},
            {"kind":"persistPendingRestores","restores":[
             {"cameraID":"cam-1","saved":{"stabilization":"on"},
              "applied":{"stabilization":"off"}}]},
            {"kind":"sessionStarted"},
            {"kind":"sessionEnded"},
            {"kind":"notice","notice":"turnOffFailed"}],
            "isArmed":true,"stabilizationWarning":false}
            """.trimIndent(),
        )
        assertEquals(6, reply.effects.size)
        assertTrue(reply.isArmed)
        assertEquals(false, reply.stabilizationWarning)

        val write = assertIs<GyroArmingEffect.WriteStabilization>(reply.effects[0])
        assertEquals(
            mapOf("stabilization" to "off", "electronicStabilization" to "off"),
            write.values,
        )
        assertEquals(GyroWritePurpose.TURN_OFF, write.purpose)

        val setup = assertIs<GyroArmingEffect.PresentSetup>(reply.effects[1])
        assertEquals(
            listOf(
                GyroArmingStep.Stabilization(lensHasVRSwitch = true),
                GyroArmingStep.Calibration(hasSavedCalibration = false),
            ),
            setup.steps,
        )

        val restore = assertIs<GyroArmingEffect.PersistPendingRestores>(reply.effects[2])
        val restores = JSONArray(restore.json)
        assertEquals(1, restores.length())
        assertEquals("cam-1", restores.getJSONObject(0).getString("cameraID"))
        assertEquals("on", restores.getJSONObject(0).getJSONObject("saved").getString("stabilization"))

        assertIs<GyroArmingEffect.SessionStarted>(reply.effects[3])
        assertIs<GyroArmingEffect.SessionEnded>(reply.effects[4])
        assertEquals(
            GyroArmingNotice.TURN_OFF_FAILED,
            assertIs<GyroArmingEffect.Notice>(reply.effects[5]).notice,
        )
    }

    @Test
    fun armingInputsEncodeTheSwiftFieldNames() {
        val inputs = GyroArmingInputs(
            toggleOn = true,
            camera = GyroCameraIdentity(id = "cam-1", name = "Camera One", automaticRestoreEligible = false),
            hostEligible = true,
            videoMode = true,
            recording = false,
            stabilization = GyroStabilizationState(
                values = mapOf("stabilization" to "on"),
                lensHasVRSwitch = true,
            ),
            settings = listOf(
                GyroStabilizationSetting(
                    key = "stabilization",
                    title = "Stabilization",
                    offValue = "off",
                ),
            ),
            providesLevel = true,
            hasSavedCalibration = false,
        )
        val json = JSONObject(encodeArmingInputs(inputs))
        val keys = mutableSetOf<String>()
        val iterator = json.keys()
        while (iterator.hasNext()) keys += iterator.next()
        assertEquals(
            setOf(
                "toggleOn", "camera", "hostEligible", "videoMode", "recording", "stabilization",
                "settings", "providesLevel", "hasSavedCalibration",
            ),
            keys,
        )
        assertEquals("cam-1", json.getJSONObject("camera").getString("id"))
        assertEquals("Camera One", json.getJSONObject("camera").getString("name"))
        assertEquals(false, json.getJSONObject("camera").getBoolean("automaticRestoreEligible"))
        assertEquals(true, json.getBoolean("videoMode"))
        assertEquals(false, json.getBoolean("recording"))
        val stabilization = json.getJSONObject("stabilization")
        assertEquals("on", stabilization.getJSONObject("values").getString("stabilization"))
        assertEquals(true, stabilization.getBoolean("lensHasVRSwitch"))
        val setting = json.getJSONArray("settings").getJSONObject(0)
        assertEquals("stabilization", setting.getString("key"))
        assertEquals("Stabilization", setting.getString("title"))
        assertEquals("off", setting.getString("offValue"))
        assertEquals(true, json.getBoolean("providesLevel"))
        assertEquals(false, json.getBoolean("hasSavedCalibration"))

        val bare = JSONObject(
            encodeArmingInputs(
                inputs.copy(
                    camera = null,
                    videoMode = null,
                    recording = null,
                    stabilization = null,
                ),
            ),
        )
        assertTrue(bare.isNull("camera"))
        assertTrue(bare.isNull("videoMode"))
        assertTrue(bare.isNull("recording"))
        assertTrue(bare.isNull("stabilization"))
        assertTrue(bare.has("camera") && bare.has("videoMode") && bare.has("recording"))
        assertEquals(JSONObject.NULL, bare.get("camera"))
    }

    @Test
    fun logReplyDecodesMountMoved() {
        val reply = decodeLogReply(
            """
            {"updates":[
            {"kind":"opened","id":"11111111-1111-1111-1111-111111111111",
             "descriptor":{"id":"11111111-1111-1111-1111-111111111111",
              "cameraLabel":"Camera"}},
            {"kind":"appended","id":"11111111-1111-1111-1111-111111111111","data":"AQID"},
            {"kind":"mountMoved","id":"11111111-1111-1111-1111-111111111111",
             "offsetSeconds":1.25},
            {"kind":"finished","id":"11111111-1111-1111-1111-111111111111",
             "summary":{"termination":"normal"}}],
            "active":true,"gapWarning":false,"finished":false,"termination":null,
            "hasSamples":true}
            """.trimIndent(),
        )
        assertTrue(reply.active)
        assertEquals(false, reply.gapWarning)
        assertEquals(false, reply.finished)
        assertNull(reply.termination)
        assertTrue(reply.hasSamples)
        assertEquals(4, reply.updates.size)

        val opened = assertIs<GyroLogUpdate.Opened>(reply.updates[0])
        assertEquals("Camera", opened.descriptor.getString("cameraLabel"))

        val appended = assertIs<GyroLogUpdate.Appended>(reply.updates[1])
        assertEquals("11111111-1111-1111-1111-111111111111", appended.id)
        assertContentEquals(byteArrayOf(1, 2, 3), appended.bytes)

        val moved = assertIs<GyroLogUpdate.MountMoved>(reply.updates[2])
        assertEquals("11111111-1111-1111-1111-111111111111", moved.id)
        assertEquals(1.25, moved.offsetSeconds)

        val finished = assertIs<GyroLogUpdate.Finished>(reply.updates[3])
        assertEquals("normal", finished.summary.getString("termination"))
    }
}
