package com.opencapture.opencine.core

/** One saved way to reach a camera (a "setup"). Dates are epoch milliseconds. */
public data class SavedRoute(
    /** Minted once and kept in the saved document. */
    public val id: ConnectionRouteID = ConnectionRouteID(),
    /** Codec-stable identity within the camera, for example `ap`, `wifi`, `hotspot`. */
    public val key: String,
    public val kind: RouteKind,
    /** The operator's setup name; `null` uses the shell's title for the kind. */
    public val title: String? = null,
    /** Network name (SSID) or interface name. Never a secret. */
    public val network: String? = null,
    /** Needs Bluetooth commissioning before the route comes up. */
    public val bluetooth: Boolean = false,
    public val lastConnected: Long? = null,
    /** Integration-owned values, kept verbatim. */
    public val extras: Map<String, String> = emptyMap(),
)

/** One saved camera with its routes. */
public data class SavedCamera(
    /**
     * Stable local key. A migrated camera keeps its legacy record id verbatim, so credentials,
     * media and calibration keyed by it keep working.
     */
    public val id: String,
    public val integration: IntegrationID,
    /** Durable identity when known (a serial); never derived from a host or a name. */
    public val device: CameraDeviceID? = null,
    /** The operator's rename. */
    public val name: String? = null,
    public val advertisedName: String,
    public val model: String,
    /** In chip order. */
    public val routes: List<SavedRoute> = emptyList(),
    public val preferredRoute: ConnectionRouteID? = null,
    public val lastConnected: Long? = null,
    /** Integration-owned values, kept verbatim. */
    public val extras: Map<String, String> = emptyMap(),
) {
    /** The rename, else the advertised name. */
    public val displayName: String get() = name ?: advertisedName
}
