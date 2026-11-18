package com.opencapture.opencine.core

import java.util.UUID

/**
 * A named set of exposure and white balance values the operator saved from a camera, recalled
 * later through the common setting commands. The values are common [SettingValue]s, so a preset
 * carries no wire bytes and names no manufacturer: what a camera can take back is decided by its
 * setting descriptors at recall time. Swift twin: `CameraSettingsPreset`.
 */
public class CameraSettingsPreset(
    public val id: String = UUID.randomUUID().toString(),
    public val name: String,
    values: List<SettingValue>,
) {
    /** At most one value per key of [KEYS], in recall order. Later values for a key replace earlier ones. */
    public val values: List<SettingValue> = values.filter { it.key in KEYS }.associateBy { it.key }
        .let { byKey -> KEYS.mapNotNull { byKey[it] } }

    public fun value(key: SettingKey): SettingValue? = values.firstOrNull { it.key == key }

    public fun copy(id: String = this.id, name: String = this.name, values: List<SettingValue> = this.values):
        CameraSettingsPreset = CameraSettingsPreset(id, name, values)

    override fun equals(other: Any?): Boolean =
        other is CameraSettingsPreset && id == other.id && name == other.name && values == other.values

    override fun hashCode(): Int = (id.hashCode() * 31 + name.hashCode()) * 31 + values.hashCode()

    override fun toString(): String = "CameraSettingsPreset(id=$id, name=$name, values=$values)"

    public companion object {
        /**
         * The settings a preset holds, in recall order: white balance before its tint (a tint rides
         * on a known white balance), then ISO, shutter, aperture and exposure compensation.
         */
        public val KEYS: List<SettingKey> = listOf(
            SettingKey.WHITE_BALANCE, SettingKey.WHITE_BALANCE_TINT, SettingKey.ISO, SettingKey.SHUTTER,
            SettingKey.APERTURE, SettingKey.EXPOSURE_COMPENSATION,
        )

        /**
         * The values the operator can set on [snapshot]'s camera right now: each preset key the
         * camera describes as writable and available, with a valid reported value inside its
         * domain. `null` when there is none.
         */
        public fun capture(
            name: String, snapshot: CameraSnapshot, id: String = UUID.randomUUID().toString(),
        ): CameraSettingsPreset? {
            val values = KEYS.mapNotNull { key ->
                val descriptor = snapshot.capabilities[key] ?: return@mapNotNull null
                if (descriptor.access != SettingAccess.READ_WRITE || descriptor.availability != Availability.Available) {
                    return@mapNotNull null
                }
                val observed = snapshot.value(key)
                val value = observed.value
                if (observed.validity != ObservationValidity.Valid || value == null || !descriptor.accepts(value)) null
                else value
            }
            return if (values.isEmpty()) null else CameraSettingsPreset(id, name, values)
        }
    }
}

/** Why a recall left a preset value out: the camera it was recalled on cannot take it now. */
public sealed interface CameraSettingsPresetSkip {
    /** The camera does not describe the setting (or says it has none). */
    public data object Unsupported : CameraSettingsPresetSkip
    public data object ReadOnly : CameraSettingsPresetSkip
    public data class Unavailable(public val reason: UnavailableReason) : CameraSettingsPresetSkip
    /** The camera offers the setting, but not this value. */
    public data object OutOfDomain : CameraSettingsPresetSkip

    public companion object {
        /**
         * The skip a shared admission rejection stands for; `null` for a rejection about the link,
         * authority or stale state rather than what the camera can do.
         */
        public fun of(rejection: CommandRejection): CameraSettingsPresetSkip? = when (rejection) {
            CommandRejection.Unsupported, CommandRejection.SupportUnknown -> Unsupported
            CommandRejection.ReadOnly -> ReadOnly
            is CommandRejection.Unavailable -> Unavailable(rejection.reason)
            CommandRejection.OutOfDomain -> OutOfDomain
            else -> null
        }
    }
}

/** What recalling one preset did, value by value, in recall order. */
public data class CameraSettingsPresetRecall(public val name: String, public val entries: List<Entry>) {
    public sealed interface Outcome {
        /** The camera confirmed it (or acknowledged it, where it only acknowledges). */
        public data object Applied : Outcome
        /** The camera already reported this value; nothing was sent. */
        public data object Unchanged : Outcome
        /** The camera cannot take it now; nothing was sent. */
        public data class Skipped(public val skip: CameraSettingsPresetSkip) : Outcome
        /** Refused for another reason, or sent without a confirmation; the stage says which. */
        public data class Failed(public val stage: CommandStage) : Outcome
    }

    public data class Entry(public val value: SettingValue, public val outcome: Outcome)

    public val applied: List<SettingKey> get() = entries.filter { it.outcome == Outcome.Applied }.map { it.value.key }

    public val skipped: List<Pair<SettingKey, CameraSettingsPresetSkip>>
        get() = entries.mapNotNull { entry -> (entry.outcome as? Outcome.Skipped)?.let { entry.value.key to it.skip } }

    public val failed: List<Pair<SettingKey, CommandStage>>
        get() = entries.mapNotNull { entry -> (entry.outcome as? Outcome.Failed)?.let { entry.value.key to it.stage } }
}

/**
 * The stored text of a preset list: a version line, then one line per preset with tab-separated
 * id, name and value tokens. Unknown tokens and malformed lines are skipped, so a list written by a
 * later version still loads what this one understands. Swift twin: `CameraSettingsPresetCodec`,
 * same text for the same presets.
 */
public object CameraSettingsPresetCodec {
    private const val HEADER = "opencine-presets 1"

    public fun encode(presets: List<CameraSettingsPreset>): String = buildList {
        add(HEADER)
        for (preset in presets) {
            add((listOf(clean(preset.id), clean(preset.name)) + preset.values.mapNotNull(::token)).joinToString("\t"))
        }
    }.joinToString("\n")

    public fun decode(text: String): List<CameraSettingsPreset> {
        val lines = text.split("\n").filter { it.isNotEmpty() }
        if (lines.firstOrNull() != HEADER) return emptyList()
        val seen = HashSet<String>()
        return lines.drop(1).mapNotNull { line ->
            val fields = line.split("\t")
            if (fields.size < 2 || fields[0].isEmpty() || !seen.add(fields[0])) return@mapNotNull null
            val values = fields.drop(2).mapNotNull(::value)
            if (values.isEmpty()) null else CameraSettingsPreset(fields[0], fields[1], values)
        }
    }

    private fun clean(text: String): String = text.replace('\t', ' ').replace('\r', ' ').replace('\n', ' ')

    internal fun token(value: SettingValue): String? = when (value) {
        is SettingValue.Iso -> when (val iso = value.value) {
            ISOValue.Auto -> "iso=auto"
            is ISOValue.AutoLimited -> "iso=auto:${iso.maximum}"
            is ISOValue.Manual -> "iso=${iso.iso}"
        }
        is SettingValue.Shutter -> when (val shutter = value.value) {
            ShutterValue.Auto -> "shutter=auto"
            is ShutterValue.Duration -> "shutter=${shutter.seconds.numerator}/${shutter.seconds.denominator}"
            is ShutterValue.Angle -> "shutter=${shutter.degrees}deg"
        }
        is SettingValue.Aperture -> "aperture=${value.fNumber}"
        is SettingValue.ExposureCompensation -> "ev=${value.stops.numerator}/${value.stops.denominator}"
        is SettingValue.WhiteBalance -> when (val wb = value.value) {
            WhiteBalanceValue.Auto -> "wb=auto"
            is WhiteBalanceValue.Kelvin -> "wb=${wb.kelvin}K"
            is WhiteBalanceValue.Preset -> "wb=preset:${clean(wb.id)}"
        }
        is SettingValue.WhiteBalanceTint -> "tint=${value.tint}"
        is SettingValue.FrameRate, is SettingValue.FocusMode, is SettingValue.Zoom -> null
    }

    internal fun value(token: String): SettingValue? {
        val equals = token.indexOf('=')
        if (equals < 0) return null
        val text = token.substring(equals + 1)
        return when (token.substring(0, equals)) {
            "iso" -> when {
                text == "auto" -> SettingValue.Iso(ISOValue.Auto)
                text.startsWith("auto:") -> text.removePrefix("auto:").toIntOrNull()?.let { SettingValue.Iso(ISOValue.AutoLimited(it)) }
                else -> text.toIntOrNull()?.let { SettingValue.Iso(ISOValue.Manual(it)) }
            }
            "shutter" -> when {
                text == "auto" -> SettingValue.Shutter(ShutterValue.Auto)
                text.endsWith("deg") -> double(text.removeSuffix("deg"))?.let { SettingValue.Shutter(ShutterValue.Angle(it)) }
                else -> rational(text)?.let { SettingValue.Shutter(ShutterValue.Duration(it)) }
            }
            "aperture" -> double(text)?.let { SettingValue.Aperture(it) }
            "ev" -> rational(text)?.let { SettingValue.ExposureCompensation(it) }
            "wb" -> when {
                text == "auto" -> SettingValue.WhiteBalance(WhiteBalanceValue.Auto)
                text.startsWith("preset:") -> text.removePrefix("preset:").takeIf { it.isNotEmpty() }
                    ?.let { SettingValue.WhiteBalance(WhiteBalanceValue.Preset(it)) }
                text.endsWith("K") -> text.removeSuffix("K").toIntOrNull()?.let { SettingValue.WhiteBalance(WhiteBalanceValue.Kelvin(it)) }
                else -> null
            }
            "tint" -> double(text)?.let { SettingValue.WhiteBalanceTint(it) }
            else -> null
        }
    }

    private fun double(text: String): Double? = text.toDoubleOrNull()?.takeIf { it.isFinite() }

    private fun rational(text: String): Rational? {
        val parts = text.split("/")
        if (parts.size != 2) return null
        val numerator = parts[0].toIntOrNull() ?: return null
        val denominator = parts[1].toIntOrNull() ?: return null
        return if (denominator == 0) null else Rational(numerator, denominator)
    }
}
