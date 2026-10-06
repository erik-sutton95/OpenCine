package com.opencapture.opencine.dji

import com.opencapture.opencine.core.Availability
import com.opencapture.opencine.core.FocusMode
import com.opencapture.opencine.core.ObservedValue
import com.opencapture.opencine.core.ObservationOrigin
import com.opencapture.opencine.core.Rational
import com.opencapture.opencine.core.SettingAccess
import com.opencapture.opencine.core.SettingDescriptor
import com.opencapture.opencine.core.SettingDomain
import com.opencapture.opencine.core.SettingKey
import com.opencapture.opencine.core.SettingValue
import com.opencapture.opencine.core.ShutterValue
import com.opencapture.opencine.core.UnavailableReason
import com.opencapture.opencine.vocabulary.CameraCommands
import com.opencapture.opencine.vocabulary.CameraModel
import com.opencapture.opencine.vocabulary.CameraStatus
import com.opencapture.opencine.vocabulary.EvComp

/** Actual decoded camera reports, before any pending UI value is applied. */
data class DjiCaptureControlState(val reported: CameraStatus, val model: CameraModel?) {
    internal val descriptors: List<SettingDescriptor>
        get() {
            val body = model ?: return emptyList()
            val shutter = reported.availableShutterDenoms.filter { it > 0 }.map {
                SettingValue.Shutter(ShutterValue.Duration(Rational(1, it)))
            }
            return buildList {
                add(SettingDescriptor(
                    SettingKey.SHUTTER,
                    access = if (shutter.isEmpty()) SettingAccess.READ_ONLY else SettingAccess.READ_WRITE,
                    domain = SettingDomain(choices = shutter),
                    availability = if (reported.expoMode == CameraCommands.EXPO_MANUAL) Availability.Available
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
            }
        }

    internal val settings: Map<SettingKey, ObservedValue<SettingValue>>
        get() = buildMap {
            fun report(value: SettingValue) {
                put(value.key, ObservedValue(value, ObservationOrigin.CAMERA_REPORTED, null))
            }
            if (reported.shutterDenom > 0)
                report(SettingValue.Shutter(ShutterValue.Duration(Rational(1, reported.shutterDenom))))
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
        }
}
