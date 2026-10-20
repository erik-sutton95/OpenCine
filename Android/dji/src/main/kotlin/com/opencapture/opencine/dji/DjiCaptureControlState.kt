package com.opencapture.opencine.dji

import com.opencapture.opencine.core.Availability
import com.opencapture.opencine.core.FocusMode
import com.opencapture.opencine.core.ObservedValue
import com.opencapture.opencine.core.ObservationOrigin
import com.opencapture.opencine.core.Rational
import com.opencapture.opencine.core.SettingAccess
import com.opencapture.opencine.core.SettingDescriptor
import com.opencapture.opencine.core.SettingDomain
import com.opencapture.opencine.core.SettingSemantics
import com.opencapture.opencine.media.HostShutterAngle
import com.opencapture.opencine.media.HostShutterPresentation
import com.opencapture.opencine.core.SettingKey
import com.opencapture.opencine.core.SettingValue
import com.opencapture.opencine.core.ShutterValue
import com.opencapture.opencine.core.UnavailableReason
import com.opencapture.opencine.vocabulary.CameraCommands
import com.opencapture.opencine.vocabulary.CameraModel
import com.opencapture.opencine.vocabulary.CameraStatus
import com.opencapture.opencine.vocabulary.EvComp

/** Actual decoded camera reports, before any pending UI value is applied. */
data class DjiCaptureControlState(
    val reported: CameraStatus, val model: CameraModel?,
    val shutterPresentation: HostShutterPresentation = HostShutterPresentation.CAMERA_VALUE,
) {
    /**
     * The speeds a common 1/N edit may use: the camera's `camcap_shutter` list, or the documented
     * video ladder (plus the live 1/N) when the body publishes none (Pocket 3).
     */
    val offeredShutterDenoms: List<Int>
        get() = CameraCommands.shutterWheelDenoms(reported.availableShutterDenoms.filter { it > 0 }, reported.shutterDenom)

    /** The angle presentation is a video one; a still always speaks in 1/N. */
    internal val emulatesShutterAngle: Boolean
        get() = shutterPresentation == HostShutterPresentation.EMULATED_ANGLE &&
            !CameraCommands.isPhotoMode(reported.shootingMode)

    internal val descriptors: List<SettingDescriptor>
        get() {
            val body = model ?: return emptyList()
            val shutter = offeredShutterDenoms.map { SettingValue.Shutter(ShutterValue.Duration(Rational(1, it))) }
            val emulated = emulatesShutterAngle
            val video = reported.shootingMode in setOf(0x00, 0x01, 0x02, 0x0A, 0x28)
            val ready = reported.expoMode == CameraCommands.EXPO_MANUAL &&
                (!emulated || (video && reported.fps > 0 && reported.shutterDenom > 0))
            return buildList {
                add(SettingDescriptor(
                    SettingKey.SHUTTER,
                    access = if (shutter.isEmpty()) SettingAccess.READ_ONLY else SettingAccess.READ_WRITE,
                    domain = SettingDomain(choices = if (emulated) HostShutterAngle.choices else shutter),
                    semantics = SettingSemantics(implementation = if (emulated) SettingSemantics.Implementation.EMULATED else SettingSemantics.Implementation.NATIVE),
                    availability = if (ready) Availability.Available
                        else Availability.Unavailable(UnavailableReason.Mode),
                ))
                add(SettingDescriptor(SettingKey.EXPOSURE_COMPENSATION,
                    domain = SettingDomain(choices = EvComp.allCases.map {
                        SettingValue.ExposureCompensation(Rational(it.thirds, 3))
                    })))
                if (body.supportsFocusMode) add(SettingDescriptor(SettingKey.FOCUS_MODE,
                    domain = SettingDomain(choices = listOf(
                        SettingValue.FocusMode(FocusMode.SINGLE), SettingValue.FocusMode(FocusMode.CONTINUOUS),
                    ))))
                if (body.supportsZoom) {
                    val maximum = body.activeZoomStops(reported.resolutionCode, reported.shootingMode).lastOrNull()
                    if (maximum != null && maximum.isFinite() && maximum >= 1.0)
                        add(SettingDescriptor(SettingKey.ZOOM, domain = SettingDomain(range = 1.0..maximum)))
                }
                // Auto/Starburst strategy stays typed; measured iris is a read-only common f-number.
                if (body.supportsAperture) add(SettingDescriptor(SettingKey.APERTURE, access = SettingAccess.READ_ONLY))
                // The recording rate is a common read-only observation; the format picker stays native.
                add(SettingDescriptor(SettingKey.FRAME_RATE, access = SettingAccess.READ_ONLY))
            }
        }

    /** A common 1/N edit reaches the wire only in Manual and inside the offered speeds. */
    fun admitsShutterWrite(denominator: Int): Boolean =
        reported.expoMode == CameraCommands.EXPO_MANUAL && denominator in offeredShutterDenoms

    internal val settings: Map<SettingKey, ObservedValue<SettingValue>>
        get() = buildMap {
            fun report(value: SettingValue) {
                put(value.key, ObservedValue(value, ObservationOrigin.CAMERA_REPORTED, null))
            }
            if (emulatesShutterAngle) {
                HostShutterAngle.reported(reported.shutterDenom, reported.fps.takeIf { it > 0 }?.toDouble())?.let {
                    put(SettingKey.SHUTTER, ObservedValue(SettingValue.Shutter(ShutterValue.Angle(it)), ObservationOrigin.PROTOCOL_DERIVED, null))
                }
            } else if (reported.shutterDenom > 0) {
                report(SettingValue.Shutter(ShutterValue.Duration(Rational(1, reported.shutterDenom))))
            }
            EvComp.fromRaw(reported.evComp)?.let {
                report(SettingValue.ExposureCompensation(Rational(it.thirds, 3)))
            }
            when (reported.focusMode) {
                CameraCommands.FOCUS_SINGLE -> report(SettingValue.FocusMode(FocusMode.SINGLE))
                CameraCommands.FOCUS_CONTINUOUS -> report(SettingValue.FocusMode(FocusMode.CONTINUOUS))
            }
            reported.zoomFactor?.takeIf { it.isFinite() && it >= 1.0 }?.let {
                report(SettingValue.Zoom(it))
            }
            if (reported.irisHundredths in 100..2_200)
                report(SettingValue.Aperture(reported.irisHundredths / 100.0))
            // `cam_video_param_v2` carries an index into whole rates (`VideoFrameRate`).
            if (reported.fps > 0) report(SettingValue.FrameRate(Rational(reported.fps)))
        }
}
