package com.opencapture.opencine.insta360.luna

import com.opencapture.opencine.core.ConnectionFailure
import com.opencapture.opencine.core.ConnectionPhase as CorePhase
import com.opencapture.opencine.core.RecoveryAction
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.delay
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.withTimeout
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertTrue

/**
 * LAN-first reconnect for a Wi-Fi or hotspot setup: a camera last reached on the network is opened at
 * its known address with the serial check, and moved over Bluetooth only when that fails. Swift
 * mirror: `LunaStationReconnectTests`, same method names; `aDropAfterTheCameraWentLiveEndsTheConnect`
 * is Android only (`reached`: here the control link runs for the whole session).
 */
class LunaStationReconnectTest {
    private val studio = LunaStationNetwork("Studio", "synthetic1", hotspot = false)
    private val known = LunaStationHost("Studio", hotspot = false, host = "192.168.1.31", serial = "LUNA-A")
    private val anotherCamera = LunaStationFailure(LunaFailures.failure(
        ConnectionFailure.Reason.WrongCamera, "wifi.serial-mismatch", "another camera", CorePhase.NEGOTIATING,
    ))

    /** What the connect did: the addresses opened directly, and how often the camera was moved. */
    private inner class Connect {
        var directFailure: (suspend () -> Unit)? = null
        var reached = false
        val opened = mutableListOf<LunaStationHost>()
        var moves = 0

        suspend fun run(known: LunaStationHost?, network: LunaStationNetwork = studio, inUse: Set<String> = emptySet()) =
            LunaStationReconnect.run(
                known, network, inUse, reached = { reached },
                direct = { host -> opened += host; directFailure?.invoke() },
                move = { moves += 1 },
            )
    }

    @Test fun aCameraAnsweringAtItsKnownAddressIsNeverMovedOverBluetooth() = runTest {
        val connect = Connect()
        assertEquals(LunaStationReconnect.Path.DIRECT, connect.run(known))
        assertTrue(connect.opened == listOf(known) && connect.moves == 0)
    }

    @Test fun aCameraWithoutAKnownAddressOnThisNetworkIsMoved() = runTest {
        val elsewhere = LunaStationHost("Office", hotspot = false, host = "192.168.1.31", serial = "LUNA-A")
        val otherKind = LunaStationHost("Studio", hotspot = true, host = "172.20.10.3", serial = "LUNA-A")
        val unproven = LunaStationHost("Studio", hotspot = false, host = "192.168.1.31", serial = "")
        for (host in listOf(null, elsewhere, otherKind, unproven)) {
            val connect = Connect()
            assertEquals(LunaStationReconnect.Path.BLUETOOTH, connect.run(host))
            assertTrue(connect.opened.isEmpty() && connect.moves == 1)
        }
    }

    @Test fun aKnownAddressAnotherConnectionHoldsIsNeverTried() = runTest {
        val connect = Connect()
        assertEquals(LunaStationReconnect.Path.BLUETOOTH, connect.run(known, inUse = setOf("192.168.1.31")))
        assertTrue(connect.opened.isEmpty() && connect.moves == 1)
    }

    @Test fun anotherCameraOrNoAnswerAtTheKnownAddressMovesTheCamera() = runTest {
        val failures: List<suspend () -> Unit> = listOf(
            { throw anotherCamera },
            { throw java.net.SocketTimeoutException("connect timed out") },
            // The control greeting's own timeout inside the open, not the connect being cancelled.
            { withTimeout(1) { delay(10) } },
        )
        for (failure in failures) {
            val connect = Connect().apply { directFailure = failure }
            assertEquals(LunaStationReconnect.Path.BLUETOOTH, connect.run(known))
            assertTrue(connect.opened == listOf(known) && connect.moves == 1)
        }
    }

    @Test fun localNetworkAccessOffIsSaidInsteadOfMovingTheCamera() = runTest {
        val denied = LunaStationFailure(LunaFailures.failure(
            ConnectionFailure.Reason.Permission(ConnectionFailure.Permission.LOCAL_NETWORK), "local-network.denied", "off",
            actions = listOf(RecoveryAction.OpenSettings, RecoveryAction.Retry),
        ))
        val connect = Connect().apply { directFailure = { throw denied } }
        assertFailsWith<LunaStationFailure> { connect.run(known) }
        assertEquals(0, connect.moves)
    }

    @Test fun cancellationIsNotAFallback() = runTest {
        val connect = Connect().apply { directFailure = { throw CancellationException("connect replaced") } }
        assertFailsWith<CancellationException> { connect.run(known) }
        assertEquals(0, connect.moves)
    }

    /** A phone that cannot join the setup's network would leave a moved camera stranded there. */
    @Test fun aPhoneThatCannotJoinTheNetworkDoesNotMoveTheCamera() = runTest {
        val notJoined = LunaStationFailure(LunaFailures.failure(
            ConnectionFailure.Reason.JoinFailed, "station.phone-join", "could not join", CorePhase.JOINING_NETWORK,
        ))
        val connect = Connect().apply { directFailure = { throw notJoined } }
        assertFailsWith<LunaStationFailure> { connect.run(known) }
        assertEquals(0, connect.moves)
    }

    @Test fun aDropAfterTheCameraWentLiveEndsTheConnect() = runTest {
        val connect = Connect().apply {
            reached = true
            directFailure = { throw IllegalStateException("Camera closed TCP") }
        }
        assertFailsWith<IllegalStateException> { connect.run(known) }
        assertEquals(0, connect.moves, "a live camera that dropped is not moved over Bluetooth")
    }
}
