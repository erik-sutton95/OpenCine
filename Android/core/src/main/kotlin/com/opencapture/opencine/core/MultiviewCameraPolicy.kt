package com.opencapture.opencine.core

/**
 * What a Multiview stage may do with one integration's cameras: whether a camera may join a stage,
 * whether the stage shows its picture, and whether the coordinator may find a member by probing
 * hosts. Every integration supplies one, with or without a [StationCommissioner], so an
 * integration whose cameras join a network only from their own menus still answers. Swift twin:
 * `MultiviewCameraPolicy`.
 */
public class MultiviewCameraPolicy<Camera>(
    /**
     * Whether the coordinator may find a member's address by probing hosts on the shared network
     * ([MultiviewMemberLink.probe]). False for cameras that must never be dialled unasked: the
     * integration then finds members from its own sightings.
     */
    public val discoversByProbe: Boolean = true,
    hostKey: ((address: String) -> String)? = null,
    qualification: (camera: Camera, experimental: Boolean) -> MulticamQualification,
    hasPreview: (camera: Camera) -> Boolean,
) {
    private val qualify = qualification
    private val preview = hasPreview
    private val key = hostKey

    /** Whether this camera, in this configuration, may join a stage. */
    public fun qualification(camera: Camera, experimental: Boolean): MulticamQualification = qualify(camera, experimental)

    /** Whether a stage shows this camera's picture; without it only the network join is checked. */
    public fun hasPreview(camera: Camera): Boolean = preview(camera)

    /**
     * The form two addresses of this integration's cameras compare in (an integration that
     * normalizes hosts supplies its rule); the address itself by default. The coordinator compares
     * reserved, excluded and controlled hosts by this key.
     */
    public fun hostKey(address: String): String = key?.invoke(address) ?: address

    /** Integrations add their own policy as an extension property on this companion. */
    public companion object
}
