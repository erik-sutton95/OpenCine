package com.opencapture.opencine.dji

/**
 * After `07/48 00` a camera Wi-Fi connect polls `07/39` until the camera's access point is up.
 * `00 00` is access point and `00 01` station. Newer Pocket 4 / 4 Pro firmware reports `00 08`
 * while its access point is up and never `00 00`, so an unrecognized two-byte `00 xx` role that
 * reads the same twice in a row also ends the poll. Swift twin:
 * `MulticamStationPolicy.accessPointRestored(previous:current:)`.
 */
internal object AccessPointRestore {
    const val MAX_POLLS = 15

    fun settled(previous: ByteArray?, current: ByteArray?): Boolean {
        if (current == null) return false
        if (current.size == 2 && current[0].toInt() == 0 && current[1].toInt() == 0) return true
        val unrecognized = current.size == 2 && current[0].toInt() == 0 && (current[1].toInt() and 0xFF) > 1
        return unrecognized && previous?.contentEquals(current) == true
    }

    /** Reads up to [MAX_POLLS] roles with a [pause] after each unsettled one; returns the polls. */
    suspend fun await(read: suspend () -> ByteArray?, pause: suspend () -> Unit): Int {
        var previous: ByteArray? = null
        for (poll in 1..MAX_POLLS) {
            val role = read()
            if (settled(previous, role)) return poll
            previous = role
            pause()
        }
        return MAX_POLLS
    }
}
