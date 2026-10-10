package com.opencapture.opencine.vocabulary


/** Snapshot of the rec lamp when confirmation opened. Any field change dismisses it. */
data class RecordConfirmationRequest(
    val shootingMode: Int,
    val recording: Boolean,
    val locked: Boolean,
    val busy: Boolean,
    val phase: ConnectionPhase,
) {
    val canConfirm: Boolean
        get() = !locked && !busy && phase == ConnectionPhase.LIVE &&
            !CameraCommands.isPhotoMode(shootingMode)
}

/** Rec-lamp vs still, and confirmation that cannot fire a stale capture kind. */
object CaptureShutterPolicy {
    fun isStillCapture(shootingMode: Int): Boolean = CameraCommands.isPhotoMode(shootingMode)

    fun requiresRecordConfirmation(prefEnabled: Boolean, shootingMode: Int): Boolean =
        prefEnabled && !isStillCapture(shootingMode)

    fun request(
        shootingMode: Int,
        recording: Boolean,
        locked: Boolean,
        busy: Boolean,
        phase: ConnectionPhase,
    ): RecordConfirmationRequest =
        RecordConfirmationRequest(shootingMode, recording, locked, busy, phase)

    fun shouldDismiss(pending: RecordConfirmationRequest?, current: RecordConfirmationRequest): Boolean =
        pending != null && pending != current

    fun canCommit(pending: RecordConfirmationRequest?, current: RecordConfirmationRequest): Boolean =
        pending != null && pending == current && current.canConfirm

    enum class CaptureKind { PHOTO, SHUTTER_TRIGGER, VIDEO_RECORD }

    fun captureKind(shootingMode: Int, shutterTriggerModes: Set<Int> = emptySet()): CaptureKind =
        when {
            isStillCapture(shootingMode) -> CaptureKind.PHOTO
            shootingMode in shutterTriggerModes -> CaptureKind.SHUTTER_TRIGGER
            else -> CaptureKind.VIDEO_RECORD
        }

    fun portraitSetupOpensMode(shootingMode: Int): Boolean = isStillCapture(shootingMode)

    /** iOS `recSetupFormat`: the current format ("4K25p"), "REC SETUP" until one is known. Stills keep "MODE". */
    fun portraitSetupLabel(status: CameraStatus): String =
        if (portraitSetupOpensMode(status.shootingMode)) "MODE"
        else VideoFormat.parse(status.resolutionCode, status.fpsIndex)
            ?.let { "${it.resolution.tabTitle}${it.frameRate.drumLabel}" } ?: "REC SETUP"

    /** iOS `recSetupColor`: color mode hanging under the format; none for stills or before `@2` arrives. */
    fun portraitSetupCaption(
        status: CameraStatus,
        family: String,
        profile: CameraLabelProfile = CameraLabelProfile.standard,
    ): String? =
        if (portraitSetupOpensMode(status.shootingMode) || status.colorMode < 0) null
        else CameraCommands.colorLabel(status.colorMode, family, profile)

    fun showsVideoTransport(shootingMode: Int): Boolean = !isStillCapture(shootingMode)

    fun showsColorReadout(shootingMode: Int): Boolean = !isStillCapture(shootingMode)

    fun showsAudioControls(shootingMode: Int): Boolean = !isStillCapture(shootingMode)

    fun recordingCategoryTabs(shootingMode: Int): List<String> =
        if (isStillCapture(shootingMode)) listOf("Mode") else listOf("Format", "Color", "Mode")

    /** A FORMAT SET failure from a previous mode must not rewrite the new mode HUD. */
    fun canRevertFormatFailure(liveShootingMode: Int, modeAtSet: Int): Boolean =
        liveShootingMode == modeAtSet
}
