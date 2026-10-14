package com.opencapture.opencine.core

import kotlin.math.abs
import kotlin.math.max
import kotlin.math.round

/** An exact ratio, normalized so that equal values compare equal (2/100 == 1/50). */
public class Rational(numerator: Int, denominator: Int = 1) {
    public val numerator: Int
    public val denominator: Int

    init {
        require(denominator != 0) { "Rational denominator must not be zero" }
        var a = abs(numerator)
        var b = abs(denominator)
        while (b != 0) {
            val remainder = a % b
            a = b
            b = remainder
        }
        val divisor = max(a, 1) * if (denominator < 0) -1 else 1
        this.numerator = numerator / divisor
        this.denominator = denominator / divisor
    }

    public val doubleValue: Double get() = numerator.toDouble() / denominator

    override fun equals(other: Any?): Boolean =
        other is Rational && numerator == other.numerator && denominator == other.denominator

    override fun hashCode(): Int = 31 * numerator + denominator

    override fun toString(): String = "$numerator/$denominator"

    public companion object {
        /**
         * The exact rate for a source that reports frames per second as a decimal: whole rates stay
         * whole, the NTSC family (23.976, 29.97, 59.94, ...) is N*1000/1001, anything else keeps
         * thousandths. `null` when not a positive finite rate. Swift twin: `Rational.frameRate`.
         */
        public fun frameRate(framesPerSecond: Double): Rational? {
            if (!framesPerSecond.isFinite() || framesPerSecond <= 0 || framesPerSecond >= 100_000) return null
            // Half up, as Swift's rounded() for positive values.
            val whole = Math.round(framesPerSecond)
            if (abs(framesPerSecond - whole) < 0.005) return Rational(whole.toInt())
            val ntsc = Math.round(framesPerSecond * 1.001)
            if (abs(framesPerSecond - ntsc / 1.001) < 0.005) return Rational(ntsc.toInt() * 1000, 1001)
            return Rational(Math.round(framesPerSecond * 1000).toInt(), 1000)
        }
    }
}

/**
 * The small common setting vocabulary. Expand only for a real use case.
 *
 * [RECORDING] and [FOCUS_POINT] are command-only controls: they carry support, access and
 * availability but no value domain. Recording is commanded with explicit start/stop intents and
 * observed through [CameraSnapshot.recording].
 */
public enum class SettingKey {
    ISO,
    SHUTTER,
    APERTURE,
    EXPOSURE_COMPENSATION,
    WHITE_BALANCE,

    /**
     * White balance tint, a separate setting because cameras expose it apart from the white
     * balance mode (plan 5.6). A camera without tint lists it as unsupported.
     */
    WHITE_BALANCE_TINT,
    FRAME_RATE,
    FOCUS_MODE,
    ZOOM,
    RECORDING,
    FOCUS_POINT,
}

/** ISO is an enumerated ladder, auto, or auto bounded by a ceiling. Never assume every integer. */
public sealed interface ISOValue {
    public data object Auto : ISOValue

    public data class AutoLimited(public val maximum: Int) : ISOValue

    public data class Manual(public val iso: Int) : ISOValue
}

/**
 * Native duration mode keeps the duration when the recording frame rate changes; native angle
 * mode keeps the angle. A camera's domain contains only the mode it is in, so a duration is never
 * silently converted to an angle (or back) and the camera mode is never changed as a side effect.
 */
public sealed interface ShutterValue {
    public data object Auto : ShutterValue

    /** Exposure time in seconds, for example 1/50. */
    public data class Duration(public val seconds: Rational) : ShutterValue

    /** Shutter angle in degrees, for example 180. */
    public data class Angle(public val degrees: Double) : ShutterValue
}

public sealed interface WhiteBalanceValue {
    public data object Auto : WhiteBalanceValue

    /** Integration-owned preset identifier such as `daylight`. */
    public data class Preset(public val id: String) : WhiteBalanceValue

    public data class Kelvin(public val kelvin: Int) : WhiteBalanceValue
}

public enum class FocusMode { MANUAL, SINGLE, CONTINUOUS }

/**
 * The reviewed sum type used wherever settings are collected, serialized or shown generically.
 * Each case implies its key, so a value can never be filed under the wrong setting.
 */
public sealed interface SettingValue {
    public data class Iso(public val value: ISOValue) : SettingValue

    public data class Shutter(public val value: ShutterValue) : SettingValue

    public data class Aperture(public val fNumber: Double) : SettingValue

    /** Stops, for example -1/3. */
    public data class ExposureCompensation(public val stops: Rational) : SettingValue

    public data class WhiteBalance(public val value: WhiteBalanceValue) : SettingValue

    /**
     * Green-magenta offset on the integration's own scale (its domain gives range and step).
     * Positive is toward magenta. Applies on top of the white balance mode, auto included.
     */
    public data class WhiteBalanceTint(public val tint: Double) : SettingValue

    /** Recording frame rate in frames per second, for example 24000/1001. */
    public data class FrameRate(public val fps: Rational) : SettingValue

    public data class FocusMode(public val mode: com.opencapture.opencine.core.FocusMode) : SettingValue

    /** Zoom ratio, 1 = widest. */
    public data class Zoom(public val ratio: Double) : SettingValue

    public val key: SettingKey
        get() = when (this) {
            is Iso -> SettingKey.ISO
            is Shutter -> SettingKey.SHUTTER
            is Aperture -> SettingKey.APERTURE
            is ExposureCompensation -> SettingKey.EXPOSURE_COMPENSATION
            is WhiteBalance -> SettingKey.WHITE_BALANCE
            is WhiteBalanceTint -> SettingKey.WHITE_BALANCE_TINT
            is FrameRate -> SettingKey.FRAME_RATE
            is FocusMode -> SettingKey.FOCUS_MODE
            is Zoom -> SettingKey.ZOOM
        }

    /** The number a [SettingDomain.range] constrains. Other values must be listed as choices. */
    public val numericValue: Double?
        get() = when (this) {
            is Iso -> (value as? ISOValue.Manual)?.iso?.toDouble()
            is Aperture -> fNumber
            is WhiteBalance -> (value as? WhiteBalanceValue.Kelvin)?.kelvin?.toDouble()
            is WhiteBalanceTint -> tint
            is Zoom -> ratio
            else -> null
        }
}

/**
 * Layer 2: valid values. A value is valid when it is one of [choices], or when its
 * [SettingValue.numericValue] lies in [range] on a [step] boundary. Automatic modes are listed as
 * choices. The unit is implied by the setting key.
 */
public data class SettingDomain(
    public val choices: List<SettingValue> = emptyList(),
    public val range: ClosedFloatingPointRange<Double>? = null,
    public val step: Double? = null,
) {
    public operator fun contains(value: SettingValue): Boolean {
        if (value in choices) return true
        val x = value.numericValue ?: return false
        if (range == null || x !in range) return false
        if (step == null || step <= 0) return true
        val steps = (x - range.start) / step
        return abs(steps - round(steps)) < 1e-9 * max(1.0, abs(steps))
    }
}

/** Layer 1: support. */
public enum class SupportStatus {
    SUPPORTED,
    UNSUPPORTED,

    /** Not yet discovered for this device, firmware, route or mode. */
    UNKNOWN,
}

/**
 * How precisely a source counts its timecode. Shared formatting follows it, so a seconds-only
 * source never shows a frame field and a frame-counting source never loses one.
 */
public sealed interface TimecodePrecision {
    /** Whole seconds only (a host clock, or a counter whose frame field is not proven per frame). */
    public data object Seconds : TimecodePrecision

    /** Frames at [rate]. [dropFrame] is `null` when the camera does not say. */
    public data class Frames(public val rate: Rational, public val dropFrame: Boolean? = null) : TimecodePrecision
}

/**
 * Support for [CameraSnapshot.timecode] plus its declared precision. [precision] is `null` while
 * support is not [SupportStatus.SUPPORTED] or the source has not said how it counts.
 */
public class TimecodeCapability(
    public val support: SupportStatus = SupportStatus.UNKNOWN,
    precision: TimecodePrecision? = null,
) {
    public val precision: TimecodePrecision? = precision.takeIf { support == SupportStatus.SUPPORTED }

    override fun equals(other: Any?): Boolean =
        other is TimecodeCapability && support == other.support && precision == other.precision

    override fun hashCode(): Int = 31 * support.hashCode() + precision.hashCode()

    override fun toString(): String = "TimecodeCapability(support=$support, precision=$precision)"

    public companion object {
        public val unknown: TimecodeCapability = TimecodeCapability()
        public val unsupported: TimecodeCapability = TimecodeCapability(SupportStatus.UNSUPPORTED)
        public fun supported(precision: TimecodePrecision?): TimecodeCapability =
            TimecodeCapability(SupportStatus.SUPPORTED, precision)
    }
}

public enum class SettingAccess { READ_ONLY, READ_WRITE }

public sealed interface UnavailableReason {
    public data object RecordingActive : UnavailableReason
    public data object Mode : UnavailableReason
    public data object Link : UnavailableReason
    public data object Authority : UnavailableReason
    public data object Busy : UnavailableReason
    public data object Route : UnavailableReason

    /** A camera prerequisite is not met yet, for example its own live view is not running. */
    public data object NotReady : UnavailableReason

    public data class OtherSetting(public val key: SettingKey) : UnavailableReason
}

/** Layer 3: current availability. */
public sealed interface Availability {
    public data object Available : Availability

    public data class Unavailable(public val reason: UnavailableReason) : Availability
}

/** Layer 4: semantics and evidence. */
public data class SettingSemantics(
    public val implementation: Implementation = Implementation.NATIVE,
    public val confirmation: Confirmation = Confirmation.READBACK,
    public val qualification: Qualification = Qualification.UNQUALIFIED,
) {
    public enum class Implementation {
        NATIVE,

        /** Implemented by the integration on top of other camera behavior, with side effects. */
        EMULATED,
    }

    public enum class Confirmation {
        /** The camera later reports the resulting value; commands wait for it. */
        READBACK,

        /** The camera only acknowledges; an accepted command is finished. */
        ACKNOWLEDGEMENT_ONLY,
    }

    public enum class Qualification { QUALIFIED, UNQUALIFIED }
}

/**
 * Layers 2 to 4 of one supported setting. Layer 1 lives in [CapabilitySnapshot].
 * Display titles are UI copy and stay in the UI.
 */
public data class SettingDescriptor(
    public val key: SettingKey,
    public val access: SettingAccess = SettingAccess.READ_WRITE,
    /** `null` for command-only controls. */
    public val domain: SettingDomain? = null,
    public val availability: Availability = Availability.Available,
    public val semantics: SettingSemantics = SettingSemantics(),
) {
    /** Whether [value] belongs to this setting and its current domain. */
    public fun accepts(value: SettingValue): Boolean = value.key == key && domain?.contains(value) == true
}

/**
 * The revisioned set of setting descriptors, plus support for the observations that are not
 * settings. A key that is neither described nor listed as unsupported has unknown support.
 * Missing groups (no aperture, say) never block the rest.
 */
@ConsistentCopyVisibility
public data class CapabilitySnapshot private constructor(
    public val revision: CapabilityRevision,
    public val descriptors: Map<SettingKey, SettingDescriptor>,
    public val unsupported: Set<SettingKey>,
    public val timecode: SupportStatus,
    public val audioLevels: SupportStatus,
    public val timecodeCapability: TimecodeCapability,
) {
    /** Retain the published JVM zero-argument constructor as well as Kotlin default calls. */
    public constructor() : this(CapabilityRevision(), emptyMap(), emptySet(), SupportStatus.UNKNOWN, SupportStatus.UNKNOWN)

    /** The published constructor retains its parameter order and value types. */
    public constructor(
        revision: CapabilityRevision = CapabilityRevision(),
        descriptors: Map<SettingKey, SettingDescriptor> = emptyMap(),
        unsupported: Set<SettingKey> = emptySet(),
        timecode: SupportStatus = SupportStatus.UNKNOWN,
        audioLevels: SupportStatus = SupportStatus.UNKNOWN,
    ) : this(revision, descriptors, unsupported, timecode, audioLevels, TimecodeCapability(timecode))

    /** Copy the published fields without losing an unchanged precision-rich reading. */
    public fun copy(
        revision: CapabilityRevision = this.revision,
        descriptors: Map<SettingKey, SettingDescriptor> = this.descriptors,
        unsupported: Set<SettingKey> = this.unsupported,
        timecode: SupportStatus = this.timecode,
        audioLevels: SupportStatus = this.audioLevels,
    ): CapabilitySnapshot = CapabilitySnapshot(revision, descriptors, unsupported, timecode, audioLevels,
        if (timecode == this.timecode) timecodeCapability else TimecodeCapability(timecode))

    /** Replace the precise value, projecting the legacy field only when representable. */
    public fun withTimecodeCapability(value: TimecodeCapability): CapabilitySnapshot =
        CapabilitySnapshot(revision, descriptors, unsupported, value.support, audioLevels, value)

    /** Support and precision use a distinct, required label beside the support-only constructor. */
    public constructor(
        timecodeCapability: TimecodeCapability,
        revision: CapabilityRevision = CapabilityRevision(),
        descriptors: Map<SettingKey, SettingDescriptor> = emptyMap(),
        unsupported: Set<SettingKey> = emptySet(),
        audioLevels: SupportStatus = SupportStatus.UNKNOWN,
    ) : this(revision, descriptors, unsupported, timecodeCapability.support, audioLevels, timecodeCapability)

    /** Later descriptors for the same key replace earlier ones. */
    public constructor(
        revision: CapabilityRevision = CapabilityRevision(),
        descriptors: List<SettingDescriptor>,
        unsupported: Set<SettingKey> = emptySet(),
        timecode: SupportStatus = SupportStatus.UNKNOWN,
        audioLevels: SupportStatus = SupportStatus.UNKNOWN,
    ) : this(revision, descriptors.associateBy { it.key }, unsupported, timecode, audioLevels)

    public constructor(
        timecodeCapability: TimecodeCapability,
        revision: CapabilityRevision = CapabilityRevision(),
        descriptors: List<SettingDescriptor>,
        unsupported: Set<SettingKey> = emptySet(),
        audioLevels: SupportStatus = SupportStatus.UNKNOWN,
    ) : this(timecodeCapability, revision, descriptors.associateBy { it.key }, unsupported, audioLevels)

    public operator fun get(key: SettingKey): SettingDescriptor? = descriptors[key]

    public fun support(key: SettingKey): SupportStatus = when {
        key in descriptors -> SupportStatus.SUPPORTED
        key in unsupported -> SupportStatus.UNSUPPORTED
        else -> SupportStatus.UNKNOWN
    }
}
