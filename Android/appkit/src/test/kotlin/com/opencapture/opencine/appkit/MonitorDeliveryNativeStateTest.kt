@file:OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)

package com.opencapture.opencine.appkit

import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.async
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.withContext

/** SIMULATED projection of the existing run; no secondary flow or operation owner. */
class MonitorDeliveryNativeStateTest {
    @Test fun nativeStateCoversCapturedWaitUntilEnteredCleanupFinishes() = runTest {
        val gate = CompletableDeferred<Unit>()
        val owner = MonitorDeliveryPresentation<String>(backgroundScope, isCaching = { false }, isExternalDelivery = { false })
        try {
            val handle = assertNotNull(owner.beginNativeCaptured { _, _ ->
                withContext(NonCancellable) { gate.await() }; null
            })
            runCurrent()
            assertTrue(owner.nativeState.value.running)
            assertNull(owner.nativeState.value.progress)
            assertNull(owner.display.value.overlay)
            val joining = async { handle.cancelAndJoin() }
            runCurrent()
            assertFalse(joining.isCompleted)
            assertFalse(owner.nativeState.value.running)
            gate.complete(Unit); joining.await(); runCurrent()
            assertFalse(owner.nativeState.value.running)
            assertNull(owner.display.value.overlay)
            assertNull(owner.display.value.toast)
        } finally { gate.complete(Unit); owner.close() }
    }
}
