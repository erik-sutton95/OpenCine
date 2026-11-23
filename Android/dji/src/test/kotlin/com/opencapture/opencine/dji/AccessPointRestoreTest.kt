package com.opencapture.opencine.dji

import kotlinx.coroutines.runBlocking
import kotlin.test.Test
import kotlin.test.assertEquals

/** Twin of the Swift `restoreStopsPollingOnceTheRoleIsStableAndNotStation` role sequences. */
class AccessPointRestoreTest {
    private fun role(vararg bytes: Int) = ByteArray(bytes.size) { bytes[it].toByte() }

    /** Polls and pauses for a `07/39` readback sequence whose last role repeats. */
    private fun restore(vararg roles: ByteArray?): Pair<Int, Int> = runBlocking {
        val queue = roles.toMutableList()
        var pauses = 0
        val polls = AccessPointRestore.await(
            read = { if (queue.size > 1) queue.removeAt(0) else queue[0] },
            pause = { pauses += 1 },
        )
        polls to pauses
    }

    @Test fun newerFirmwareAccessPointRoleEndsThePollOnceStable() {
        // Pocket 4 / 4 Pro firmware reports 00 08 while its access point is up, never 00 00.
        assertEquals(2 to 1, restore(role(0, 8)))
        assertEquals(3 to 2, restore(role(0, 1), role(0, 8)))
        assertEquals(3 to 2, restore(role(0, 8), role(0, 9)))
    }

    @Test fun accessPointRoleEndsThePollAtOnce() {
        assertEquals(1 to 0, restore(role(0, 0)))
        assertEquals(2 to 1, restore(role(0, 8), role(0, 0)))
    }

    @Test fun stationOrNoReplyKeepsPollingToTheLimit() {
        assertEquals(15 to 15, restore(role(0, 1)))
        assertEquals(15 to 15, restore(null))
        assertEquals(15 to 15, restore(role(0xe0)))
    }
}
