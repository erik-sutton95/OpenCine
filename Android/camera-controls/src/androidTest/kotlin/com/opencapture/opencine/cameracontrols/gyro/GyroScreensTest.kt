package com.opencapture.opencine.cameracontrols.gyro

import android.os.Bundle
import android.os.SystemClock
import android.view.accessibility.AccessibilityNodeInfo
import androidx.activity.compose.setContent
import androidx.compose.runtime.Composable
import androidx.compose.runtime.mutableStateOf
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.opencapture.opencine.cameracontrols.GalleryOpeningTestActivity
import com.opencapture.opencine.gyro.GyroArmingStep
import com.opencapture.opencine.gyro.GyroCalibrationBlock
import com.opencapture.opencine.gyro.GyroCalibrationInvalidation
import com.opencapture.opencine.gyro.GyroRingEvent
import com.opencapture.opencine.gyro.GyroRingPhase
import com.opencapture.opencine.gyro.GyroRingState
import java.util.concurrent.CopyOnWriteArrayList
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/** SIMULATED arming sheet and calibration screens hosted in a real activity. */
@RunWith(AndroidJUnit4::class)
class GyroScreensTest {
    @Test
    fun stabilizationStepShowsOnePrimaryButton() {
        withScreen(
            screen = {
                GyroSetupSheet(
                    step = GyroArmingStep.Stabilization(lensHasVRSwitch = false),
                    ring = null,
                    actions = GyroSetupActions(),
                )
            },
            assertions = {
                awaitNodes("The stabilization step must show its primary action") { nodes ->
                    nodes.any { tag(it) == "gyro.setup.turnOff" }
                }
                assertEquals(1, tagged("gyro.primary").size)
                assertEquals(1, tagged("gyro.setup.turnOff").size)
                assertEquals(1, tagged("gyro.setup.keepOn").size)
                assertEquals(1, tagged("gyro.visual").size)
                assertTrue(labels().contains(GyroCopy.ibisTitle))
                assertTrue(labels().contains(GyroCopy.ibisReason))
                assertTrue(labels().contains(GyroCopy.ibisTurnOff))
                assertTrue(labels().contains(GyroCopy.ibisKeep))
            },
        )
    }

    @Test
    fun lensLineOnlyWithVRSwitch() {
        withScreen(
            screen = {
                GyroSetupSheet(
                    step = GyroArmingStep.Stabilization(lensHasVRSwitch = true),
                    ring = null,
                    actions = GyroSetupActions(),
                )
            },
            assertions = {
                awaitNodes("The stabilization step must show its primary action") { nodes ->
                    nodes.any { tag(it) == "gyro.setup.turnOff" }
                }
                assertTrue(labels().contains(GyroCopy.ibisLens))
            },
        )
        for (known in listOf<Boolean?>(false, null)) {
            withScreen(
                screen = {
                    GyroSetupSheet(
                        step = GyroArmingStep.Stabilization(lensHasVRSwitch = known),
                        ring = null,
                        actions = GyroSetupActions(),
                    )
                },
                assertions = {
                    awaitNodes("The stabilization step must show its primary action") { nodes ->
                        nodes.any { tag(it) == "gyro.setup.turnOff" }
                    }
                    assertFalse("lensHasVRSwitch=$known", labels().contains(GyroCopy.ibisLens))
                },
            )
        }
    }

    @Test
    fun useLastOnlyWithSavedCalibration() {
        withScreen(
            screen = {
                GyroSetupSheet(
                    step = GyroArmingStep.Calibration(hasSavedCalibration = true),
                    ring = null,
                    actions = GyroSetupActions(),
                )
            },
            assertions = {
                awaitNodes("The calibration intro must show Get started") { nodes ->
                    labelsOf(nodes).contains(GyroCopy.getStarted)
                }
                assertEquals(1, tagged("gyro.primary").size)
                assertTrue(labels().contains(GyroCopy.useLastCalibration))
            },
        )
        withScreen(
            screen = {
                GyroSetupSheet(
                    step = GyroArmingStep.Calibration(hasSavedCalibration = false),
                    ring = null,
                    actions = GyroSetupActions(),
                )
            },
            assertions = {
                awaitNodes("The calibration intro must show Get started") { nodes ->
                    labelsOf(nodes).contains(GyroCopy.getStarted)
                }
                assertEquals(1, tagged("gyro.primary").size)
                assertFalse(labels().contains(GyroCopy.useLastCalibration))
            },
        )
    }

    @Test
    fun introHasNoCaptureButton() {
        withScreen(
            screen = {
                GyroRingCalibrationScreen(
                    state = ringState(GyroRingPhase.INTRO, step = null),
                    canUseLast = false,
                    actions = GyroSetupActions(),
                )
            },
            assertions = {
                awaitNodes("The calibration intro must show Get started") { nodes ->
                    labelsOf(nodes).contains(GyroCopy.getStarted)
                }
                assertEquals(1, tagged("gyro.primary").size)
                assertEquals(1, tagged("gyro.visual").size)
                assertTrue(labels().contains(GyroCopy.cancel))
                assertEquals(
                    "The ring's one semantics node carries the instruction",
                    listOf(GyroCopy.calibrateTitle),
                    tagged("gyro.visual").mapNotNull { it.contentDescription?.toString() },
                )
                for (forbidden in listOf("Capture", "Verify", "Start again")) {
                    assertFalse("The intro must not offer $forbidden", labels().contains(forbidden))
                }
                assertFalse(labels().contains(GyroCopy.useLastCalibration))
            },
        )
        withScreen(
            screen = {
                GyroRingCalibrationScreen(
                    state = ringState(GyroRingPhase.INTRO, step = null),
                    canUseLast = true,
                    actions = GyroSetupActions(),
                )
            },
            assertions = {
                awaitNodes("The saved-calibration link must be offered") { nodes ->
                    labelsOf(nodes).contains(GyroCopy.useLastCalibration)
                }
            },
        )
    }

    @Test
    fun blockedStateShowsOneLine() {
        withScreen(
            screen = {
                GyroRingCalibrationScreen(
                    state = ringState(
                        phase = GyroRingPhase.BLOCKED,
                        step = 0,
                        inZone = false,
                        block = GyroCalibrationBlock.MOVING,
                    ),
                    canUseLast = false,
                    actions = GyroSetupActions(),
                )
            },
            assertions = {
                awaitNodes("The block line must be on screen") { nodes ->
                    labelsOf(nodes).contains(GyroCopy.block(GyroCalibrationBlock.MOVING))
                }
                assertEquals(1, tagged("gyro.hint").size)
                assertTrue(tagged("gyro.primary").isEmpty())
                assertFalse(labels().contains(GyroCopy.holdHint))
            },
        )
    }

    @Test
    fun ringAnnouncesProgressAndCaptures() {
        val state = mutableStateOf(ringState(GyroRingPhase.INTRO, step = null))
        val announcements = CopyOnWriteArrayList<String>()
        ActivityScenario.launch(GalleryOpeningTestActivity::class.java).use { scenario ->
            scenario.onActivity { activity ->
                activity.setContent {
                    GyroRingCalibrationScreen(
                        state = state.value,
                        canUseLast = false,
                        actions = GyroSetupActions(),
                        announcer = { announcements += it },
                    )
                }
            }
            awaitNodes("The calibration intro must be on screen") { nodes ->
                labelsOf(nodes).contains(GyroCopy.getStarted)
            }
            assertTrue(announcements.isEmpty())

            fun update(next: GyroRingState) {
                scenario.onActivity { state.value = next }
                InstrumentationRegistry.getInstrumentation().waitForIdleSync()
            }

            update(ringState(GyroRingPhase.POSING, step = 0, inZone = true, hold = 0.1))
            awaitNodes("The posing screen must show the hold hint") { nodes ->
                labelsOf(nodes).contains(GyroCopy.holdHint)
            }
            assertTrue(announcements.isEmpty())

            update(ringState(GyroRingPhase.POSING, step = 0, inZone = true, hold = 0.3))
            awaitCondition("A quarter hold must be announced") { announcements.size >= 1 }
            assertEquals(GyroCopy.holdProgressA11y(25), announcements.last())

            update(ringState(GyroRingPhase.POSING, step = 0, inZone = true, hold = 0.35))
            assertEquals("One milestone is announced once per crossing", 1, announcements.size)

            update(ringState(GyroRingPhase.POSING, step = 0, inZone = true, hold = 0.8))
            awaitCondition("The three-quarter hold must be announced") { announcements.size >= 2 }
            assertEquals(GyroCopy.holdProgressA11y(75), announcements.last())

            update(
                ringState(
                    GyroRingPhase.POSING,
                    step = 0,
                    inZone = true,
                    hold = 1.0,
                    completedSteps = 1,
                    event = GyroRingEvent.STEP_CAPTURED,
                ),
            )
            awaitCondition("A captured step must be announced") { announcements.size >= 3 }
            assertEquals(GyroCopy.stepDoneA11y(1), announcements.last())

            update(
                ringState(
                    GyroRingPhase.COMPLETE,
                    step = null,
                    completedSteps = 3,
                    event = GyroRingEvent.COMPLETED,
                    calibrationJSON = "{}",
                ),
            )
            awaitCondition("Completion must be announced") { announcements.size >= 4 }
            assertEquals(GyroCopy.completeTitle, announcements.last())
        }
    }

    private fun ringState(
        phase: GyroRingPhase,
        step: Int? = 0,
        inZone: Boolean? = null,
        hold: Double? = null,
        block: GyroCalibrationBlock? = null,
        invalidation: GyroCalibrationInvalidation? = null,
        completedSteps: Int = 0,
        event: GyroRingEvent? = null,
        calibrationJSON: String? = null,
    ) = GyroRingState(
        phase = phase,
        step = step,
        inZone = inZone,
        hold = hold,
        block = block,
        invalidation = invalidation,
        completedSteps = completedSteps,
        event = event,
        calibrationJSON = calibrationJSON,
    )

    private fun withScreen(screen: @Composable () -> Unit, assertions: () -> Unit) {
        ActivityScenario.launch(GalleryOpeningTestActivity::class.java).use { scenario ->
            scenario.onActivity { activity -> activity.setContent { screen() } }
            assertions()
        }
    }

    private fun tagged(id: String): List<AccessibilityNodeInfo> = nodes().filter { tag(it) == id }

    private fun labels(): List<String> = labelsOf(nodes())

    private fun labelsOf(nodes: List<AccessibilityNodeInfo>): List<String> =
        nodes.mapNotNull { label(it) }

    private fun label(node: AccessibilityNodeInfo): String? {
        val text = node.text?.toString()?.takeIf { it.isNotEmpty() }
        return text ?: node.contentDescription?.toString()?.takeIf { it.isNotEmpty() }
    }

    private fun tag(node: AccessibilityNodeInfo): String? {
        node.viewIdResourceName?.substringAfter(":id/")?.takeIf { it.isNotEmpty() }?.let { return it }
        if (TEST_TAG !in node.availableExtraData) return null
        node.refreshWithExtraData(TEST_TAG, Bundle())
        return node.extras.getCharSequence(TEST_TAG)?.toString()
    }

    private fun nodes(): List<AccessibilityNodeInfo> {
        val pending = ArrayDeque<AccessibilityNodeInfo>()
        InstrumentationRegistry.getInstrumentation().uiAutomation.rootInActiveWindow?.let(pending::add)
        val result = mutableListOf<AccessibilityNodeInfo>()
        while (pending.isNotEmpty() && result.size < 5_000) {
            val node = pending.removeFirst()
            result += node
            for (index in 0 until node.childCount) node.getChild(index)?.let(pending::add)
        }
        return result
    }

    private fun awaitNodes(message: String, predicate: (List<AccessibilityNodeInfo>) -> Boolean) {
        val deadline = SystemClock.uptimeMillis() + 5_000
        while (SystemClock.uptimeMillis() < deadline) {
            InstrumentationRegistry.getInstrumentation().waitForIdleSync()
            if (predicate(nodes())) return
            SystemClock.sleep(20)
        }
        assertTrue(message, predicate(nodes()))
    }

    private fun awaitCondition(message: String, predicate: () -> Boolean) {
        val deadline = SystemClock.uptimeMillis() + 5_000
        while (SystemClock.uptimeMillis() < deadline) {
            InstrumentationRegistry.getInstrumentation().waitForIdleSync()
            if (predicate()) return
            SystemClock.sleep(20)
        }
        assertTrue(message, predicate())
    }

    private companion object {
        /** The extra a Compose node reports its test tag under, when the resource id is absent. */
        const val TEST_TAG = "androidx.compose.ui.semantics.testTag"
    }
}
