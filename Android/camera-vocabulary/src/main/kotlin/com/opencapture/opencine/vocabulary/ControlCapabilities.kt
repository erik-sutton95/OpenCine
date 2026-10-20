package com.opencapture.opencine.vocabulary

import com.opencapture.opencine.core.Availability
import com.opencapture.opencine.core.CapabilitySnapshot
import com.opencapture.opencine.core.MonitorLayoutCapabilities
import com.opencapture.opencine.core.SettingAccess
import com.opencapture.opencine.core.SettingDescriptor
import com.opencapture.opencine.core.SettingDomain
import com.opencapture.opencine.core.SettingKey
import com.opencapture.opencine.core.SettingSemantics
import com.opencapture.opencine.core.SupportStatus
import com.opencapture.opencine.core.TimecodePrecision
import com.opencapture.opencine.motion.MotionAxis
import com.opencapture.opencine.motion.MotionCapabilities

/**
 * A user-facing camera control family the shared UI may offer. Host features that do not depend on
 * the camera (assists, relay, watch, settings tabs, local clip stars) are not listed: a difference
 * there between apps is a parity gap, never a camera capability. Swift twin: `ControlFamily`.
 */
public enum class ControlFamily(public val id: String) {
    ISO("iso"), SHUTTER("shutter"), WHITE_BALANCE("whiteBalance"), TINT("tint"), IRIS("iris"),
    ND_FILTER("ndFilter"), FOCUS("focus"), TAP_FOCUS("tapFocus"), FACE_METERING("faceMetering"),
    EXPOSURE_COMPENSATION("exposureCompensation"), CODEC_COLOR("codecColor"),
    RECORDING_FORMAT("recordingFormat"), AUDIO("audio"), LIVE_AUDIO_LEVELS("liveAudioLevels"),
    ZOOM("zoom"), GIMBAL("gimbal"), HEAD_TRACKING("headTracking"), TIMECODE("timecode"),
    RECORDING("recording"), PHOTO("photo"), MEDIA("media"), MEDIA_DELETE("mediaDelete"),
    MULTIVIEW("multiview"),
}

/** Support and access of one family, for readers that do not need its values. */
public data class ControlStatus(
    public val support: SupportStatus,
    public val access: SettingAccess = SettingAccess.READ_WRITE,
) {
    /** The shared UI offers the control: supported and writable. */
    public val isOffered: Boolean get() = support == SupportStatus.SUPPORTED && access == SettingAccess.READ_WRITE
    /** The shared UI shows at least its readout. */
    public val isShown: Boolean get() = support == SupportStatus.SUPPORTED
}

/** A family with support only, no values to offer. */
public data object NoOffer

/**
 * One control family: whether the connected camera has it, whether it can be changed, and the
 * typed values it offers. Unknown support is never offered and never "not applicable".
 */
public class ControlCapability<out T>(
    public val support: SupportStatus,
    public val access: SettingAccess = SettingAccess.READ_WRITE,
    offer: T? = null,
) {
    /**
     * The ladder, range or modes, when the source declared them (never for an unsupported family;
     * a family still unknown may carry declared values such as its native ISO extensions).
     */
    public val offer: T? = offer.takeIf { support != SupportStatus.UNSUPPORTED }
    public val status: ControlStatus get() = ControlStatus(support, access)
    public val isOffered: Boolean get() = status.isOffered
    public val isShown: Boolean get() = status.isShown

    override fun equals(other: Any?): Boolean =
        other is ControlCapability<*> && support == other.support && access == other.access && offer == other.offer

    override fun hashCode(): Int = listOf(support, access, offer).hashCode()
    override fun toString(): String = "ControlCapability(support=$support, access=$access, offer=$offer)"

    public companion object {
        public fun <T> unknown(): ControlCapability<T> = ControlCapability(SupportStatus.UNKNOWN)
        public fun <T> unsupported(): ControlCapability<T> = ControlCapability(SupportStatus.UNSUPPORTED)
        public fun <T> supported(offer: T? = null, access: SettingAccess = SettingAccess.READ_WRITE): ControlCapability<T> =
            ControlCapability(SupportStatus.SUPPORTED, access, offer)
    }
}

/** A setting-backed family's values, straight from its Core descriptor. */
public data class SettingOffer(
    public val domain: SettingDomain? = null,
    public val availability: Availability = Availability.Available,
    public val semantics: SettingSemantics = SettingSemantics(),
) {
    public constructor(descriptor: SettingDescriptor) : this(descriptor.domain, descriptor.availability, descriptor.semantics)
}

/** ISO values plus the declared native extensions (dual-native hop, auto ceiling). */
public data class ISOOffer(
    public val setting: SettingOffer? = null,
    public val autoRangeFloor: Int? = null,
    public val nativeISO: CaptureNativeISOCapabilities = CaptureNativeISOCapabilities(),
)

/** Recording format values: the common frame-rate descriptor and the body's declared format lists. */
public data class RecordingFormatOffer(
    public val frameRate: SettingOffer? = null,
    public val fallbacks: Map<Int, List<VideoFormat>> = emptyMap(),
)

/**
 * The one typed camera capability model the shared UI reads to decide what to offer. Static facts
 * per body come from the integration's [CameraCaptureProfile]; dynamic facts from its revisioned
 * [CapabilitySnapshot] and motion declaration. Apps never set a field to a literal.
 * Swift twin: `ControlCapabilities`.
 */
public data class ControlCapabilities(
    public val iso: ControlCapability<ISOOffer> = ControlCapability.unknown(),
    public val shutter: ControlCapability<SettingOffer> = ControlCapability.unknown(),
    public val whiteBalance: ControlCapability<SettingOffer> = ControlCapability.unknown(),
    public val tint: ControlCapability<SettingOffer> = ControlCapability.unknown(),
    public val iris: ControlCapability<SettingOffer> = ControlCapability.unknown(),
    public val ndFilter: ControlCapability<SettingOffer> = ControlCapability.unknown(),
    public val focus: ControlCapability<SettingOffer> = ControlCapability.unknown(),
    public val tapFocus: ControlCapability<NoOffer> = ControlCapability.unknown(),
    public val faceMetering: ControlCapability<NoOffer> = ControlCapability.unknown(),
    public val exposureCompensation: ControlCapability<SettingOffer> = ControlCapability.unknown(),
    public val codecColor: ControlCapability<CaptureCodecColorChoices> = ControlCapability.unknown(),
    public val recordingFormat: ControlCapability<RecordingFormatOffer> = ControlCapability.unknown(),
    /** The camera's audio input settings (the AUDIO tile and sheet). */
    public val audio: ControlCapability<NoOffer> = ControlCapability.unknown(),
    /** Live audio levels the camera reports (the meter). */
    public val liveAudioLevels: ControlCapability<NoOffer> = ControlCapability.unknown(),
    public val zoom: ControlCapability<CameraZoomProfile> = ControlCapability.unknown(),
    public val gimbal: ControlCapability<MotionCapabilities> = ControlCapability.unknown(),
    public val headTracking: ControlCapability<MotionCapabilities> = ControlCapability.unknown(),
    public val timecode: ControlCapability<TimecodePrecision> = ControlCapability.unknown(),
    public val recording: ControlCapability<NoOffer> = ControlCapability.unknown(),
    public val photo: ControlCapability<NoOffer> = ControlCapability.unknown(),
    /** The camera's own clip library can be browsed. */
    public val media: ControlCapability<NoOffer> = ControlCapability.unknown(),
    public val mediaDelete: ControlCapability<NoOffer> = ControlCapability.unknown(),
    /** The body can join a multi-camera stage. */
    public val multiview: ControlCapability<NoOffer> = ControlCapability.unknown(),
    /**
     * Which live header readout carries the app accent, from the body's static profile. The
     * shared header accents the declared slot only when it shows.
     */
    public val headerAccent: MonitorHeaderAccent = MonitorHeaderAccent.SHOOTING_MODE,
) {
    /**
     * Applies typed backend restrictions without inventing support or values. Missing inputs retain
     * the camera's facts; unknown inputs withhold controls; read-only never becomes writable.
     */
    public fun restricting(inputs: Map<ControlFamily, ControlStatus>): ControlCapabilities {
        fun <T> restrict(value: ControlCapability<T>, family: ControlFamily): ControlCapability<T> {
            val input = inputs[family] ?: return value
            val support = when {
                value.support == SupportStatus.UNSUPPORTED || input.support == SupportStatus.UNSUPPORTED -> SupportStatus.UNSUPPORTED
                input.support == SupportStatus.UNKNOWN -> SupportStatus.UNKNOWN
                else -> value.support
            }
            val access = if (value.access == SettingAccess.READ_ONLY || input.access == SettingAccess.READ_ONLY)
                SettingAccess.READ_ONLY else SettingAccess.READ_WRITE
            return ControlCapability(support, access, value.offer)
        }
        return copy(
            iso = restrict(iso, ControlFamily.ISO),
            shutter = restrict(shutter, ControlFamily.SHUTTER),
            whiteBalance = restrict(whiteBalance, ControlFamily.WHITE_BALANCE),
            tint = restrict(tint, ControlFamily.TINT),
            iris = restrict(iris, ControlFamily.IRIS),
            ndFilter = restrict(ndFilter, ControlFamily.ND_FILTER),
            focus = restrict(focus, ControlFamily.FOCUS),
            tapFocus = restrict(tapFocus, ControlFamily.TAP_FOCUS),
            faceMetering = restrict(faceMetering, ControlFamily.FACE_METERING),
            exposureCompensation = restrict(exposureCompensation, ControlFamily.EXPOSURE_COMPENSATION),
            codecColor = restrict(codecColor, ControlFamily.CODEC_COLOR),
            recordingFormat = restrict(recordingFormat, ControlFamily.RECORDING_FORMAT),
            audio = restrict(audio, ControlFamily.AUDIO),
            liveAudioLevels = restrict(liveAudioLevels, ControlFamily.LIVE_AUDIO_LEVELS),
            zoom = restrict(zoom, ControlFamily.ZOOM),
            gimbal = restrict(gimbal, ControlFamily.GIMBAL),
            headTracking = restrict(headTracking, ControlFamily.HEAD_TRACKING),
            timecode = restrict(timecode, ControlFamily.TIMECODE),
            recording = restrict(recording, ControlFamily.RECORDING),
            photo = restrict(photo, ControlFamily.PHOTO),
            media = restrict(media, ControlFamily.MEDIA),
            mediaDelete = restrict(mediaDelete, ControlFamily.MEDIA_DELETE),
            multiview = restrict(multiview, ControlFamily.MULTIVIEW),
        )
    }

    /** Support and access of [family]. */
    public fun status(family: ControlFamily): ControlStatus = when (family) {
        ControlFamily.ISO -> iso.status
        ControlFamily.SHUTTER -> shutter.status
        ControlFamily.WHITE_BALANCE -> whiteBalance.status
        ControlFamily.TINT -> tint.status
        ControlFamily.IRIS -> iris.status
        ControlFamily.ND_FILTER -> ndFilter.status
        ControlFamily.FOCUS -> focus.status
        ControlFamily.TAP_FOCUS -> tapFocus.status
        ControlFamily.FACE_METERING -> faceMetering.status
        ControlFamily.EXPOSURE_COMPENSATION -> exposureCompensation.status
        ControlFamily.CODEC_COLOR -> codecColor.status
        ControlFamily.RECORDING_FORMAT -> recordingFormat.status
        ControlFamily.AUDIO -> audio.status
        ControlFamily.LIVE_AUDIO_LEVELS -> liveAudioLevels.status
        ControlFamily.ZOOM -> zoom.status
        ControlFamily.GIMBAL -> gimbal.status
        ControlFamily.HEAD_TRACKING -> headTracking.status
        ControlFamily.TIMECODE -> timecode.status
        ControlFamily.RECORDING -> recording.status
        ControlFamily.PHOTO -> photo.status
        ControlFamily.MEDIA -> media.status
        ControlFamily.MEDIA_DELETE -> mediaDelete.status
        ControlFamily.MULTIVIEW -> multiview.status
    }

    /** The declared native ISO extensions (dual-native hop, auto ceiling); unknown when not declared. */
    public val nativeISO: CaptureNativeISOCapabilities get() = iso.offer?.nativeISO ?: CaptureNativeISOCapabilities()

    /** Every family the shared UI offers as a control. */
    public val offered: Set<ControlFamily> get() = ControlFamily.entries.filter { status(it).isOffered }.toSet()

    public companion object {
        /**
         * The one pre-connection rule, the same in every app (Swift `init(beforeConnection:)`):
         * before a camera is connected the shared UI offers only what the static [profile] of the
         * known camera model declares; with no model known it offers no camera-dependent control.
         */
        public fun beforeConnection(
            profile: CameraCaptureProfile?,
            motion: MotionCapabilities? = null,
            codecColor: CaptureCodecColorChoices? = null,
        ): ControlCapabilities =
            if (profile == null) ControlCapabilities() else derive(CapabilitySnapshot(), profile, motion, codecColor)

        /**
         * Merges the integration's declarations into one model: [snapshot] is the live Core
         * capabilities, [profile] the body's static declaration (`null` while no body is known),
         * [motion] the body's motion service (with a known body `null` means none), [codecColor]
         * the codec and colour choices the camera offers now, when the host has them.
         */
        public fun derive(
            snapshot: CapabilitySnapshot,
            profile: CameraCaptureProfile?,
            motion: MotionCapabilities? = null,
            codecColor: CaptureCodecColorChoices? = null,
        ): ControlCapabilities {
            val declared = profile?.controls.orEmpty()
            fun writable(key: SettingKey) = snapshot[key]?.access == SettingAccess.READ_WRITE
            fun flag(value: Boolean?): SupportStatus? = value?.let { if (it) SupportStatus.SUPPORTED else SupportStatus.UNSUPPORTED }
            fun setting(key: SettingKey, family: ControlFamily): ControlCapability<SettingOffer> {
                snapshot[key]?.let { return ControlCapability.supported(SettingOffer(it), it.access) }
                declared[family]?.takeIf { it != SupportStatus.UNKNOWN }?.let { return ControlCapability(it) }
                return ControlCapability(snapshot.support(key))
            }
            fun control(keys: List<SettingKey>, declaration: Boolean?): ControlStatus {
                if (keys.any(::writable)) return ControlStatus(SupportStatus.SUPPORTED)
                flag(declaration)?.let { return ControlStatus(it) }
                keys.firstNotNullOfOrNull { snapshot[it] }?.let { return ControlStatus(SupportStatus.SUPPORTED, it.access) }
                val all = keys.all { snapshot.support(it) == SupportStatus.UNSUPPORTED }
                return ControlStatus(if (all) SupportStatus.UNSUPPORTED else SupportStatus.UNKNOWN)
            }
            fun declaredOnly(family: ControlFamily): ControlCapability<NoOffer> =
                ControlCapability(declared[family] ?: SupportStatus.UNKNOWN)

            val isoBase = setting(SettingKey.ISO, ControlFamily.ISO)
            val iso = ControlCapability(isoBase.support, isoBase.access, ISOOffer(snapshot[SettingKey.ISO]?.let(::SettingOffer),
                profile?.isoAutoRangeFloor, profile?.nativeISO ?: CaptureNativeISOCapabilities()))
            // Iris: a declared iris control (for example a variable-iris strategy panel over a
            // read-only f-number) or a writable aperture.
            val iris = control(listOf(SettingKey.APERTURE), profile?.supportsAperture)
            val focus = control(listOf(SettingKey.FOCUS_MODE, SettingKey.FOCUS_POINT), profile?.supportsFocusMode)
            val tap = if (snapshot.support(SettingKey.FOCUS_POINT) == SupportStatus.SUPPORTED) SupportStatus.SUPPORTED
                else flag(profile?.supportsTapFocus) ?: snapshot.support(SettingKey.FOCUS_POINT)
            val zoom = control(listOf(SettingKey.ZOOM), profile?.supportsZoom)
            val frameRate = snapshot[SettingKey.FRAME_RATE]?.let(::SettingOffer)
            val fallbacks = profile?.videoFormatFallbacks.orEmpty()
            val codec = if (codecColor != null) {
                val any = codecColor.showsCodec || codecColor.showsColor
                ControlCapability(if (any) SupportStatus.SUPPORTED else declared[ControlFamily.CODEC_COLOR] ?: SupportStatus.UNKNOWN,
                    if (codecColor.codecEditable || codecColor.colorEditable || !any) SettingAccess.READ_WRITE else SettingAccess.READ_ONLY,
                    codecColor)
            } else ControlCapability(declared[ControlFamily.CODEC_COLOR] ?: SupportStatus.UNKNOWN)
            // Motion: gimbal when the service drives pan and tilt; head tracking when it also
            // reports the camera's pose. With no body known both stay unknown.
            val (gimbal, head) = when {
                motion != null -> {
                    val steers = motion.axes.containsAll(listOf(MotionAxis.PAN, MotionAxis.TILT))
                    ControlCapability(if (steers) SupportStatus.SUPPORTED else SupportStatus.UNSUPPORTED, offer = motion) to
                        ControlCapability(if (steers) motion.pose else SupportStatus.UNSUPPORTED, offer = motion)
                }
                profile != null -> {
                    val none = if (profile.hasGimbal == true) SupportStatus.UNKNOWN else SupportStatus.UNSUPPORTED
                    ControlCapability<MotionCapabilities>(none) to ControlCapability<MotionCapabilities>(none)
                }
                else -> ControlCapability.unknown<MotionCapabilities>() to ControlCapability.unknown()
            }
            return ControlCapabilities(
                iso = iso,
                shutter = setting(SettingKey.SHUTTER, ControlFamily.SHUTTER),
                whiteBalance = setting(SettingKey.WHITE_BALANCE, ControlFamily.WHITE_BALANCE),
                tint = setting(SettingKey.WHITE_BALANCE_TINT, ControlFamily.TINT),
                iris = ControlCapability(iris.support, iris.access, snapshot[SettingKey.APERTURE]?.let(::SettingOffer)),
                ndFilter = ControlCapability(declared[ControlFamily.ND_FILTER] ?: SupportStatus.UNKNOWN),
                focus = ControlCapability(focus.support, focus.access, snapshot[SettingKey.FOCUS_MODE]?.let(::SettingOffer)),
                tapFocus = ControlCapability(tap),
                faceMetering = declaredOnly(ControlFamily.FACE_METERING),
                exposureCompensation = setting(SettingKey.EXPOSURE_COMPENSATION, ControlFamily.EXPOSURE_COMPENSATION),
                codecColor = codec,
                recordingFormat = ControlCapability(
                    declared[ControlFamily.RECORDING_FORMAT]
                        ?: if (frameRate != null || fallbacks.isNotEmpty()) SupportStatus.SUPPORTED else SupportStatus.UNKNOWN,
                    offer = RecordingFormatOffer(frameRate, fallbacks)),
                // Audio input settings follow the body's declaration, else live levels (a body that
                // reports levels has an input to set).
                audio = ControlCapability(declared[ControlFamily.AUDIO] ?: snapshot.audioLevels),
                liveAudioLevels = ControlCapability(snapshot.audioLevels, SettingAccess.READ_ONLY),
                zoom = ControlCapability(zoom.support, zoom.access, profile?.zoom),
                gimbal = gimbal,
                headTracking = head,
                timecode = ControlCapability(snapshot.timecodeCapability.support, SettingAccess.READ_ONLY, snapshot.timecodeCapability.precision),
                recording = ControlCapability(
                    if (snapshot[SettingKey.RECORDING] != null) SupportStatus.SUPPORTED
                    else declared[ControlFamily.RECORDING] ?: snapshot.support(SettingKey.RECORDING)),
                photo = declaredOnly(ControlFamily.PHOTO),
                media = declaredOnly(ControlFamily.MEDIA),
                mediaDelete = declaredOnly(ControlFamily.MEDIA_DELETE),
                multiview = declaredOnly(ControlFamily.MULTIVIEW),
                headerAccent = profile?.headerAccent ?: MonitorHeaderAccent.SHOOTING_MODE,
            )
        }
    }
}

/**
 * The ten-section layout as a computed view of the one model: a control section lays out when its
 * family is offered, the timecode slot when the camera reports timecode. `clipDelete`, `clipStar`
 * and `requiresInternetHop` are host policy and come from [base]; a family whose support is
 * unknown keeps [base]. Swift: `MonitorLayoutCapabilities(controls:base:)`.
 */
public fun MonitorLayoutCapabilities(
    controls: ControlCapabilities,
    base: MonitorLayoutCapabilities = MonitorLayoutCapabilities(),
): MonitorLayoutCapabilities {
    fun lays(status: ControlStatus, base: Boolean, readout: Boolean = false) = when (status.support) {
        SupportStatus.SUPPORTED -> if (readout) status.isShown else status.isOffered
        SupportStatus.UNSUPPORTED -> false
        SupportStatus.UNKNOWN -> base
    }
    val gimbal = lays(controls.gimbal.status, base.gimbal)
    return base.copy(
        gimbal = gimbal,
        headTracking = gimbal && lays(controls.headTracking.status, base.headTracking),
        zoom = lays(controls.zoom.status, base.zoom),
        focus = lays(controls.focus.status, base.focus),
        iris = lays(controls.iris.status, base.iris),
        audio = lays(controls.audio.status, base.audio),
        timecode = lays(controls.timecode.status, base.timecode, readout = true),
    )
}

/**
 * The machine-readable export of the model: one tab-separated row per body and family,
 * `integration body family state`, state one of offered, readout, unsupported, unknown. The Swift
 * integration tests write `Fixtures/control-capabilities-<integration>.tsv`; the Kotlin integration
 * tests check their twin renders the same text. Swift twin: `ControlCapabilityVectors`.
 */
public object ControlCapabilityVectors {
    public const val HEADER: String =
        "# Generated by the integration's ControlCapabilityFixture test; do not edit.\n" +
            "# integration\tbody\tfamily\tstate"

    public fun state(status: ControlStatus): String = when (status.support) {
        SupportStatus.SUPPORTED -> if (status.access == SettingAccess.READ_WRITE) "offered" else "readout"
        SupportStatus.UNSUPPORTED -> "unsupported"
        SupportStatus.UNKNOWN -> "unknown"
    }

    /** Every family of [body], in [ControlFamily] order. */
    public fun rows(integration: String, body: String, controls: ControlCapabilities): List<String> =
        ControlFamily.entries.map { listOf(integration, body, it.id, state(controls.status(it))).joinToString("\t") }

    /** The whole file for [bodies], in the given order, ending with a newline. */
    public fun document(integration: String, bodies: List<Pair<String, ControlCapabilities>>): String =
        (listOf(HEADER) + bodies.flatMap { (body, controls) -> rows(integration, body, controls) }).joinToString("\n") + "\n"
}
