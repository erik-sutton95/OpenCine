package com.opencapture.opencine.insta360.luna

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.delay
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.withTimeout
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertTrue
import kotlin.test.fail

/**
 * Returning a Luna to its own Wi-Fi when Multiview closes (Pocket's Exit): Bluetooth reaches and
 * authorizes the camera, one SET_WIFI_MODE 147 asks it back onto its access point, and the link
 * closes. The phone joins nothing and no recording is stopped. Swift mirror:
 * `LunaAccessPointReturnTests`, same method names.
 */
class LunaAccessPointReturnTest {
    /**
     * A camera behind the Bluetooth link: it answers the real authorization the backend runs
     * (identity, key exchange, approval, credential read) and records every request it receives.
     */
    private class Camera {
        var link: (suspend () -> Unit) = {}
        /** Each request of these codes is answered by throwing instead. */
        val fails = mutableMapOf<Int, suspend () -> Nothing>()
        var switchMode: (suspend () -> Unit) = {}
        /** The authorization check's answer: 0 authorized, 1 approval required. */
        var authorization = 0L
        /** The approval notification's result (0 approved), or null when the camera never sends one. */
        var approval: Long? = 0
        var region: String? = "DK"
        val sent = mutableListOf<Pair<Int, List<Byte>>>()
        var closes = 0
        private val key = LunaWire.keyPair()

        fun restore() = LunaAccessPointRestore(
            link = {
                link()
                LunaBluetoothAuthorization(
                    request = { code, body, _ -> answer(code, body) }, agreed = {},
                    approvals = {
                        val result = approval ?: awaitCancellation()
                        LunaWire.Message(8209, 1, LunaWire.integer(1, result) + LunaWire.integer(2, 0), false)
                    },
                )
            },
            authBody = byteArrayOf(1),
            close = { closes += 1 },
        )

        private suspend fun answer(code: Int, body: ByteArray): ByteArray {
            sent += code to body.toList()
            fails[code]?.invoke()
            return when (code) {
                8 -> if (body.contentEquals(LunaWire.options(36, 37, 43))) credentials(region) else LunaWire.blob(
                    2, LunaWire.blob(48, text("Insta360 Luna Ultra")) + LunaWire.blob(15, text("SN-LUNA")) + LunaWire.blob(30, text("1.1.15")),
                )
                240 -> LunaWire.integer(1, 3)
                241 -> LunaWire.integer(1, 1) + LunaWire.blob(2, LunaWire.publicBytes(key))
                39 -> LunaWire.integer(1, authorization)
                LunaStationWire.SET_WIFI_MODE -> { switchMode(); ByteArray(0) }
                else -> ByteArray(0)
            }
        }

        companion object {
            private fun text(value: String) = value.toByteArray()

            /** The credential read's reply: the camera's own Wi-Fi and, when given, its region. */
            fun credentials(region: String?): ByteArray {
                val wifi = LunaWire.blob(36, LunaWire.blob(1, text("LUNA-TEST")) + LunaWire.blob(2, text("synthetic-password")))
                val channels = region?.let { LunaWire.blob(37, LunaWire.blob(1, text(it))) } ?: ByteArray(0)
                return byteArrayOf(0x0a, 0x03, 0x24, 0x25, 0x2b) + LunaWire.blob(2, wifi + channels)
            }
        }
    }

    private fun accessPoint(region: String?) =
        LunaStationWire.SET_WIFI_MODE to LunaStationWire.wifiMode(LunaStationWire.Mode.ACCESS_POINT, region).toList()

    /** Commands that start or stop a recording, a photo or the live picture: a return sends none. */
    private val capture = setOf(1, 2, 3, 4, 5, 22, 23)

    /** A timeout raised inside a step, as `withTimeout` in the link's request raises it. */
    private suspend fun timeout(): Nothing { withTimeout(1) { delay(10) }; error("unreachable") }

    @Test fun theCameraIsAskedBackOntoItsAccessPointAndNothingElse() = runTest {
        val camera = Camera()
        assertEquals(LunaAccessPointReturn.Returned, camera.restore().run())
        assertTrue(camera.sent.none { it.first in capture }, "never a capture, record or live command")
        assertEquals(listOf(accessPoint("DK")), camera.sent.filter { it.first == LunaStationWire.SET_WIFI_MODE })
        assertEquals(LunaStationWire.SET_WIFI_MODE, camera.sent.last().first, "the switch is the last request")
        assertEquals(1, camera.closes)
    }

    @Test fun aCameraWithoutARegionIsAskedWithoutOne() = runTest {
        val camera = Camera().apply { region = null }
        assertEquals(LunaAccessPointReturn.Returned, camera.restore().run())
        assertEquals(accessPoint(null), camera.sent.last())
    }

    @Test fun aCameraBluetoothCannotReachIsDeferred() = runTest {
        val camera = Camera().apply { link = { throw IllegalStateException("Camera Bluetooth disconnected (133)") } }
        val result = camera.restore().run()
        assertEquals("com.opencapture.insta360.luna.return.not-reachable", result.failure?.code)
        assertTrue(result.isRetryable)
        assertTrue(camera.sent.isEmpty() && camera.closes == 1)
    }

    @Test fun aCameraStillSwitchingItsWiFiIsDeferred() = runTest {
        val authorizing = Camera().apply { fails[8] = { throw LunaWiFiBusy(8) } }
        val switching = Camera().apply { switchMode = { throw LunaWiFiBusy(LunaStationWire.SET_WIFI_MODE) } }
        for (camera in listOf(authorizing, switching)) {
            val result = camera.restore().run()
            assertEquals("com.opencapture.insta360.luna.return.camera-busy", result.failure?.code)
            assertTrue(result.isRetryable)
            assertEquals(1, camera.closes)
        }
    }

    @Test fun aCameraThatDoesNotAnswerIsDeferred() = runTest {
        val authorizing = Camera().apply { fails[241] = { timeout() } }
        val switching = Camera().apply { switchMode = { timeout() } }
        for (camera in listOf(authorizing, switching)) {
            val result = camera.restore().run()
            assertEquals("com.opencapture.insta360.luna.return.no-answer", result.failure?.code)
            assertTrue(result.isRetryable)
        }
    }

    @Test fun aCameraThatDoesNotAuthorizeThisPhoneFails() = runTest {
        val camera = Camera().apply { authorization = 1; approval = 1 }
        val result = camera.restore().run()
        assertEquals("com.opencapture.insta360.luna.return.not-authorized", result.failure?.code)
        assertFalse(result.isRetryable)
        assertTrue(camera.sent.none { it.first == LunaStationWire.SET_WIFI_MODE }, "nothing is asked of a camera that did not authorize this phone")
        assertEquals(1, camera.closes)
    }

    @Test fun aCameraThatRefusesTheSwitchFails() = runTest {
        val camera = Camera().apply { switchMode = { throw LunaRefused(LunaStationWire.SET_WIFI_MODE) } }
        val result = camera.restore().run()
        assertEquals("com.opencapture.insta360.luna.return.refused", result.failure?.code)
        assertFalse(result.isRetryable)
    }

    @Test fun cancellationIsNeverAResult() = runTest {
        val camera = Camera().apply { fails[240] = { throw CancellationException("connect replaced") } }
        assertFailsWith<CancellationException> { camera.restore().run() }
        assertEquals(1, camera.closes)
    }

    // The bounded retry (DJI `restoreCameraWiFiWithRetry`).

    private val busy = LunaAccessPointReturn.Deferred(LunaAccessPointReturn.cameraBusy)

    @Test fun aDeferredReturnIsRetriedAfterAWait() = runTest {
        var attempts = 0
        var waits = 0
        val result = LunaAccessPointReturn.retrying(waitBetween = { waits++ }) {
            attempts++
            if (attempts == 1) busy else LunaAccessPointReturn.Returned
        }
        assertTrue(result == LunaAccessPointReturn.Returned && attempts == 2 && waits == 1)
    }

    @Test fun repeatedDeferralStopsAtTheAttemptLimit() = runTest {
        var attempts = 0
        var waits = 0
        val result = LunaAccessPointReturn.retrying(waitBetween = { waits++ }) { attempts++; busy }
        assertEquals(busy, result)
        assertTrue(attempts == 3 && waits == 2, "no wait after the last attempt")
    }

    @Test fun aFailedReturnIsNotRetried() = runTest {
        val refused = LunaAccessPointReturn.Failed(LunaAccessPointReturn.refused)
        var attempts = 0
        val result = LunaAccessPointReturn.retrying(waitBetween = { fail("Unexpected retry") }) { attempts++; refused }
        assertTrue(result == refused && attempts == 1)
    }

    @Test fun cancellationDoesNotBecomeAReportedResult() = runTest {
        assertFailsWith<CancellationException> {
            LunaAccessPointReturn.retrying(waitBetween = {}) { throw CancellationException("closed") }
        }
    }
}
