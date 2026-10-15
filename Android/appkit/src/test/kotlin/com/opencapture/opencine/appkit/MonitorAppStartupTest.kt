package com.opencapture.opencine.appkit

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/** SIMULATED coroutine time over the same launch function the real Compose root consumes. */
@OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
class MonitorAppStartupTest {
    @Test
    fun launchWaits2250MillisecondsAndKeepsThe350MillisecondFade() = runTest {
        var dismissed = false
        launch { awaitMonitorLaunch(); dismissed = true }
        runCurrent()
        advanceTimeBy(2_249)
        runCurrent()
        assertFalse(dismissed)
        advanceTimeBy(1)
        runCurrent()
        assertTrue(dismissed)
        assertEquals(350, MonitorLaunchTiming.FADE_MILLIS)
    }

    @Test
    fun cancelledLaunchRejectsAnUncooperativeLateSleeper() = runTest {
        val entered = CompletableDeferred<Unit>()
        val release = CompletableDeferred<Unit>()
        var dismissed = false
        val task = launch {
            awaitMonitorLaunch { millis ->
                assertEquals(2_250L, millis)
                entered.complete(Unit)
                // An external callback can return normally after its source was cancelled.
                kotlinx.coroutines.withContext(kotlinx.coroutines.NonCancellable) { release.await() }
            }
            dismissed = true
        }
        entered.await()
        task.cancel()
        release.complete(Unit)
        task.join()
        assertFalse(dismissed)
    }

    @Test
    fun consentRequiresAvailableReportingAndAnAbsentDecision() {
        assertTrue(MonitorStartupConsentAdmission.allows(available = true, hasDecision = false))
        assertFalse(MonitorStartupConsentAdmission.allows(available = false, hasDecision = false))
        assertFalse(MonitorStartupConsentAdmission.allows(available = true, hasDecision = true))
        assertFalse(MonitorStartupConsentAdmission.allows(available = false, hasDecision = true))
    }
}
