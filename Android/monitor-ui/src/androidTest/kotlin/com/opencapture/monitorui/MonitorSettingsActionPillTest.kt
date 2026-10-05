package com.opencapture.monitorui

import androidx.activity.compose.setContent
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Text
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.opencapture.monitorui.settings.MonitorSettingsActionPill
import kotlin.math.roundToInt
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/** The settings action pill's touch target: 48 dp by default, the capsule's own bounds when off. */
@RunWith(AndroidJUnit4::class)
class MonitorSettingsActionPillTest {
    @Test fun minimumTouchTargetMeasuresAtLeastFortyEightDp() {
        val (pill, _, density) = measure(minimumTouchTarget = true)
        assertTrue(pill.height >= (48 * density).roundToInt(), "pill $pill")
    }

    @Test fun withoutMinimumTouchTargetThePillKeepsTheCapsuleBounds() {
        val (pill, capsule, density) = measure(minimumTouchTarget = false)
        assertEquals(capsule, pill)
        assertTrue(pill.height < (48 * density).roundToInt(), "pill $pill")
    }

    /** The shared pill and the capsule without a minimum size (alpha, plate, border, click, padding). */
    private fun measure(minimumTouchTarget: Boolean): Triple<IntSize, IntSize, Float> {
        var pill = IntSize.Zero
        var capsule = IntSize.Zero
        var density = 0f
        ActivityScenario.launch(MonitorTestActivity::class.java).use { scenario ->
            scenario.onActivity { activity ->
                density = activity.resources.displayMetrics.density
                activity.setContent {
                    Column {
                        MonitorSettingsActionPill("Open", modifier = Modifier.onSizeChanged { pill = it },
                            minimumTouchTarget = minimumTouchTarget) {}
                        Row(
                            Modifier.onSizeChanged { capsule = it }
                                .alpha(1f)
                                .background(MonitorPalette.accent.copy(alpha = 0.16f), CircleShape)
                                .border(1.dp, MonitorPalette.accent.copy(alpha = 0.5f), CircleShape)
                                .clickable(remember { MutableInteractionSource() }, null, role = Role.Button) {}
                                .padding(horizontal = 14.dp, vertical = 9.dp),
                            horizontalArrangement = Arrangement.spacedBy(6.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Text("OPEN", style = MonitorTypography.readout(10.5f, FontWeight.Bold),
                                color = MonitorPalette.accent, maxLines = 1, letterSpacing = 0.6.sp)
                        }
                    }
                }
            }
            InstrumentationRegistry.getInstrumentation().waitForIdleSync()
            scenario.onActivity { assertTrue(pill != IntSize.Zero && capsule != IntSize.Zero) }
        }
        return Triple(pill, capsule, density)
    }
}
