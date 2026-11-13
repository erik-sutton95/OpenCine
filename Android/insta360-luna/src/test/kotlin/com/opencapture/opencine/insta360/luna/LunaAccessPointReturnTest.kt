package com.opencapture.opencine.insta360.luna

import kotlinx.coroutines.CancellationException
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
    /** A scripted camera behind the Bluetooth link: what each step does, and what it was sent. */
    private class Camera {
        var link: (suspend () -> Unit) = {}
        var authorize: (suspend () -> Unit) = {}
        var switchMode: (suspend () -> Unit) = {}
        var reply = credentials("DK")
        val sent = mutableListOf<Pair<Int, List<Byte>>>()
        var closes = 0

        fun restore() = LunaAccessPointRestore(
            link = { link() },
            authorize = { authorize(); reply },
            send = { code, body -> sent += code to body.toList(); switchMode() },
            close = { closes += 1 },
        )

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

    /** A timeout raised inside a step, as `withTimeout` in the link's request raises it. */
    private suspend fun timeout(): Nothing { withTimeout(1) { delay(10) }; error("unreachable") }

    @Test fun theCameraIsAskedBackOntoItsAccessPointAndNothingElse() = runTest {
        val camera = Camera()
        assertEquals(LunaAccessPointReturn.Returned, camera.restore().run())
        assertEquals(listOf(accessPoint("DK")), camera.sent, "never a capture, record or live command")
        assertEquals(1, camera.closes)
    }

    @Test fun aCameraWithoutARegionIsAskedWithoutOne() = runTest {
        val camera = Camera().apply { reply = Camera.credentials(null) }
        assertEquals(LunaAccessPointReturn.Returned, camera.restore().run())
        assertEquals(listOf(accessPoint(null)), camera.sent)
    }

    @Test fun aCameraBluetoothCannotReachIsDeferred() = runTest {
        val camera = Camera().apply { link = { throw IllegalStateException("Camera Bluetooth disconnected (133)") } }
        val result = camera.restore().run()
        assertEquals("com.opencapture.insta360.luna.return.not-reachable", result.failure?.code)
        assertTrue(result.isRetryable)
        assertTrue(camera.sent.isEmpty() && camera.closes == 1)
    }

    @Test fun aCameraStillSwitchingItsWiFiIsDeferred() = runTest {
        val authorizing = Camera().apply { authorize = { throw LunaWiFiBusy(8) } }
        val switching = Camera().apply { switchMode = { throw LunaWiFiBusy(LunaStationWire.SET_WIFI_MODE) } }
        for (camera in listOf(authorizing, switching)) {
            val result = camera.restore().run()
            assertEquals("com.opencapture.insta360.luna.return.camera-busy", result.failure?.code)
            assertTrue(result.isRetryable)
            assertEquals(1, camera.closes)
        }
    }

    @Test fun aCameraThatDoesNotAnswerIsDeferred() = runTest {
        val authorizing = Camera().apply { authorize = { timeout() } }
        val switching = Camera().apply { switchMode = { timeout() } }
        for (camera in listOf(authorizing, switching)) {
            val result = camera.restore().run()
            assertEquals("com.opencapture.insta360.luna.return.no-answer", result.failure?.code)
            assertTrue(result.isRetryable)
        }
    }

    @Test fun aCameraThatDoesNotAuthorizeThisPhoneFails() = runTest {
        val camera = Camera().apply { authorize = { throw LunaNotApproved("Camera did not approve this client") } }
        val result = camera.restore().run()
        assertEquals("com.opencapture.insta360.luna.return.not-authorized", result.failure?.code)
        assertFalse(result.isRetryable)
        assertTrue(camera.sent.isEmpty(), "nothing is asked of a camera that did not authorize this phone")
        assertEquals(1, camera.closes)
    }

    @Test fun aCameraThatRefusesTheSwitchFails() = runTest {
        val camera = Camera().apply { switchMode = { throw LunaRefused(LunaStationWire.SET_WIFI_MODE) } }
        val result = camera.restore().run()
        assertEquals("com.opencapture.insta360.luna.return.refused", result.failure?.code)
        assertFalse(result.isRetryable)
    }

    @Test fun cancellationIsNeverAResult() = runTest {
        val camera = Camera().apply { authorize = { throw CancellationException("connect replaced") } }
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
