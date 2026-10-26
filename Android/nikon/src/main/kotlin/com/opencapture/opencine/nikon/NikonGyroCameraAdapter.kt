package com.opencapture.opencine.nikon

import com.opencapture.opencine.gyro.GyroCameraAdapter
import com.opencapture.opencine.gyro.GyroCameraIdentity
import com.opencapture.opencine.gyro.GyroCameraLevel
import com.opencapture.opencine.gyro.GyroNativeApi
import com.opencapture.opencine.gyro.GyroStabilizationSetting
import com.opencapture.opencine.gyro.GyroStabilizationState
import com.opencapture.opencine.gyro.GyroVector3
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.emptyFlow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.flow.SharingStarted
import org.json.JSONObject

/** Feeds one Nikon session's state and live-view levels to shared gyro capture. */
class NikonGyroCameraAdapter(
    private val session: CameraSession,
    frames: SwiftCoreLiveFrameSource?,
    private val native: GyroNativeApi,
    scope: CoroutineScope,
    private val now: () -> Double,
) : GyroCameraAdapter {
    override val identity: StateFlow<GyroCameraIdentity?> =
        session.state.map { state ->
            (state as? CameraSessionState.Connected)?.identity?.let { identity ->
                GyroCameraIdentity(
                    id = if (identity.serialNumber.isEmpty()) {
                        "nikon-model-${identity.model}"
                    } else {
                        "nikon-${identity.serialNumber}"
                    },
                    name = identity.name,
                    automaticRestoreEligible = identity.serialNumber.isNotEmpty(),
                )
            }
        }.stateIn(scope, SharingStarted.Eagerly, null)

    override val recording: StateFlow<Boolean?> = session.reportedRecording

    override val videoMode: StateFlow<Boolean?> =
        session.reportedCameraProperties.map { properties ->
            properties.captureSelector?.let { it == "video" }
        }.stateIn(scope, SharingStarted.Eagerly, null)

    override val stabilization: StateFlow<GyroStabilizationState?> =
        session.reportedCameraProperties.map { properties ->
            if (properties.vibrationReduction == null && properties.electronicVr == null) {
                null
            } else {
                GyroStabilizationState(
                    values = buildMap {
                        properties.vibrationReduction?.let { put(MOVIE_VR_KEY, it) }
                        properties.electronicVr?.let { put(ELECTRONIC_VR_KEY, it) }
                    },
                    lensHasVRSwitch = null,
                )
            }
        }.stateIn(scope, SharingStarted.Eagerly, null)

    override val level: Flow<GyroCameraLevel> =
        frames?.currentStreamFrames?.metadataOnly()?.map { frame ->
            frame.level?.let { cameraLevel(it, native, now()) }
                ?: GyroCameraLevel(down = null, timestampSeconds = now())
        } ?: emptyFlow()

    override val providesLevel: Boolean = frames != null

    override val stabilizationSettings: List<GyroStabilizationSetting> =
        listOf(
            GyroStabilizationSetting(MOVIE_VR_KEY, "IBIS", "OFF"),
            GyroStabilizationSetting(ELECTRONIC_VR_KEY, "Electronic VR", "OFF"),
        )

    override suspend fun writeStabilization(values: Map<String, String>): Boolean {
        if (values.keys.any { it != MOVIE_VR_KEY && it != ELECTRONIC_VR_KEY }) return false
        values[ELECTRONIC_VR_KEY]?.let { value ->
            if (value.uppercase() != "ON" && value.uppercase() != "OFF") return false
        }
        values[MOVIE_VR_KEY]?.let { value ->
            try {
                session.applyControl(CameraControl.VIBRATION_REDUCTION, value)
            } catch (_: CameraControlException) {
                return false
            }
        }
        values[ELECTRONIC_VR_KEY]?.let { value ->
            try {
                session.applyControl(CameraControl.ELECTRONIC_VR, value.uppercase())
            } catch (_: CameraControlException) {
                return false
            }
        }
        return true
    }

    internal companion object {
        private const val MOVIE_VR_KEY = "movieVR"
        private const val ELECTRONIC_VR_KEY = "electronicVR"

        fun cameraLevel(level: LiveCameraLevel, native: GyroNativeApi, timestamp: Double): GyroCameraLevel {
            if (level.isDebugFixture || !level.hasPitch) {
                return GyroCameraLevel(down = null, timestampSeconds = timestamp)
            }
            val down = native.cameraDown(level.rollDegrees, level.pitchDegrees)?.let { json ->
                runCatching {
                    JSONObject(json).let { value ->
                        GyroVector3(value.getDouble("x"), value.getDouble("y"), value.getDouble("z"))
                    }
                }.getOrNull()
            }
            return GyroCameraLevel(down = down, timestampSeconds = timestamp)
        }
    }
}
