package com.opencapture.opencine.appkit

import com.opencapture.opencine.core.Availability
import com.opencapture.opencine.core.ConnectionState
import com.opencapture.opencine.core.ControlAuthority
import com.opencapture.opencine.core.ISOValue
import com.opencapture.opencine.core.SettingAccess
import com.opencapture.opencine.core.SettingDomain
import com.opencapture.opencine.core.SettingKey
import com.opencapture.opencine.core.SettingValue
import com.opencapture.opencine.core.ShutterValue
import com.opencapture.opencine.core.WhiteBalanceValue
import kotlin.math.round
import kotlin.math.floor

/** A drum detent keeps its typed command value. Display copy never becomes a wire mapping. */
public data class MonitorCaptureChoice(public val value: SettingValue, public val label: String)

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

/** Common setting copy and bounded drum sampling. Integrations own the accepted domain. */
public object MonitorCapturePresentation {
    public fun title(key: SettingKey): String? = when (key) {
        SettingKey.ISO -> "ISO"
        SettingKey.SHUTTER -> "SHUTTER"
        SettingKey.APERTURE -> "IRIS"
        SettingKey.WHITE_BALANCE -> "WB"
        SettingKey.EXPOSURE_COMPENSATION -> "EV"
        SettingKey.FOCUS_MODE -> "FOCUS"
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
        is SettingValue.Aperture -> "f/${number(value.fNumber)}"
        is SettingValue.WhiteBalance -> when (val wb = value.value) {
            WhiteBalanceValue.Auto -> "Auto"
            is WhiteBalanceValue.Preset -> wb.id
            is WhiteBalanceValue.Kelvin -> "${wb.kelvin}K"
        }
        is SettingValue.ExposureCompensation -> if (value.stops.numerator == 0) "0.0"
            else (if (value.stops.numerator < 0) "−" else "+") +
                String.format(java.util.Locale.ROOT, "%.1f", kotlin.math.abs(value.stops.doubleValue))
        is SettingValue.FocusMode -> when (value.mode) {
            com.opencapture.opencine.core.FocusMode.MANUAL -> "MF"
            com.opencapture.opencine.core.FocusMode.SINGLE -> "AF-S"
            com.opencapture.opencine.core.FocusMode.CONTINUOUS -> "AF-C"
        }
        else -> ""
    }

    internal fun choices(key: SettingKey, domain: SettingDomain?): List<MonitorCaptureChoice> {
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
                for (index in 0..count) {
                    val kelvin = range.start + index * step
                    if (round(kelvin) == kelvin) {
                        val value = SettingValue.WhiteBalance(WhiteBalanceValue.Kelvin(kelvin.toInt()))
                        if (value in domain && value !in values) values += value
                    }
                }
            }
        }
        return values.map { MonitorCaptureChoice(it, label(it)) }
    }

    private fun number(value: Double): String = if (value == round(value)) value.toLong().toString() else value.toString()
}

/** A described common field stays readable while unavailable; only a writable ready field gets an editor. */
public fun MonitorControlModel.captureField(key: SettingKey): MonitorCaptureField? {
    val title = MonitorCapturePresentation.title(key) ?: return null
    val snapshot = state.value.snapshot ?: return null
    val descriptor = snapshot.capabilities[key] ?: return null
    val authorized = snapshot.authority == ControlAuthority.Owner || snapshot.authority is ControlAuthority.Lease
    val writable = authorized && snapshot.connection == ConnectionState.Ready &&
        descriptor.access == SettingAccess.READ_WRITE && descriptor.availability == Availability.Available
    return MonitorCaptureField(key, title, shown(key), MonitorCapturePresentation.choices(key, descriptor.domain),
        if (writable) edit(key) else null)
}

/** Both held gestures and persistent drums commit the editor they opened, never a new one. */
public fun MonitorControlModel.commit(choice: MonitorCaptureChoice, field: MonitorCaptureField): Boolean {
    val editor = field.editor ?: return false
    val current = captureField(field.key) ?: return false
    if (choice !in field.choices || !current.isEditable || current.editor != editor) return false
    return commit(choice.value, editor, "${field.title} ${choice.label}")
}
