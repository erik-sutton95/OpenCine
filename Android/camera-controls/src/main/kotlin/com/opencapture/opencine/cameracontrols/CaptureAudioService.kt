package com.opencapture.opencine.cameracontrols

import com.opencapture.opencine.core.CameraSessionID
import com.opencapture.opencine.core.ControlEpoch

/** A coherent optional audio domain, outside the common capture command entry. */
enum class CaptureAudioControl { CHANNEL, WIND, DIRECTION, VOCAL }
enum class CaptureAudioChannel(val raw: Int, val label: String) { STEREO(2, "Stereo"), MONO(1, "Mono"), SPATIAL(3, "Spatial") }
enum class CaptureAudioDirection(val raw: Int, val label: String) { ALL(0, "All"), FRONT(1, "Front"), FRONT_AND_BACK(2, "Front+back") }
sealed interface CaptureAudioValue {
    val label: String
    data class Channel(val value: CaptureAudioChannel) : CaptureAudioValue { override val label get() = value.label }
    data class Wind(val enabled: Boolean) : CaptureAudioValue { override val label get() = if (enabled) "On" else "Off" }
    data class Direction(val value: CaptureAudioDirection) : CaptureAudioValue { override val label get() = value.label }
    data class Vocal(val enabled: Boolean) : CaptureAudioValue { override val label get() = if (enabled) "On" else "Off" }
}
data class CaptureAudioField(val id: CaptureAudioControl, val title: String,
    val choices: List<CaptureAudioValue>, val observed: CaptureAudioValue? = null, val isEditable: Boolean = true)
enum class CaptureAudioCommitResult { SUBMITTED, UNAVAILABLE, REFUSED }
data class CaptureAudioSourceID(val session: CameraSessionID, val epoch: ControlEpoch)
class CaptureAudioService(val sourceID: CaptureAudioSourceID, val fields: List<CaptureAudioField>,
    val commit: (CaptureAudioValue) -> CaptureAudioCommitResult, val refresh: suspend () -> Unit)
