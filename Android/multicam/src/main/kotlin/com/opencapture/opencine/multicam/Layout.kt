package com.opencapture.opencine.multicam

import com.opencapture.opencine.core.CameraDeviceID
import com.opencapture.opencine.core.ConnectionRouteID
import com.opencapture.opencine.core.MonitorEntryID

/**
 * The persisted part of a group: slot order, names, the device and route each slot reconnects
 * through, and the staged slot. Live sessions, pictures and authority are never persisted. The
 * app encodes the value wherever it likes and recreates entries with the saved IDs. (No
 * serializer here, as in Core: the app maps it to its own storage format.)
 */
public data class MulticamLayout(
    public val slots: List<Slot>,
    public val stage: MonitorEntryID? = null,
    /** Bump on an incompatible change and migrate older values when decoding. */
    public val version: Int = 1,
) {
    public data class Slot(
        public val entry: MonitorEntryID,
        public val name: String,
        public val device: CameraDeviceID? = null,
        public val route: ConnectionRouteID? = null,
    )

    /** The layout of [group]. Routes come from the app, which knows how each entry connected. */
    public constructor(group: MulticamGroup, routes: Map<MonitorEntryID, ConnectionRouteID> = emptyMap()) : this(
        group.entries.map { Slot(it.id, it.name, it.device, routes[it.id]) },
        group.stage,
    )
}
