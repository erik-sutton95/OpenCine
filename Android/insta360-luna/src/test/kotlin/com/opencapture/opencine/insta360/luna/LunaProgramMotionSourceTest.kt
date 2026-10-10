package com.opencapture.opencine.insta360.luna

import com.opencapture.opencine.core.SessionCloseReason
import com.opencapture.opencine.insta360.shell.ConnectionPhase
import com.opencapture.opencine.motion.GimbalWaypoint
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.async
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlin.coroutines.Continuation
import kotlin.coroutines.resume
import kotlin.coroutines.suspendCoroutine
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** Captured take commands use the real LunaCameraSession admission and deployed wire builders. */
@OptIn(ExperimentalCoroutinesApi::class)
class LunaProgramMotionSourceTest {
    @Test fun boundFactoryNeedsReadyOwnedSession() = runTest {
        val session = LunaCameraSession(send = { ByteArray(0) }, functionMode = { LunaControl.FUNCTION_MODE_VIDEO },
            readSettings = {}, readCapture = {}, scope = backgroundScope)
        assertNull(LunaMotionService.boundTo(session, backgroundScope))
        session.linkChanged(ConnectionPhase.LIVE)
        assertNotNull(LunaMotionService.boundTo(session, backgroundScope))
        session.closeNow(SessionCloseReason.REPLACED)
        assertNull(LunaMotionService.boundTo(session, backgroundScope))
    }

    @Test fun capturedCommandsKeepOriginalBytesClampWrapAndMovingStamp() = runTest {
        val sent = mutableListOf<LunaControl.Request>(); var commanding = 0
        val session = LunaCameraSession(send = { sent += it; ByteArray(0) }, functionMode = { LunaControl.FUNCTION_MODE_VIDEO },
            readSettings = {}, readCapture = {}, scope = backgroundScope, noteGimbalCommand = { commanding += 1 })
        session.linkChanged(ConnectionPhase.LIVE)
        val motion = assertNotNull(LunaMotionService.boundTo(session, backgroundScope))
        assertTrue(motion.aim(GimbalWaypoint(190.0, 110.0, 1.0)))
        val expected = LunaControl.gimbalSetAngle(90f, -170f)
        assertEquals(expected.code, sent.single().code)
        assertTrue(expected.body.contentEquals(sent.single().body)); assertEquals(1, commanding)
        assertTrue(motion.recenter()); assertTrue(motion.flip()); assertTrue(motion.release())
        val expectedRest = listOf(LunaControl.gimbal(2), LunaControl.gimbal(3), LunaControl.gimbalStick(0.0, 0.0))
        assertTrue(sent.drop(1).zip(expectedRest).all { (actual, expectedRequest) ->
            actual.code == expectedRequest.code && actual.body.contentEquals(expectedRequest.body) })
        assertEquals(1, commanding, "Original recenter/flip/rest do not mark commanded head-pitch suppression")
        assertTrue(motion.stick(0.25, -1.0)); runCurrent(); motion.endHold()
        assertEquals(2, commanding)
        assertTrue(sent.last().body.contentEquals(LunaControl.gimbalStick(0.25, -1.0).body))
    }

    @Test fun sameSessionReentryRetiresCapturedEpochBeforeNextCommand() = runTest {
        val sent = mutableListOf<LunaControl.Request>()
        val session = LunaCameraSession(send = { sent += it; ByteArray(0) }, functionMode = { LunaControl.FUNCTION_MODE_VIDEO },
            readSettings = {}, readCapture = {}, scope = backgroundScope)
        session.linkChanged(ConnectionPhase.LIVE)
        val old = assertNotNull(LunaMotionService.boundTo(session, backgroundScope))
        session.linkChanged(ConnectionPhase.FAILED); session.linkChanged(ConnectionPhase.LIVE)
        assertFalse(old.aim(GimbalWaypoint(10.0, 5.0, 1.0))); assertTrue(sent.isEmpty())
        val next = assertNotNull(LunaMotionService.boundTo(session, backgroundScope))
        assertTrue(next.aim(GimbalWaypoint(10.0, 5.0, 1.0))); assertEquals(1, sent.size)
    }

    @Test fun commandStampCallbackCannotAuthorizeANewEpoch() = runTest {
        val sent = mutableListOf<LunaControl.Request>(); lateinit var session: LunaCameraSession
        session = LunaCameraSession(send = { sent += it; ByteArray(0) }, functionMode = { LunaControl.FUNCTION_MODE_VIDEO },
            readSettings = {}, readCapture = {}, scope = backgroundScope,
            noteGimbalCommand = { session.linkChanged(ConnectionPhase.LIVE) })
        session.linkChanged(ConnectionPhase.LIVE)
        val motion = assertNotNull(LunaMotionService.boundTo(session, backgroundScope))
        assertFalse(motion.aim(GimbalWaypoint(10.0, 5.0, 1.0)))
        assertTrue(sent.isEmpty(), "Epoch recheck after the moving callback precedes wire dispatch")
    }

    @Test fun lateReplyCannotPublishAcceptanceAfterReentry() = runTest {
        val sent = mutableListOf<LunaControl.Request>(); var continuation: Continuation<ByteArray>? = null
        val session = LunaCameraSession(send = {
            sent += it
            if (sent.size == 1) suspendCoroutine { continuation = it } else ByteArray(0)
        }, functionMode = { LunaControl.FUNCTION_MODE_VIDEO }, readSettings = {}, readCapture = {}, scope = backgroundScope)
        session.linkChanged(ConnectionPhase.LIVE)
        val old = assertNotNull(LunaMotionService.boundTo(session, backgroundScope))
        val pending = async { old.aim(GimbalWaypoint(10.0, 5.0, 1.0)) }; runCurrent()
        assertNotNull(continuation)
        session.linkChanged(ConnectionPhase.FAILED); session.linkChanged(ConnectionPhase.LIVE)
        val next = assertNotNull(LunaMotionService.boundTo(session, backgroundScope))
        assertTrue(next.aim(GimbalWaypoint(20.0, 5.0, 1.0)))
        continuation!!.resume(ByteArray(0)); runCurrent()
        assertFalse(pending.await(), "Reply publication rechecks the original epoch")
        assertEquals(2, sent.size)
    }

    @Test fun replacedSessionCannotLookUpTheSuccessor() = runTest {
        val oldSent = mutableListOf<LunaControl.Request>(); val nextSent = mutableListOf<LunaControl.Request>()
        val old = LunaCameraSession(send = { oldSent += it; ByteArray(0) }, functionMode = { LunaControl.FUNCTION_MODE_VIDEO },
            readSettings = {}, readCapture = {}, scope = backgroundScope)
        val next = LunaCameraSession(send = { nextSent += it; ByteArray(0) }, functionMode = { LunaControl.FUNCTION_MODE_VIDEO },
            readSettings = {}, readCapture = {}, scope = backgroundScope)
        old.linkChanged(ConnectionPhase.LIVE); next.linkChanged(ConnectionPhase.LIVE)
        val captured = assertNotNull(LunaMotionService.boundTo(old, backgroundScope))
        old.closeNow(SessionCloseReason.REPLACED)
        assertFalse(captured.aim(GimbalWaypoint(10.0, 5.0, 1.0)))
        assertTrue(oldSent.isEmpty() && nextSent.isEmpty())
        assertTrue(assertNotNull(LunaMotionService.boundTo(next, backgroundScope)).aim(GimbalWaypoint(10.0, 5.0, 1.0)))
        assertTrue(oldSent.isEmpty()); assertEquals(1, nextSent.size)
    }
}
