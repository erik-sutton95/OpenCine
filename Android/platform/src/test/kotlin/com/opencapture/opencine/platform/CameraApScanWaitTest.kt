@file:OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)

package com.opencapture.opencine.platform

import kotlinx.coroutines.test.currentTime
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/** The pre-join scan wait every product's camera-AP join runs (A4-22). */
class CameraApScanWaitTest {
    /**
     * The wizard asks only for NEARBY_WIFI_DEVICES on API 33+, so scan results are often
     * unreadable. The system panel still lists networks from its own scan: kick it once (and once
     * more when the panel must see the access point), then join without polling (ZAB-150).
     */
    @Test
    fun withoutScanPermissionTheJoinStillKicksTheScanOnceWithoutWaiting() = runTest {
        var kicks = 0
        val seen = awaitScanVisibility(
            canReadScans = false, maxWaitMillis = 12_000, requireVisible = false,
            kick = { kicks++ }, visible = { false },
        )
        assertFalse(seen)
        assertEquals(0L, currentTime, "an unreadable scan can never show the camera; waiting only delays the join")
        assertEquals(1, kicks)
    }

    @Test
    fun withoutScanPermissionThePanelGetsItsFinalKickToo() = runTest {
        var kicks = 0
        assertFalse(
            awaitScanVisibility(
                canReadScans = false, maxWaitMillis = 12_000, requireVisible = true,
                kick = { kicks++ }, visible = { false },
            ),
        )
        assertEquals(0L, currentTime)
        assertEquals(2, kicks)
    }

    @Test
    fun aVisibleCameraEndsTheWaitAtOnce() = runTest {
        assertTrue(awaitScanVisibility(true, 12_000, false, kick = {}, visible = { true }))
        assertEquals(0L, currentTime)
    }

    @Test
    fun anUnseenCameraWaitsTheBudgetRescanningAndKicksOnceMoreWhenRequired() = runTest {
        var kicks = 0
        assertFalse(awaitScanVisibility(true, 3_000, requireVisible = true, kick = { kicks++ }, visible = { false }))
        assertTrue(currentTime in 3_000L..3_350L, "waited $currentTime ms")
        // First kick, one rescan every 1.5 s of polling, and the last kick for the system panel.
        assertEquals(1 + 1 + 1, kicks)
    }

    @Test
    fun theCameraAppearingMidWaitEndsIt() = runTest {
        var polls = 0
        assertTrue(awaitScanVisibility(true, 12_000, false, kick = {}, visible = { ++polls >= 4 }))
        assertEquals(3 * 350L, currentTime)
    }
}
