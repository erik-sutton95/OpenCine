package com.opencapture.opencine.cameracontrols

import android.graphics.Bitmap
import android.graphics.Rect
import android.os.SystemClock
import android.view.InputDevice
import android.view.MotionEvent
import android.view.accessibility.AccessibilityNodeInfo
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.opencapture.opencine.appkit.MonitorControlModel
import com.opencapture.opencine.core.*
import com.opencapture.opencine.core.testing.*
import com.opencapture.opencine.vocabulary.CaptureLadder
import com.opencapture.opencine.vocabulary.LadderSheetPresentation
import com.opencapture.opencine.vocabulary.LadderTab
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import kotlin.time.Duration.Companion.seconds

/** SIMULATED twin: real native sheet/input, accepted control path and manual camera clock. */
class LadderSheetTestActivity : ComponentActivity()

@RunWith(AndroidJUnit4::class)
class LadderSheetInputTest {
    @Test fun unknownAndExplicitFirstTapReachBackendExactlyOnce() = withLadder(null) { fixture, scenario ->
        val drum = node("Choose value")
        scenario.onActivity {
            assertNull(fixture.control.state.value.snapshot!!.value(SettingKey.ISO).value)
            assertTrue(fixture.control.state.value.pending.isEmpty())
            assertEquals(0, fixture.hostCalls)
            assertTrue(fixture.camera.wire.isEmpty())
        }
        screenshot("SIMULATED-unknown")
        tap(drum)
        awaitState(scenario) { fixture.accepted == 1 }
        scenario.onActivity {
            assertEquals(1, fixture.hostCalls)
            assertNull(fixture.control.state.value.snapshot!!.value(SettingKey.ISO).value)
            assertEquals(iso(100), fixture.control.state.value.pending[SettingKey.ISO])
            assertTrue("Selection is deferred until the manual clock advances", fixture.camera.wire.isEmpty())
            fixture.flush.complete(Unit)
        }
        awaitState(scenario) { fixture.camera.wire.size == 1 }
        scenario.onActivity {
            assertEquals(listOf("set ${iso(100)}"), fixture.camera.wire)
            assertNull(fixture.control.state.value.snapshot!!.value(SettingKey.ISO).value)
            fixture.camera.advance(3.seconds)
        }
        awaitState(scenario) { fixture.control.state.value.pending.isEmpty() }
        scenario.onActivity { assertEquals(iso(100), fixture.control.state.value.snapshot!!.value(SettingKey.ISO).value) }
        tap(node("100"))
        scenario.onActivity {
            assertEquals(1, fixture.hostCalls)
            assertEquals(1, fixture.accepted)
            assertEquals(listOf("set ${iso(100)}"), fixture.camera.wire)
        }
        screenshot("SIMULATED-first-choice")
    }

    @Test fun knownCurrentAndRedundantTapRemainUnchanged() = withLadder(200) { fixture, scenario ->
        tap(node("200"))
        scenario.onActivity {
            fixture.flush.complete(Unit)
            assertEquals(iso(200), fixture.control.state.value.snapshot!!.value(SettingKey.ISO).value)
            assertTrue(fixture.control.state.value.pending.isEmpty())
            assertEquals(0, fixture.hostCalls)
            assertEquals(0, fixture.accepted)
            assertTrue(fixture.camera.wire.isEmpty())
        }
        screenshot("SIMULATED-known-current")
    }

    private fun withLadder(current: Int?, body: (Fixture, ActivityScenario<LadderSheetTestActivity>) -> Unit) {
        ActivityScenario.launch(LadderSheetTestActivity::class.java).use { scenario ->
            lateinit var fixture: Fixture
            scenario.onActivity { activity ->
                fixture = Fixture(current)
                val editor = requireNotNull(fixture.control.edit(SettingKey.ISO))
                activity.setContent {
                    LadderSheet(
                        presentation = LadderSheetPresentation(
                            "SIMULATED ISO", "", listOf(LadderTab("ISO", "iso",
                                CaptureLadder(current = current?.toString(), values = listOf("100", "200", "400"))))),
                        enabled = true, chromeless = true, onClose = {},
                        onWrite = { write ->
                            fixture.hostCalls += 1
                            if (write.key == "iso" && fixture.control.commit(iso(write.value.toInt()), editor, write.value)) {
                                fixture.accepted += 1
                            }
                        },
                    )
                }
            }
            try { body(fixture, scenario) }
            finally { scenario.onActivity { fixture.control.unbind(); fixture.scope.cancel() } }
        }
    }

    private class Fixture(current: Int?) {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
        val flush = CompletableDeferred<Unit>()
        val control = MonitorControlModel(scope, delay = { flush.await() })
        val camera: FakeCameraSession
        var hostCalls = 0
        var accepted = 0

        init {
            val mode = FakeMode(CaptureMode(CaptureMode.Role.PHOTO, "SIMULATED.photo", "SIMULATED"),
                listOf(SettingDescriptor(SettingKey.ISO, access = SettingAccess.READ_WRITE,
                    domain = SettingDomain(choices = listOf(iso(100), iso(200), iso(400))))), emptySet())
            camera = FakeCameraSession(
                FakeCameraBehavior(IntegrationID("SIMULATED"), 3.seconds, 5.seconds,
                    FakeCameraBehavior.RecordWire.EXPLICIT, modes = mapOf(1 to mode)),
                FakeDevice(1, current?.let { mapOf(SettingKey.ISO to iso(it)) } ?: emptyMap()))
            camera.cameraReportsStatus()
            control.bind(camera)
        }
    }

    private fun node(description: String): AccessibilityNodeInfo {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val deadline = SystemClock.uptimeMillis() + 10_000
        do {
            instrumentation.waitForIdleSync()
            val pending = ArrayDeque<AccessibilityNodeInfo>()
            instrumentation.uiAutomation.rootInActiveWindow?.let(pending::add)
            while (pending.isNotEmpty()) {
                val next = pending.removeFirst()
                if (next.contentDescription?.toString() == description) return next
                for (index in 0 until next.childCount) next.getChild(index)?.let(pending::add)
            }
            Thread.yield()
        } while (SystemClock.uptimeMillis() < deadline)
        throw AssertionError("Missing native drum: $description")
    }

    private fun tap(node: AccessibilityNodeInfo) {
        val rect = Rect().also(node::getBoundsInScreen)
        val automation = InstrumentationRegistry.getInstrumentation().uiAutomation
        val down = SystemClock.uptimeMillis()
        for (action in listOf(MotionEvent.ACTION_DOWN, MotionEvent.ACTION_UP)) {
            val event = MotionEvent.obtain(down, SystemClock.uptimeMillis(), action,
                rect.exactCenterX(), rect.exactCenterY(), 0)
            event.source = InputDevice.SOURCE_TOUCHSCREEN
            try { assertTrue(automation.injectInputEvent(event, true)) }
            finally { event.recycle() }
        }
        InstrumentationRegistry.getInstrumentation().waitForIdleSync()
    }

    private fun awaitState(scenario: ActivityScenario<LadderSheetTestActivity>, ready: () -> Boolean) {
        val deadline = SystemClock.uptimeMillis() + 10_000
        do {
            var finished = false
            scenario.onActivity { finished = ready() }
            if (finished) return
            Thread.yield()
        } while (SystemClock.uptimeMillis() < deadline)
        throw AssertionError("Real control/backend did not reach the expected state")
    }

    private fun screenshot(name: String) {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val bitmap = requireNotNull(instrumentation.uiAutomation.takeScreenshot())
        val file = requireNotNull(instrumentation.context.getExternalFilesDir(null)).resolve("$name.png")
        file.outputStream().use { assertTrue(bitmap.compress(Bitmap.CompressFormat.PNG, 100, it)) }
    }

    companion object {
        private fun iso(value: Int): SettingValue = SettingValue.Iso(ISOValue.Manual(value))
    }
}
