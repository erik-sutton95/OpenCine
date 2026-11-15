package com.opencapture.opencine.platform

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * A Multiview stage and its members on one shared Wi-Fi path: no member's join ever drops the
 * network the stage (or another member) holds, including when the phone cannot read its Wi-Fi
 * name (Location off, the Wi-Fi-name permission denied).
 */
class OwnedStationJoinTest {
    private class FakePort : StationRequestPort {
        var ssid: String? = null
        var address = false
        val requests = mutableListOf<String>()
        var letGoes = 0
        /** When set, the next request waits for it (true joins). */
        var pending: CompletableDeferred<Boolean>? = null
        var joins = true

        override fun currentSsid(): String? = ssid
        override fun hasAddress(): Boolean = address
        override suspend fun request(ssid: String, password: String): Boolean {
            requests += ssid
            val joined = pending?.await() ?: joins
            if (joined) address = true
            return joined
        }
        override fun letGo() {
            letGoes += 1
        }
    }

    private val stage = Any()
    private val member = Any()
    private val other = Any()

    @Test fun aMemberSharesTheStagesNetworkWhenThePhoneCannotReadItsName() = runTest {
        val port = FakePort()
        val joins = OwnedStationJoin(port, PathHolders())
        assertTrue(joins.join("Studio", "pw", stage))
        assertEquals(listOf("Studio"), port.requests)
        val letGoes = port.letGoes
        // Location off: the Wi-Fi name reads null.
        port.ssid = null
        assertTrue(joins.join("Studio", "pw", member))
        assertEquals(listOf("Studio"), port.requests, "no second system request")
        assertEquals(letGoes, port.letGoes, "the stage's request stays registered")
    }

    @Test fun aJoinForAnotherNetworkIsRefusedWhileTheStageHoldsOne() = runTest {
        val port = FakePort()
        val joins = OwnedStationJoin(port, PathHolders())
        assertTrue(joins.join("Studio", "pw", stage))
        val letGoes = port.letGoes
        assertFalse(joins.join("Elsewhere", "pw", member))
        assertEquals(listOf("Studio"), port.requests)
        assertEquals(letGoes, port.letGoes)
        assertEquals("Studio", joins.network)
    }

    @Test fun aMembersReleaseKeepsTheStagesNetworkAndTheLastLetsItGo() = runTest {
        val port = FakePort()
        val joins = OwnedStationJoin(port, PathHolders())
        joins.join("Studio", "pw", stage)
        joins.join("Studio", "pw", member)
        val letGoes = port.letGoes
        assertFalse(joins.release(member))
        assertEquals(letGoes, port.letGoes)
        assertTrue(joins.release(stage))
        assertEquals(letGoes + 1, port.letGoes)
    }

    @Test fun aFailedJoinWhileAnotherOwnerHoldsDropsNothing() = runTest {
        val port = FakePort()
        val joins = OwnedStationJoin(port, PathHolders())
        joins.join("Studio", "pw", stage)
        port.joins = false
        // The member shares, so it never asks the system and cannot fail the stage's network.
        assertTrue(joins.join("Studio", "pw", member))
        assertFalse(joins.release(member))
        assertEquals("Studio", joins.network)
    }

    @Test fun aSecondOwnerWaitsForTheFirstJoinAndSharesIt() = runTest {
        val port = FakePort()
        val joins = OwnedStationJoin(port, PathHolders())
        val gate = CompletableDeferred<Boolean>()
        port.pending = gate
        val first = async { joins.join("Studio", "pw", stage) }
        runCurrent()
        val second = async { joins.join("Studio", "pw", member) }
        runCurrent()
        gate.complete(true)
        assertTrue(first.await())
        assertTrue(second.await())
        assertEquals(listOf("Studio"), port.requests)
    }

    @Test fun aLoneOwnerMayMoveThePathToAnotherNetwork() = runTest {
        val port = FakePort()
        val joins = OwnedStationJoin(port, PathHolders())
        joins.join("Studio", "pw", member)
        port.ssid = "Studio"
        assertTrue(joins.join("Elsewhere", "pw", member))
        assertEquals(listOf("Studio", "Elsewhere"), port.requests)
        assertEquals("Elsewhere", joins.network)
    }

    @Test fun ownersOnTheCurrentWiFiWithoutANameShareIt() = runTest {
        val port = FakePort()
        val joins = OwnedStationJoin(port, PathHolders())
        port.address = true
        joins.hold(other)
        assertTrue(joins.join("Studio", "pw", member))
        assertTrue(port.requests.isEmpty())
        port.ssid = "Elsewhere"
        assertFalse(OwnedStationJoin(port, PathHolders().also { it.hold(other) }).join("Studio", "pw", member))
    }

    @Test fun aFreshJoinOnTheCurrentNetworkAsksTheSystemForNothing() = runTest {
        val port = FakePort()
        port.ssid = "Studio"
        port.address = true
        val joins = OwnedStationJoin(port, PathHolders())
        assertTrue(joins.join("Studio", "pw", stage))
        assertTrue(port.requests.isEmpty())
    }
}
