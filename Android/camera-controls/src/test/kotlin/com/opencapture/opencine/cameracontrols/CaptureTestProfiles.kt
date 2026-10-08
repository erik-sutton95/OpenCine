package com.opencapture.opencine.cameracontrols

import com.opencapture.opencine.vocabulary.*

internal object CaptureTestProfiles {
    val base = CameraLabelProfile(colorModes = listOf(CameraCommands.COLOR_NORMAL,
        CameraCommands.COLOR_HDR, CameraCommands.COLOR_DLOG))
    val pro = base.copy(colorModes = base.colorModes!! + CameraCommands.COLOR_DLOG2)
    val lowLight = CameraLabelProfile(
        shootingModeLabels = mapOf(CameraCommands.SHOOT_SUPER_NIGHT to "Low-Light"),
        colorModes = listOf(CameraCommands.COLOR_NORMAL, CameraCommands.COLOR_HDR, CameraCommands.COLOR_DLOG_M))
    val fixed = CameraLabelProfile(colorModeLabels = mapOf(CameraCommands.COLOR_NORMAL to "Normal 8-bit",
        CameraCommands.COLOR_DLOG_M to "D-Log M 10-bit"),
        colorModes = listOf(CameraCommands.COLOR_NORMAL, CameraCommands.COLOR_NORMAL10, CameraCommands.COLOR_DLOG_M))
    val video = listOf(VideoResolution.P1080, VideoResolution.P2_7K, VideoResolution.P4K,
        VideoResolution.P1080_1X1, VideoResolution.P2160_1X1, VideoResolution.P3K_1X1)
        .flatMap { resolution -> VideoFrameRate.labeledVideo.map { VideoFormat(resolution, it) } }
    val slowMo = listOf(VideoFormat(VideoResolution.P4K, VideoFrameRate.FPS100),
        VideoFormat(VideoResolution.P4K, VideoFrameRate.FPS120),
        VideoFormat(VideoResolution.P2_7K, VideoFrameRate.FPS120),
        VideoFormat(VideoResolution.P1080, VideoFrameRate.FPS120),
        VideoFormat(VideoResolution.P1080, VideoFrameRate.FPS240))
    val night = listOf(VideoResolution.P1080, VideoResolution.P4K).flatMap { resolution ->
        listOf(VideoFrameRate.FPS24, VideoFrameRate.FPS25, VideoFrameRate.FPS30).map { VideoFormat(resolution, it) } }
    val acceptedModel = CameraModel(name = "Declared capture facts", captureProfile = CameraCaptureProfile(
        labels = lowLight, isoAutoRangeFloor = 50, videoFormatFallbacks = mapOf(
            CameraCommands.SHOOT_VIDEO to video, CameraCommands.SHOOT_SLOWMO to slowMo,
            CameraCommands.SHOOT_SUPER_NIGHT to night)))
}
