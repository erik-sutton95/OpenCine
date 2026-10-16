package com.opencapture.opencine.dji

import com.opencapture.opencine.core.CameraRecordingFormat
import com.opencapture.opencine.core.CameraRecordingObservations
import com.opencapture.opencine.core.ObservedValue
import com.opencapture.opencine.core.ObservationOrigin
import com.opencapture.opencine.vocabulary.CameraStatus
import com.opencapture.opencine.vocabulary.CameraCommands
import com.opencapture.opencine.vocabulary.CameraLabelProfile

/** Decoded recording dimensions; a transport codec supplies no recording fact. */
internal object DjiRecordingObservations {
    fun dimensions(code: Int): CameraRecordingFormat.Dimensions? {
        val size = when (code) {
            0x0A -> 1920 to 1080
            0x0C -> 1920 to 1440
            0x10 -> 3840 to 2160
            0x2D -> 2688 to 1512
            0x42 -> 1080 to 1920
            0x43 -> 1512 to 2688
            0x5F -> 2688 to 2016
            0x67 -> 3840 to 2880
            0x69 -> 1080 to 1080
            0x6A -> 2160 to 2160
            0x6B -> 3072 to 3072
            0x6C -> 1728 to 3072
            0x7D -> 3840 to 3840
            else -> return null
        }
        return CameraRecordingFormat.Dimensions.measured(size.first, size.second)
    }
    fun exposureProgram(status: CameraStatus?): ObservedValue<com.opencapture.opencine.core.CameraExposureProgram> {
        val value = when (status?.expoMode) {
            CameraCommands.EXPO_AUTO -> com.opencapture.opencine.core.CameraExposureProgram.AUTOMATIC
            CameraCommands.EXPO_MANUAL -> com.opencapture.opencine.core.CameraExposureProgram.MANUAL
            else -> null
        }
        return value?.let { ObservedValue(it, ObservationOrigin.CAMERA_REPORTED, null) } ?: ObservedValue.unknown
    }
    /** The profile reads in the body's own colour names ([labels], from its capture profile). */
    fun recording(status: CameraStatus?, labels: CameraLabelProfile = CameraLabelProfile.standard): CameraRecordingObservations {
        if (status == null) return CameraRecordingObservations.unknown
        val dimensions = dimensions(status.resolutionCode)
        val profile = when (status.colorMode) {
            CameraCommands.COLOR_NORMAL, CameraCommands.COLOR_NORMAL10, CameraCommands.COLOR_DLOG,
            CameraCommands.COLOR_DLOG2, CameraCommands.COLOR_DLOG_M, CameraCommands.COLOR_HDR -> CameraCommands.colorLabel(status.colorMode, profile = labels)
            else -> null
        }
        return CameraRecordingObservations(
            dimensions = dimensions?.let { ObservedValue(it, ObservationOrigin.CAMERA_REPORTED, null) } ?: ObservedValue.unknown,
            profile = profile?.let { ObservedValue(it, ObservationOrigin.CAMERA_REPORTED, null) } ?: ObservedValue.unknown,
        )
    }
}
