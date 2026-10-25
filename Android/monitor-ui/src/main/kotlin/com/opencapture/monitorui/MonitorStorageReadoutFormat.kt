package com.opencapture.monitorui

import com.opencapture.opencine.media.StorageReadoutCycle

/** Live storage has two units; unknown readings do not become zero. */
object MonitorStorageReadoutFormat {
    fun capacity(gigabytes: Long?): String = gigabytes?.takeIf { it >= 0 }?.let { "$it GB" } ?: "\u2014"

    /** The live storage readout's free space ([StorageReadoutCycle.freeSpace]). */
    fun wholeUnitCapacity(bytes: Long?): String = StorageReadoutCycle.freeSpace(bytes)

    /** The forms one tap steps to after the free space ([StorageReadoutCycle.alternatives]). */
    fun alternatives(percent: String?, recordingTime: String?, photo: Boolean): List<String> =
        StorageReadoutCycle.alternatives(percent, recordingTime, photo)

    /**
     * The form a tap selects after [current], of [count] forms. With nothing to step to the
     * readout stays on the free space, so a later alternative starts from it.
     */
    fun nextForm(current: Int, count: Int): Int = if (count > 1) (current + 1) % count else 0

    fun remainingMinutes(minutes: Int?): String = minutes?.takeIf { it >= 0 }?.let { "$it Min" } ?: "\u2014 Min"
}
