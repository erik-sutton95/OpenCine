package com.opencapture.opencine.nikon

import com.opencapture.opencine.core.Availability
import com.opencapture.opencine.core.Rational
import com.opencapture.opencine.core.SettingDescriptor
import com.opencapture.opencine.core.SettingDomain
import com.opencapture.opencine.core.SettingKey
import com.opencapture.opencine.core.SettingValue
import com.opencapture.opencine.core.ShutterValue
import com.opencapture.opencine.core.UnavailableReason

/** Movie exposure values; a common edit never changes shutter convention or a stills property. */
public object NikonExposureSettings {
    /** Open-shutter sentinels remain integration-owned. Invalid and unknown labels stay null. */
    public fun shutter(label: String): SettingValue? {
        val text = label.trim()
        if (text.endsWith("°")) {
            val angle = text.dropLast(1).toDoubleOrNull() ?: return null
            return angle.takeIf { it.isFinite() && it > 0 && it <= 360 }
                ?.let { SettingValue.Shutter(ShutterValue.Angle(it)) }
        }
        if (text.endsWith("s")) {
            val seconds = text.dropLast(1).toIntOrNull() ?: return null
            return seconds.takeIf { it in 1..65535 }
                ?.let { SettingValue.Shutter(ShutterValue.Duration(Rational(it))) }
        }
        val parts = text.split("/")
        if (parts.size != 2) return null
        val numerator = parts[0].toIntOrNull() ?: return null
        val denominator = parts[1].toIntOrNull() ?: return null
        if (numerator !in 1..65535 || denominator !in 1..65535) return null
        return SettingValue.Shutter(ShutterValue.Duration(Rational(numerator, denominator)))
    }

    /** The body's positive f-number, without a fabricated value for an unknown lens. */
    public fun aperture(label: String): SettingValue? {
        val text = label.trim()
        if (!text.startsWith("f/")) return null
        val value = text.drop(2).toDoubleOrNull() ?: return null
        return value.takeIf { it.isFinite() && it > 0 && it * 100 <= 65534 }
            ?.let(SettingValue::Aperture)
    }

    /**
     * Camera reports follow only the active movie circuit. A body that never reports
     * `MovieShutterMode` (only the ZR does) shows the circuit it reports, angle first.
     */
    public fun reported(properties: CameraPropertySnapshot): Map<SettingKey, SettingValue?> {
        if (!properties.captureSelector.equals("video", ignoreCase = true)) {
            return mapOf(SettingKey.SHUTTER to null, SettingKey.APERTURE to null)
        }
        val shutter = when (properties.shutterMode) {
            CameraShutterMode.ANGLE -> properties.shutterAngle?.let(::shutter)
            CameraShutterMode.SPEED -> properties.shutterSpeed?.let(::shutter)
            null -> (properties.shutterAngle ?: properties.shutterSpeed)?.let(::shutter)
        }
        return mapOf(SettingKey.SHUTTER to shutter, SettingKey.APERTURE to properties.iris?.let(::aperture))
    }

    /**
     * Active write domains; a reported value does not imply permission to write it. While the
     * shutter mode is unknown the encoder writes by label shape, so each circuit the body reports
     * a value for is the domain: the advertised labels, else the picker ladders. A body that
     * reports no shutter value publishes no shutter descriptor.
     */
    public fun descriptors(properties: CameraPropertySnapshot): List<SettingDescriptor> {
        if (!properties.captureSelector.equals("video", ignoreCase = true)) return emptyList()
        val reported = reported(properties)
        val labels = properties.controlCapabilities.shutterValues.ifEmpty {
            if (properties.shutterMode == null) {
                ShutterPickerPolicy.angleOptions + ShutterPickerPolicy.speedOptions
            } else {
                emptyList()
            }
        }
        val shutters = (labels.mapNotNull(::shutter).filter {
            when (properties.shutterMode) {
                CameraShutterMode.ANGLE -> it is SettingValue.Shutter && it.value is ShutterValue.Angle
                CameraShutterMode.SPEED -> it is SettingValue.Shutter && it.value is ShutterValue.Duration
                // Unknown mode: only a circuit the body reports a value for is writable.
                null -> it is SettingValue.Shutter &&
                    ((it.value is ShutterValue.Angle && properties.shutterAngle != null) ||
                        (it.value is ShutterValue.Duration && properties.shutterSpeed != null))
            }
        }).distinct()
        val apertures = properties.controlCapabilities.advertisedIrisValues.mapNotNull(::aperture).distinct()
        return buildList {
            if (shutters.isNotEmpty() || reported[SettingKey.SHUTTER] != null) add(SettingDescriptor(SettingKey.SHUTTER,
                domain = SettingDomain(shutters),
                availability = when {
                    shutters.isEmpty() -> Availability.Unavailable(UnavailableReason.NotReady)
                    properties.shutterLocked == true -> Availability.Unavailable(UnavailableReason.Busy)
                    else -> Availability.Available
                }))
            if (apertures.isNotEmpty() || reported[SettingKey.APERTURE] != null) add(SettingDescriptor(SettingKey.APERTURE, domain = SettingDomain(apertures),
                availability = if (apertures.isEmpty()) Availability.Unavailable(UnavailableReason.NotReady) else Availability.Available))
        }
    }

    /** Keep an equivalent camera-advertised label intact for the native raw-domain validator. */
    public fun label(value: SettingValue, advertised: List<String> = emptyList()): String? {
        when (value) {
            is SettingValue.Shutter -> {
                advertised.firstOrNull { shutter(it) == value }?.let { return it }
                return when (val shutter = value.value) {
                    is ShutterValue.Angle -> shutter.degrees.takeIf { it.isFinite() && it > 0 && it <= 360 }?.let { "${it}°" }
                    is ShutterValue.Duration -> shutter.seconds.takeIf {
                        it.numerator in 1..65535 && it.denominator in 1..65535
                    }?.toString()
                    ShutterValue.Auto -> null
                }
            }
            is SettingValue.Aperture -> {
                advertised.firstOrNull { aperture(it) == value }?.let { return it }
                return value.fNumber.takeIf { it.isFinite() && it > 0 && it * 100 <= 65534 }?.let { "f/$it" }
            }
            else -> return null
        }
    }
}
