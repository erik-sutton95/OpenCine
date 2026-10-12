package com.opencapture.monitorui

import android.os.SystemClock
import android.view.InputDevice
import android.view.MotionEvent
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.size
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.positionOnScreen
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import kotlin.math.abs
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/** A3-09: every app's chrome control is hit across the 44 dp floor and still draws at its own size. */
@RunWith(AndroidJUnit4::class)
class MonitorChromeTapTargetTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()

    @Test fun aSmallControlIsHitAcrossTheFloorWithoutGrowing() {
        ActivityScenario.launch(MonitorTestActivity::class.java).use { scenario ->
            var clicks = 0
            var size = IntSize.Zero
            var origin = Offset.Zero
            var density = 0f
            scenario.onActivity { activity ->
                density = activity.resources.displayMetrics.density
                activity.setContent {
                    Box(Modifier.fillMaxSize()) {
                        Box(Modifier.offset(120.dp, 200.dp)
                            .onGloballyPositioned { size = it.size; origin = it.positionOnScreen() }
                            .monitorChromeClickable { clicks += 1 }
                            .size(20.dp))
                    }
                }
            }
            settle()
            settle()
            assertTrue(abs(size.width - 20 * density) <= 1f && abs(size.height - 20 * density) <= 1f,
                "the control still lays out at its drawn 20 dp, was $size")
            val centre = origin + Offset(size.width / 2f, size.height / 2f)
            tap(centre + Offset(-19 * density, 0f))
            assertEquals(1, clicks, "19 dp left of centre is outside the drawing, inside the floor")
            tap(centre + Offset(0f, 19 * density))
            assertEquals(2, clicks, "19 dp below centre")
            tap(centre + Offset(-27 * density, 0f))
            assertEquals(2, clicks, "27 dp left of centre is beyond the 44 dp floor")
        }
    }

    private fun tap(point: Offset) {
        val down = SystemClock.uptimeMillis()
        for (action in listOf(MotionEvent.ACTION_DOWN, MotionEvent.ACTION_UP)) {
            val event = MotionEvent.obtain(down, SystemClock.uptimeMillis(), action, point.x, point.y, 0)
                .apply { source = InputDevice.SOURCE_TOUCHSCREEN }
            instrumentation.uiAutomation.injectInputEvent(event, true)
            event.recycle()
        }
        settle()
    }

    private fun settle() {
        instrumentation.waitForIdleSync()
        SystemClock.sleep(48)
        instrumentation.waitForIdleSync()
    }
}
