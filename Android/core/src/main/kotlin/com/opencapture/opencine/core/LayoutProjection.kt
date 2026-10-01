package com.opencapture.opencine.core

/**
 * A compact layout projection for shared UI, kept apart from the domain model.
 *
 * The ten fields mirror the UI's existing `MonitorCapabilities` one to one, so the UI can keep
 * its type and map this value into it. They answer "is there a control section to lay out", not
 * "is the control enabled now": availability and observations still come from the snapshot, and
 * read-only settings are readouts, not sections. Support that is still unknown projects to
 * `false` here; that is a layout choice (reserve no space until discovered) and never a
 * statement about telemetry.
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
     * Derives [zoom], [focus] and [iris] from writable settings. The other seven fields have no
     * Core vocabulary yet and are copied from [base], which the integration or app supplies.
     */
    public constructor(
        capabilities: CapabilitySnapshot,
        base: MonitorLayoutCapabilities = MonitorLayoutCapabilities(),
    ) : this(
        gimbal = base.gimbal,
        zoom = capabilities.writable(SettingKey.ZOOM),
        focus = capabilities.writable(SettingKey.FOCUS_MODE) || capabilities.writable(SettingKey.FOCUS_POINT),
        iris = capabilities.writable(SettingKey.APERTURE),
        audio = base.audio,
        headTracking = base.headTracking,
        clipDelete = base.clipDelete,
        clipStar = base.clipStar,
        requiresInternetHop = base.requiresInternetHop,
        timecode = base.timecode,
    )
}

private fun CapabilitySnapshot.writable(key: SettingKey): Boolean = this[key]?.access == SettingAccess.READ_WRITE
