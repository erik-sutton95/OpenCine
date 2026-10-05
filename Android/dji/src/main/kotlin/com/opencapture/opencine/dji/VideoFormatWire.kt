package com.opencapture.opencine.dji

import com.opencapture.opencine.vocabulary.CameraCommands
import com.opencapture.opencine.vocabulary.GimbalStickMapping
import com.opencapture.opencine.vocabulary.VideoFormat

val VideoFormat.setPayload: ByteArray
    get() = payload(CameraCommands.SHOOT_VIDEO)

fun VideoFormat.payload(shootingMode: Int): ByteArray =
    CameraCommands.resolutionFps(resolution.rawValue, frameRate.rawValue, shootingMode)

fun VideoFormat.commandExtra(shootingMode: Int, cameraName: String? = null): String =
    CameraCommands.formatCommandExtra(
        resolution.rawValue, frameRate.rawValue, shootingMode, cameraName,
    )

fun VideoFormat.Companion.parseVideoParamV2(value: ByteArray): VideoFormat? {
    if (value.size < 2) return null
    return parse(value[0].toInt() and 0xFF, value[1].toInt() and 0xFF)
}

fun GimbalStickMapping.applyAttitude(payload: ByteArray): GimbalStickMapping {
    val yaw = CameraCommands.yawTenthDeg(payload) ?: return this
    val rotated = kotlin.math.abs(yaw) > CameraCommands.ROTATED_180_TENTH_DEG
    var next =
        copy(
            rotated180 = rotated,
            yawTenthDeg = yaw,
            pitchTenthDeg = CameraCommands.pitchTenthDeg(payload) ?: pitchTenthDeg,
        )
    val want180 = next.pendingWant180.firstOrNull()
    if (want180 != null) {
        if (CameraCommands.rotationSettled(yaw, want180)) {
            next = next.copy(
                commanded180 = want180,
                pendingWant180 = next.pendingWant180.drop(1),
                poseSeeded = true,
                poseSeedFrontCount = 0,
            )
        }
    } else if (!next.poseSeeded) {
        if (rotated) {
            next = next.copy(commanded180 = true, poseSeeded = true, poseSeedFrontCount = 0)
        } else if (CameraCommands.rotationSettled(yaw, false)) {
            val votes = next.poseSeedFrontCount + 1
            next = if (votes >= CameraCommands.POSE_SEED_FRONT_VOTES) {
                next.copy(commanded180 = false, poseSeeded = true, poseSeedFrontCount = votes)
            } else {
                next.copy(poseSeedFrontCount = votes)
            }
        } else {
            next = next.copy(poseSeedFrontCount = 0)
        }
    }
    return next
}
