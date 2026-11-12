package com.opencapture.opencine.platform

import java.util.Collections
import java.util.IdentityHashMap

/**
 * Who holds a shared network path ([SharedWiFiPath]): several connections may use one network,
 * and the path is let go only when the last of them releases. Owners count by identity; holding
 * twice is one hold. Thread-safe.
 */
internal class PathHolders {
    private val owners: MutableSet<Any> = Collections.newSetFromMap(IdentityHashMap())

    @Synchronized fun hold(owner: Any) {
        owners += owner
    }

    /** Drops [owner]'s hold (none is fine). True when no owner holds the path any more. */
    @Synchronized fun release(owner: Any): Boolean {
        owners -= owner
        return owners.isEmpty()
    }

    @Synchronized fun clear() {
        owners.clear()
    }
}
