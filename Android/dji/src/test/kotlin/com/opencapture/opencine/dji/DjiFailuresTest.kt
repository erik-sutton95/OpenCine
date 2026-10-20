package com.opencapture.opencine.dji

import com.opencapture.opencine.vocabulary.ConnectionPhase
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * The pair page's failure copy: the session's raw reason is technical text, never operator copy.
 * The baseline `StartupConnectionCopy.friendly` said what the operator can do (PAB-C-23).
 */
class DjiFailuresTest {
    private val pairingTimedOut = "pairing timed out \u2014 tap Approve on the camera if it asked"

    /** A real timeout, because the constructor is internal to kotlinx-coroutines. */
    private fun timeoutError(): TimeoutCancellationException = runBlocking {
        assertFailsWith<TimeoutCancellationException> { withTimeout(1) { delay(5_000) } }
    }

    @Test
    fun `a pairing timeout gets the time copy and the DJI apps tip`() {
        val failure =
            DjiFailures.classify(
                timeoutError(),
                ConnectionPhase.AWAITING_APPROVAL,
                pairingTimedOut,
            )
        assertTrue(
            failure.message.startsWith("The camera didn't respond in time. Check Bluetooth and try again."),
            failure.message,
        )
        assertTrue(failure.message.endsWith(DjiFailures.DJI_APPS_TIP), failure.message)
    }

    @Test
    fun `a silent datalink gets the video-link copy`() {
        val failure =
            DjiFailures.classify(
                DatalinkHandshakeException("camera never answered the datalink handshake"),
                ConnectionPhase.OPENING_DATALINK,
                "camera never answered the datalink handshake",
            )
        assertEquals("The camera never answered the video link. ${DjiFailures.DJI_APPS_TIP}", failure.message)
    }

    @Test
    fun `a dropped connection gets the ended copy`() {
        val failure =
            DjiFailures.classify(
                IllegalStateException("the camera disconnected"),
                ConnectionPhase.JOINING_WIFI,
                "the camera disconnected",
            )
        assertEquals("The camera ended the connection. Try again.", failure.message)
    }

    @Test
    fun `a reason with no friendly sentence keeps its own words`() {
        val failure =
            DjiFailures.classify(
                StationJoin.Failure.JoinRejected(),
                ConnectionPhase.JOINING_WIFI,
                "The camera could not join the Wi-Fi.",
            )
        assertEquals("The camera could not join the Wi-Fi.", failure.message)
    }

    @Test
    fun `no failure copy carries an em dash`() {
        val reasons =
            listOf(
                DjiFailures.classify(timeoutError(), ConnectionPhase.AWAITING_APPROVAL, pairingTimedOut),
                DjiFailures.classify(DatalinkHandshakeException("camera never answered the datalink handshake"), ConnectionPhase.OPENING_DATALINK, "camera never answered the datalink handshake"),
                DjiFailures.classify(IllegalStateException("the camera disconnected"), ConnectionPhase.JOINING_WIFI, "the camera disconnected"),
            )
        for (reason in reasons) assertFalse(reason.message.contains('\u2014'), reason.message)
    }
}
