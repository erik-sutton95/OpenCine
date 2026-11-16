package com.opencapture.opencine.platform

import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/** One network shared by several camera connections: only the last release lets it go. */
class PathHoldersTest {
    private val first = Any()
    private val second = Any()

    @Test fun oneCamerasReleaseKeepsTheNetworkAnotherStillHolds() {
        val holders = PathHolders()
        holders.hold(first)
        holders.hold(second)
        assertFalse(holders.release(first), "the second camera still uses the network")
        assertTrue(holders.release(second), "the last release lets the network go")
    }

    @Test fun aReleaseByAConnectionThatNeverHeldThePathKeepsTheHolders() {
        val holders = PathHolders()
        holders.hold(first)
        assertFalse(holders.release(second))
        assertTrue(holders.release(first))
    }

    @Test fun holdingTwiceIsOneHold() {
        val holders = PathHolders()
        holders.hold(first)
        holders.hold(first)
        assertTrue(holders.release(first))
    }

    @Test fun aSingleUserPathIsLetGoAtOnce() {
        val holders = PathHolders()
        assertTrue(holders.release(first), "nobody holds the path: releasing lets it go, as before owners")
    }
}
