package com.opencapture.opencine.appkit

import com.opencapture.opencine.core.Availability
import com.opencapture.opencine.core.ConnectionState
import com.opencapture.opencine.core.ControlAuthority
import com.opencapture.opencine.core.ISOValue
import com.opencapture.opencine.core.Rational
import com.opencapture.opencine.core.SettingAccess
import com.opencapture.opencine.core.SettingDomain
import com.opencapture.opencine.core.SettingKey
import com.opencapture.opencine.core.SettingValue
import com.opencapture.opencine.core.ShutterValue
import com.opencapture.opencine.core.WhiteBalanceValue
import com.opencapture.opencine.media.ExposureCompensation
import java.math.BigDecimal
import java.math.MathContext
import java.math.RoundingMode
import kotlin.math.abs
import kotlin.math.floor
import kotlin.math.round

/** A drum detent keeps its typed command value. Display copy never becomes a wire mapping. */
public data class MonitorCaptureChoice(public val value: SettingValue, public val label: String)

/** Which observation a readout presents; pending commands never become camera reports. */
public enum class MonitorCaptureSelection { REPORTED, PENDING }

/** One common readout and the immutable editor its gestures opened against. */
public data class MonitorCaptureField(
    public val key: SettingKey,
    public val title: String,
    /** An absent report stays absent, including when there is a visual drum fallback. */
    public val selection: SettingValue?,
    public val choices: List<MonitorCaptureChoice>,
    public val editor: MonitorControlModel.Editor?,
) {
    public val label: String? get() = selection?.let(MonitorCapturePresentation::label)
    public val isEditable: Boolean get() = editor != null && choices.isNotEmpty()
}

/**
 * The Custom white balance hold drum: Kelvin detents only (Swift `MonitorCaptureField.kelvinScrub`).
 * Leaving Custom for Auto or a preset takes the panel, so a quick drag never flips the mode.
 */
public val MonitorCaptureField.kelvinScrub: MonitorCaptureField
    get() = copy(choices = choices.filter {
        (it.value as? SettingValue.WhiteBalance)?.value is com.opencapture.opencine.core.WhiteBalanceValue.Kelvin
    })

/** Common setting copy and bounded drum sampling. Integrations own the accepted domain. */
public object MonitorCapturePresentation {
    /** The dashes a readout draws for a value the camera has not reported. */
    public val unreportedMarks: Set<String> = setOf("", "--", "\u2014")

    /** Whether a readout's value stands for a value the camera has not reported. */
    public fun isUnreported(drawn: String?): Boolean = drawn == null || drawn in unreportedMarks || drawn == "Not set"

    /**
     * An unreported readout whose owner offers nothing to edit is inert: it is disabled and opens
     * no panel. [editable] is null when the readout declares no field or native owner; such a
     * readout keeps the host's panel unless it disabled its quick control. A host action or a
     * reported value always keeps the readout live.
     */
    public fun readoutIsInert(reported: Boolean, editable: Boolean?, quickEnabled: Boolean, hasAction: Boolean): Boolean {
        if (hasAction || reported) return false
        if (editable == null) return !quickEnabled
        return !(quickEnabled && editable)
    }

    /** The same rule for a readout drawn from a common field or a native quick control. */
    public fun readoutIsInert(value: String?, field: MonitorCaptureField?, nativeEnabled: Boolean?,
        quickEnabled: Boolean, hasAction: Boolean): Boolean = if (field != null) {
        readoutIsInert(field.selection != null, field.isEditable, quickEnabled, hasAction)
    } else readoutIsInert(!isUnreported(value), nativeEnabled, quickEnabled, hasAction)

    public fun title(key: SettingKey): String? = when (key) {
        SettingKey.ISO -> "ISO"
        SettingKey.SHUTTER -> "SHUTTER"
        SettingKey.APERTURE -> "IRIS"
        SettingKey.WHITE_BALANCE -> "WB"
        SettingKey.EXPOSURE_COMPENSATION -> "EV"
        SettingKey.FOCUS_MODE -> "FOCUS"
        SettingKey.FRAME_RATE -> "FPS"
        else -> null
    }

    public fun label(value: SettingValue): String = when (value) {
        is SettingValue.Iso -> when (val iso = value.value) {
            ISOValue.Auto -> "Auto"
            is ISOValue.AutoLimited -> "Auto ${iso.maximum}"
            is ISOValue.Manual -> iso.iso.toString()
        }
        is SettingValue.Shutter -> when (val shutter = value.value) {
            ShutterValue.Auto -> "Auto"
            is ShutterValue.Duration -> if (shutter.seconds.numerator == 1) "1/${shutter.seconds.denominator}"
                else "${number(shutter.seconds.doubleValue)}s"
            is ShutterValue.Angle -> "${number(shutter.degrees)}°"
        }
        // One decimal, as every body and its menus spell it ("f/4.0").
        is SettingValue.Aperture -> "f/%.1f".format(java.util.Locale.ROOT, value.fNumber)
        is SettingValue.WhiteBalance -> when (val wb = value.value) {
            WhiteBalanceValue.Auto -> "Auto"
            is WhiteBalanceValue.Preset -> wb.id
            is WhiteBalanceValue.Kelvin -> "${wb.kelvin}K"
        }
        is SettingValue.ExposureCompensation -> ExposureCompensation.label(value.stops.doubleValue)
        is SettingValue.FocusMode -> when (value.mode) {
            com.opencapture.opencine.core.FocusMode.MANUAL -> "MF"
            com.opencapture.opencine.core.FocusMode.SINGLE -> "AF-S"
            com.opencapture.opencine.core.FocusMode.CONTINUOUS -> "AF-C"
        }
        is SettingValue.FrameRate -> frameRate(value.fps)
        else -> ""
    }

    /** Bounded typed detents from the reported domain; this projection grants no command authority. */
    public fun choices(key: SettingKey, domain: SettingDomain?): List<MonitorCaptureChoice> {
        if (domain == null) return emptyList()
        val values = domain.choices.filter { it.key == key }.toMutableList()
        val range = domain.range
        if (key == SettingKey.WHITE_BALANCE && range != null) {
            // Kelvin has integer units. A continuous domain uses 100 K detents; an explicit
            // camera step is honored. Bound allocation even for an erroneous remote domain.
            val step = domain.step ?: 100.0
            if (range.start.isFinite() && range.endInclusive.isFinite() && step.isFinite() && step > 0 &&
                range.start >= 0 && range.endInclusive <= Int.MAX_VALUE.toDouble() &&
                (range.endInclusive - range.start) / step <= 1_000) {
                val count = floor((range.endInclusive - range.start) / step).toInt()
                // Every detent lies on the domain's own grid; a set keeps the merge linear (R-03).
                val listed = values.toHashSet()
                for (index in 0..count) {
                    val kelvin = range.start + index * step
                    if (round(kelvin) == kelvin) {
                        val value = SettingValue.WhiteBalance(WhiteBalanceValue.Kelvin(kelvin.toInt()))
                        if (listed.add(value)) values += value
                    }
                }
            }
        }
        return values.map { MonitorCaptureChoice(it, label(it)) }
    }

    /** Whole rates print whole (24); the rest print two decimals (24000/1001 shows 23.98). Swift twin. */
    public fun frameRate(rate: Rational): String =
        if (rate.denominator == 1) rate.numerator.toString()
        else String.format(java.util.Locale.ROOT, "%.2f", rate.doubleValue)

    public fun exposureProgram(value: com.opencapture.opencine.core.CameraExposureProgram): String = when (value) {
        com.opencapture.opencine.core.CameraExposureProgram.AUTOMATIC, com.opencapture.opencine.core.CameraExposureProgram.APERTURE_PRIORITY -> "A"
        com.opencapture.opencine.core.CameraExposureProgram.MANUAL -> "M"
        com.opencapture.opencine.core.CameraExposureProgram.ISO_PRIORITY -> "I"
        com.opencapture.opencine.core.CameraExposureProgram.SHUTTER_PRIORITY -> "S"
        com.opencapture.opencine.core.CameraExposureProgram.PROGRAM -> "P"
    }

    public fun recordingFormat(snapshot: com.opencapture.opencine.core.CameraSnapshot): com.opencapture.opencine.core.CameraRecordingFormat =
        com.opencapture.opencine.core.CameraRecordingFormat.measured(snapshot.recordingFormat.dimensions.value,
            (snapshot.value(SettingKey.FRAME_RATE).value as? SettingValue.FrameRate)?.fps,
            snapshot.recordingFormat.profile.value, snapshot.recordingFormat.codec.value)

    public fun recordingLabel(format: com.opencapture.opencine.core.CameraRecordingFormat): String? {
        val parts = listOfNotNull(format.dimensions?.let(::resolutionLabel), format.frameRate?.let { frameRate(it) + "p" })
        return parts.takeIf { it.isNotEmpty() }?.joinToString(" · ")
    }

    /** Compact captions use measured geometry; uncommon dimensions retain exact values. */
    public fun resolutionLabel(size: com.opencapture.opencine.core.CameraRecordingFormat.Dimensions): String {
        val label = when (val width = maxOf(size.width, size.height)) {
            in 7680..Int.MAX_VALUE -> "8K"
            in 5000..7679 -> "6K"
            in 3500..4999 -> "4K"
            in 2880..3499 -> "3K"
            in 2500..2879 -> "2.7K"
            2160 -> if (size.width == size.height) "2160p" else return "${size.width}×${size.height}"
            1080 -> if (size.width == size.height) "1080p" else return "${size.width}×${size.height}"
            1920 -> "1080p"
            else -> return "${size.width}×${size.height}"
        }
        val ratio = size.width.toDouble() / size.height
        val aspect = when {
            kotlin.math.abs(ratio - 16.0 / 9.0) < 0.015 -> ""
            kotlin.math.abs(ratio - 4.0 / 3.0) < 0.015 -> " 4:3"
            kotlin.math.abs(ratio - 9.0 / 16.0) < 0.015 -> " 9:16"
            kotlin.math.abs(ratio - 1.0) < 0.015 -> " 1:1"
            kotlin.math.abs(ratio - 2.35) < 0.03 -> " 2.35:1"
            else -> ""
        }
        return label + aspect
    }

    /**
     * C `%g`, what Swift `String(format: "%g")` prints: six significant digits from the exact binary
     * value (ties to even), trailing zeros and a bare point dropped, `1.5e-05` below 1e-4 and from
     * 1e6 up. Java's own `%g` keeps the zeros and rounds the shortest decimal half up.
     */
    private fun number(value: Double): String {
        if (!value.isFinite()) return if (value.isNaN()) "nan" else if (value > 0) "inf" else "-inf"
        if (value == 0.0) return if (1.0 / value < 0) "-0" else "0"
        val rounded = BigDecimal(value).round(MathContext(6, RoundingMode.HALF_EVEN))
        val exponent = rounded.precision() - rounded.scale() - 1
        if (exponent in -4..5) return rounded.stripTrailingZeros().toPlainString()
        val mantissa = rounded.movePointLeft(exponent).stripTrailingZeros().toPlainString()
        val power = abs(exponent).toString().padStart(2, '0')
        return mantissa + (if (exponent < 0) "e-" else "e+") + power
    }
}

/** A described common field stays readable while unavailable; only a writable ready field gets an editor. */
public fun MonitorControlModel.captureField(key: SettingKey): MonitorCaptureField? =
    captureField(key, MonitorCaptureSelection.PENDING)

/** Read a reported or pending value through the same descriptor and editor admission. */
public fun MonitorControlModel.captureField(key: SettingKey, selection: MonitorCaptureSelection): MonitorCaptureField? {
    val title = MonitorCapturePresentation.title(key) ?: return null
    val snapshot = state.value.snapshot ?: return null
    val descriptor = snapshot.capabilities[key] ?: return null
    val authorized = snapshot.authority == ControlAuthority.Owner || snapshot.authority is ControlAuthority.Lease
    val writable = authorized && snapshot.connection == ConnectionState.Ready &&
        descriptor.access == SettingAccess.READ_WRITE && descriptor.availability == Availability.Available
    return MonitorCaptureField(key, title,
        captureValue(key, selection),
        drum(key, descriptor.domain), if (writable) edit(key) else null)
}

/** Readout observations do not require a writable descriptor or create an editor. */
public fun MonitorControlModel.captureValue(key: SettingKey, selection: MonitorCaptureSelection): SettingValue? =
    if (selection == MonitorCaptureSelection.PENDING) shown(key) else state.value.snapshot?.value(key)?.value

/** The drum for a domain, built once per domain rather than on every read. */
private fun MonitorControlModel.drum(key: SettingKey, domain: SettingDomain?): List<MonitorCaptureChoice> {
    if (domain == null) return emptyList()
    captureChoices[key]?.takeIf { it.first == domain }?.let { return it.second }
    return MonitorCapturePresentation.choices(key, domain).also { captureChoices[key] = domain to it }
}

/** Both held gestures and persistent drums commit the editor they opened, never a new one. */
public fun MonitorControlModel.commit(choice: MonitorCaptureChoice, field: MonitorCaptureField): Boolean {
    val editor = field.editor ?: return false
    val current = captureField(field.key) ?: return false
    if (choice !in field.choices || !current.isEditable || current.editor != editor) return false
    return commit(choice.value, editor, "${field.title} ${choice.label}")
}
