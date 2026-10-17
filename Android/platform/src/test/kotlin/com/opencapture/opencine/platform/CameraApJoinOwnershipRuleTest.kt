package com.opencapture.opencine.platform

import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * One camera access-point join and one Wi-Fi low-latency lock for every integration (A4-22): a fix
 * to the join (timeouts, scan permission, reassociation) lands once. Joining the operator's own
 * Wi-Fi for the DJI station setups is a different network and stays DJI's.
 */
class CameraApJoinOwnershipRuleTest {
    private val androidRoot = File("..").canonicalFile
    private val owners = setOf("platform/src/main/kotlin/com/opencapture/opencine/platform/CameraApJoiner.kt")
    private val stationJoin = "dji/src/main/kotlin/com/opencapture/opencine/dji/MultiviewNetwork.kt"

    private fun sourcesUsing(token: String): Set<String> =
        androidRoot.walk()
            .filter { it.isFile && it.extension == "kt" && "/src/main/" in it.path && "/build/" !in it.path }
            .filter { token in it.readText() }
            .map { it.relativeTo(androidRoot).path }
            .toSet()

    @Test
    fun onlyThePlatformJoinerAsksAndroidForTheCameraNetwork() {
        assertEquals(owners + stationJoin, sourcesUsing("WifiNetworkSpecifier.Builder"))
        assertEquals(owners, sourcesUsing("CameraApAvailabilityTracker<"))
    }

    @Test
    fun onlyThePlatformHoldsTheLowLatencyLock() {
        assertEquals(setOf("platform/src/main/kotlin/com/opencapture/opencine/platform/WifiLowLatencyLock.kt"), sourcesUsing("createWifiLock("))
    }

    @Test
    fun everyWirelessIntegrationHoldsTheLockWhileLive() {
        for (integration in listOf("dji", "insta360-luna")) {
            val users = sourcesUsing("WifiLowLatencyLock(").filter { it.startsWith("$integration/") }
            assertTrue(users.isNotEmpty(), "$integration takes no Wi-Fi low-latency lock")
        }
    }
}
