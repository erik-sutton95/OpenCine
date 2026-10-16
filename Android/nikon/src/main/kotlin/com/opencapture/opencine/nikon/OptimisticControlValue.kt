package com.opencapture.opencine.nikon

/**
 * Optimistic inverse of [cameraPropertyConfirmsSelection] (iOS
 * `cameraPropertySnapshot.applying(property:data:)`): returns the snapshot with the field(s) the
 * operator just picked set to [label], so the monitor tile reflects the pick immediately while the
 * authoritative write + readback confirm lands in the background. Each branch mirrors the matching
 * [cameraPropertyConfirmsSelection] branch one-for-one, so a synthesized value round-trips as
 * confirmed. Anything that can't be cleanly synthesized (an unparsable ISO, a shutter value with
 * no known display circuit) is left untouched; the confirmed refresh still reconciles it.
 */
fun CameraPropertySnapshot.withOptimisticControlValue(
    control: CameraControl,
    label: String,
): CameraPropertySnapshot =
    when (control) {
        CameraControl.ISO, CameraControl.STILL_ISO ->
            label.toLongOrNull()?.let { copy(iso = it) } ?: this
        CameraControl.ISO_AUTO ->
            copy(isoAuto = label.equals(IsoPickerPolicy.AUTO_ISO_ON_LABEL, ignoreCase = true))
        CameraControl.STILL_ISO_AUTO -> copy(isoAuto = label.equals("On", ignoreCase = true))
        CameraControl.SHUTTER ->
            when (shutterMode) {
                CameraShutterMode.ANGLE -> copy(shutterAngle = label)
                CameraShutterMode.SPEED -> copy(shutterSpeed = label)
                null -> this
            }
        CameraControl.STILL_SHUTTER -> copy(shutterSpeed = label)
        CameraControl.IRIS, CameraControl.STILL_IRIS -> copy(iris = label)
        CameraControl.WHITE_BALANCE ->
            if (label.endsWith("K")) {
                copy(
                    whiteBalanceMode = COLOR_TEMPERATURE_MODE,
                    whiteBalanceKelvin = label.dropLast(1).toIntOrNull() ?: whiteBalanceKelvin,
                )
            } else {
                copy(whiteBalanceMode = label)
            }
        CameraControl.WHITE_BALANCE_TINT -> copy(whiteBalanceTint = label)
        CameraControl.FOCUS_MODE -> copy(focusMode = label)
        CameraControl.STILL_FOCUS_MODE -> copy(stillFocusMode = label)
        CameraControl.FOCUS_AREA, CameraControl.STILL_FOCUS_AREA -> copy(focusArea = label)
        CameraControl.FOCUS_SUBJECT, CameraControl.STILL_FOCUS_SUBJECT -> copy(focusSubject = label)
        CameraControl.EXPOSURE_MODE -> copy(exposureMode = label)
        CameraControl.AUDIO_SENSITIVITY -> copy(audioSensitivity = label)
        CameraControl.AUDIO_INPUT -> copy(audioInput = label)
        CameraControl.WIND_FILTER -> copy(windFilter = label)
        CameraControl.ATTENUATOR -> copy(inputAttenuator = label)
        CameraControl.AUDIO_32_BIT_FLOAT -> copy(audio32BitFloat = label)
        CameraControl.BASE_ISO -> copy(baseIso = label)
        CameraControl.SHUTTER_MODE ->
            when (label) {
                "Angle" -> copy(shutterMode = CameraShutterMode.ANGLE)
                "Speed" -> copy(shutterMode = CameraShutterMode.SPEED)
                else -> this
            }
        CameraControl.SHUTTER_LOCK -> copy(shutterLocked = label == "Locked")
        CameraControl.RESOLUTION_FRAMERATE -> copy(resolutionFrameRate = label)
        // A bit-depth button writes a variant label ("H.265 10-bit"), which is not a drum row;
        // resolve it back through the core-supplied table so the drum keeps its row and only the
        // depth moves. Never by pulling the depth out of the label.
        CameraControl.CODEC ->
            controlCapabilities.codecBitDepths.firstOrNull { it.writeValue == label }
                ?.let { copy(codecSelection = it.codec, codecBitDepth = it.label) }
                ?: copy(codecSelection = label)
        CameraControl.VIBRATION_REDUCTION -> copy(vibrationReduction = label)
        CameraControl.ELECTRONIC_VR -> copy(electronicVr = label)
        CameraControl.STILL_DRIVE -> copy(stillCaptureMode = label)
        CameraControl.STILL_METER -> copy(meteringMode = label)
        CameraControl.STILL_IMAGE_AREA -> copy(imageArea = label)
        CameraControl.STILL_IMAGE_SIZE -> copy(imageSize = label)
        CameraControl.STILL_QUALITY -> copy(compression = label)
        CameraControl.STILL_RAW_COMPRESSION -> copy(rawCompression = label)
        CameraControl.STILL_USER_MODE_PROGRAM -> copy(userModeProgram = label)
        CameraControl.STILL_PICTURE_CONTROL -> copy(pictureControl = label)
        CameraControl.MOVIE_TONE -> copy(movieTone = label)
    }

/* Every label below is accepted by `PTPCameraPropertyWrite` in the shared Swift core. */
private const val COLOR_TEMPERATURE_MODE = "Color temp"
