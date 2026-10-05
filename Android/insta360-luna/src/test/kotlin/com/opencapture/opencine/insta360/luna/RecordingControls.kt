package com.opencapture.opencine.insta360.luna

import com.opencapture.opencine.insta360.shell.CameraColorProfile
import com.opencapture.opencine.insta360.shell.CameraControls
import com.opencapture.opencine.insta360.shell.CameraFocusMode
import com.opencapture.opencine.insta360.shell.CameraGimbalAngle
import com.opencapture.opencine.insta360.shell.CameraGimbalMode
import com.opencapture.opencine.insta360.shell.CameraGimbalSpeed
import com.opencapture.opencine.insta360.shell.CameraNotice
import com.opencapture.opencine.insta360.shell.CameraReadout
import com.opencapture.opencine.insta360.shell.CameraShootingMode
import com.opencapture.opencine.insta360.shell.CameraTrackFrame
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.emptyFlow

/** Live controls that record the motion, tracking and focus calls and answer [accepts]. */
internal class RecordingControls : CameraControls {
    val calls = mutableListOf<Pair<String, List<Any?>>>()
    var accepts = true
    var angle: CameraGimbalAngle? = null

    fun calls(name: String) = calls.filter { it.first == name }.map { it.second }

    private fun record(name: String, vararg args: Any?): Boolean {
        calls += name to args.toList()
        return accepts
    }

    override val zoomRange = 1.0..15.0
    override suspend fun setZoom(factor: Double) = record("setZoom", factor)
    override suspend fun gimbalStick(pan: Double, tilt: Double) = record("gimbalStick", pan, tilt)
    override suspend fun gimbalRecenter() = record("gimbalRecenter")
    override suspend fun gimbalFlip() = record("gimbalFlip")
    override suspend fun tapFocus(x: Double, y: Double) = record("tapFocus", x, y)
    override suspend fun startTracking(x: Double, y: Double, width: Double, height: Double) =
        record("startTracking", x, y, width, height)
    override suspend fun stopTracking() = record("stopTracking")
    override suspend fun gimbalAngle(): CameraGimbalAngle? {
        record("gimbalAngle")
        return angle
    }
    override suspend fun gimbalSetAngle(pitch: Double, yaw: Double) = record("gimbalSetAngle", pitch, yaw)
    override val gimbalHeadPitch: Double? = null

    override val readout = MutableStateFlow(CameraReadout())
    override suspend fun takePhoto() = error("unused")
    override suspend fun setExposureBias(thirds: Int) = error("unused")
    override suspend fun setColorProfile(profile: CameraColorProfile) = error("unused")
    override suspend fun setRecordFormat(id: Long) = error("unused")
    override suspend fun setShootingMode(mode: CameraShootingMode) = error("unused")
    override suspend fun setGimbalMode(mode: CameraGimbalMode) = error("unused")
    override suspend fun setGimbalSpeed(speed: CameraGimbalSpeed) = error("unused")
    override suspend fun setFocusMode(mode: CameraFocusMode) = error("unused")
    override suspend fun setFaceMetering(on: Boolean) = error("unused")
    override fun requestSettingsRefresh() = error("unused")
    override val trackFrames = emptyFlow<CameraTrackFrame>()
    override val notices = emptyFlow<CameraNotice>()
}
