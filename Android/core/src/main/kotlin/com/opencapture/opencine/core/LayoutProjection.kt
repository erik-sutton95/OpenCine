package com.opencapture.opencine.core

/**
 * A compact layout projection for shared UI, kept apart from the domain model, and the one
 * layout type (the conformance profile declares its review body in it too). The ten fields
 * answer "is there a control section to lay out", not "is the control enabled now":
 * availability and observations still come from the snapshot, and
 * read-only settings are readouts, not sections. A setting whose support is still unknown
 * projects to `false` (reserve no space until discovered); an observation whose support is
 * still unknown keeps the `base` value. Neither is a statement about telemetry.
 */
public data class MonitorLayoutCapabilities(
    public val gimbal: Boolean = false,
    public val zoom: Boolean = false,
    public val focus: Boolean = false,
    public val iris: Boolean = false,
    public val audio: Boolean = false,
    public val headTracking: Boolean = false,
    public val clipDelete: Boolean = false,
    public val clipStar: Boolean = false,
    public val requiresInternetHop: Boolean = false,
    public val timecode: Boolean = false,
) {
    /**
     * Derives [zoom], [focus] and [iris] from writable settings, and [timecode] and [audio] from
     * observation support (audio means live levels; clip audio metadata never turns it on).
     * [gimbal] and [headTracking] come from the motion overload; the other three fields have no
     * Core vocabulary yet. Everything not derived is copied from [base], which the integration or
     * app supplies.
     */
    public constructor(
        capabilities: CapabilitySnapshot,
        base: MonitorLayoutCapabilities = MonitorLayoutCapabilities(),
    ) : this(
        gimbal = base.gimbal,
        zoom = capabilities.writable(SettingKey.ZOOM),
        focus = capabilities.writable(SettingKey.FOCUS_MODE) || capabilities.writable(SettingKey.FOCUS_POINT),
        iris = capabilities.writable(SettingKey.APERTURE),
        audio = capabilities.audioLevels.shown(base.audio),
        headTracking = base.headTracking,
        clipDelete = base.clipDelete,
        clipStar = base.clipStar,
        requiresInternetHop = base.requiresInternetHop,
        timecode = capabilities.timecode.shown(base.timecode),
    )
}

/** Supported shows, unsupported hides, unknown keeps [base]. */
internal fun SupportStatus.shown(base: Boolean): Boolean = when (this) {
    SupportStatus.SUPPORTED -> true
    SupportStatus.UNSUPPORTED -> false
    SupportStatus.UNKNOWN -> base
}

private fun CapabilitySnapshot.writable(key: SettingKey): Boolean = this[key]?.access == SettingAccess.READ_WRITE
