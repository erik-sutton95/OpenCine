package com.opencapture.opencine.cameracontrols.gyro

import android.content.pm.ActivityInfo
import android.graphics.Rect
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
import com.opencapture.opencine.gyro.GyroLogEntry
import com.opencapture.opencine.gyro.GyroRingEvent
import com.opencapture.opencine.gyro.GyroRingPhase
import com.opencapture.opencine.gyro.GyroRingState
import com.opencapture.opencine.gyro.GyroTakeStatus
import java.io.File
import java.util.UUID
import java.util.concurrent.CopyOnWriteArrayList
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/** SIMULATED arming sheet, calibration and logs screens hosted in a real activity. */
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
                    tagged("gyro.visual").mapNotNull { deepLabel(it) },
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

    @Test
    fun rowsShowOneBadgeEach() {
        val ready = logEntry(startMillis = NOW - 60_000)
        val gaps = logEntry(startMillis = NOW - 120_000, status = GyroTakeStatus.SmallGaps)
        withScreen(
            screen = {
                GyroLogsScreen(
                    entries = listOf(ready, gaps),
                    tipVisible = false,
                    gyroEnabled = true,
                    nowMillis = NOW,
                    actions = GyroLogsActions(),
                )
            },
            assertions = {
                awaitNodes("Both take rows must be on screen") { nodes ->
                    listOf(ready, gaps).all { entry ->
                        nodes.any { tag(it) == "gyro.row.${entry.id}" }
                    }
                }
                assertEquals(
                    "One badge per row, in row order",
                    listOf(GyroCopy.status(ready.status), GyroCopy.status(gaps.status)),
                    tagged("gyro.badge").mapNotNull { label(it) },
                )
                for (entry in listOf(ready, gaps)) {
                    val row = tagged("gyro.row.${entry.id}").single()
                    assertTrue(
                        "The row must read its status",
                        deepLabel(row)?.contains(GyroCopy.status(entry.status)) == true,
                    )
                }
            },
        )
    }

    @Test
    fun emptyStateShowsOneButton() {
        withScreen(
            screen = {
                GyroLogsScreen(
                    entries = emptyList(),
                    tipVisible = false,
                    gyroEnabled = false,
                    nowMillis = NOW,
                    actions = GyroLogsActions(),
                )
            },
            assertions = {
                awaitNodes("The empty state must show its title") { nodes ->
                    labelsOf(nodes).contains(GyroCopy.emptyTitle)
                }
                assertEquals(1, tagged("gyro.primary").size)
                assertTrue(labels().contains(GyroCopy.turnOnGyro))
                assertTrue(labels().contains(GyroCopy.emptyTitle))
                assertTrue(labels().contains(GyroCopy.emptyBody))
            },
        )
        withScreen(
            screen = {
                GyroLogsScreen(
                    entries = emptyList(),
                    tipVisible = false,
                    gyroEnabled = true,
                    nowMillis = NOW,
                    actions = GyroLogsActions(),
                )
            },
            assertions = {
                awaitNodes("The empty state must show its title") { nodes ->
                    labelsOf(nodes).contains(GyroCopy.emptyTitle)
                }
                assertTrue(
                    "Gyro is already on, so the empty state offers no action",
                    tagged("gyro.primary").isEmpty(),
                )
                assertFalse(labels().contains(GyroCopy.turnOnGyro))
            },
        )
    }

    @Test
    fun takePageLeadsWithVerdictAndSharePrimary() {
        val entry = logEntry(startMillis = NOW - 60_000)
        withScreen(
            screen = { GyroTakeScreen(entry, onShare = {}) },
            assertions = {
                awaitNodes("The take page must show its verdict") { nodes ->
                    labelsOf(nodes).contains(GyroCopy.verdict(entry.status))
                }
                assertEquals(1, tagged("gyro.primary").size)
                assertEquals(GyroCopy.shareLog, deepLabel(tagged("gyro.primary").single()))
                assertEquals(
                    "The visual carries the verdict",
                    listOf(GyroCopy.verdict(entry.status)),
                    tagged("gyro.visual").mapNotNull { deepLabel(it) },
                )
                assertTrue(labels().contains(GyroCopy.details.uppercase()))
                assertTrue(labels().contains(GyroCopy.startOffset(0.12)))
                assertTrue(labels().contains(GyroCopy.smoothness(entry.status)))
                assertTrue(labels().contains(GyroCopy.sampleRate(200.0)))
                val verdict = nodes().first { label(it) == GyroCopy.verdict(entry.status) }
                val details = nodes().first { label(it) == GyroCopy.details.uppercase() }
                assertTrue(
                    "The verdict leads the details",
                    bounds(verdict).top < bounds(details).top,
                )
            },
        )
    }

    @Test
    fun activeTakeCannotBeSelectedOrDeleted() {
        val active = logEntry(startMillis = NOW - 60_000, status = GyroTakeStatus.Recording)
        val ready = logEntry(startMillis = NOW - 120_000)
        withScreen(
            screen = {
                GyroLogsScreen(
                    entries = listOf(active, ready),
                    tipVisible = false,
                    gyroEnabled = true,
                    nowMillis = NOW,
                    actions = GyroLogsActions(),
                )
            },
            assertions = {
                awaitNodes("Both take rows must be on screen") { nodes ->
                    nodes.any { tag(it) == "gyro.row.${active.id}" } &&
                        nodes.any { tag(it) == "gyro.row.${ready.id}" }
                }
                val select = tagged("gyro.select").single()
                assertEquals(GyroCopy.select, deepLabel(select))
                assertTrue("Select starts the mode", select.clickTarget().performAction(AccessibilityNodeInfo.ACTION_CLICK))
                awaitCondition("Select mode must show the one share action") {
                    tagged("gyro.primary").size == 1
                }
                assertTrue(labels().contains(GyroCopy.shareCount(0)))
                val activeRow = tagged("gyro.row.${active.id}").single()
                val readyRow = tagged("gyro.row.${ready.id}").single()
                assertFalse(
                    "A recording row cannot be swiped away",
                    activeRow.canDismiss(),
                )
                assertTrue("A finished row offers the swipe delete", readyRow.canDismiss())
                assertFalse(
                    "A recording row cannot be selected",
                    activeRow.performAction(AccessibilityNodeInfo.ACTION_CLICK),
                )
                assertTrue(
                    "A finished row can be selected",
                    readyRow.performAction(AccessibilityNodeInfo.ACTION_CLICK),
                )
                awaitCondition("The share count follows the selection") {
                    labels().contains(GyroCopy.shareCount(1))
                }
            },
        )
    }

    @Test
    fun landscapeShowsListAndTakeSideBySide() {
        val newest = logEntry(startMillis = NOW - 60_000)
        val older = logEntry(startMillis = NOW - 120_000, status = GyroTakeStatus.SmallGaps)
        ActivityScenario.launch(GalleryOpeningTestActivity::class.java).use { scenario ->
            try {
                val screen: @Composable () -> Unit = {
                    GyroLogsScreen(
                        entries = listOf(newest, older),
                        tipVisible = false,
                        gyroEnabled = true,
                        nowMillis = NOW,
                        actions = GyroLogsActions(),
                    )
                }
                scenario.onActivity { activity ->
                    activity.requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE
                    activity.setContent { screen() }
                }
                awaitNodes("The window must turn landscape") { nodes ->
                    nodes.firstOrNull()?.let {
                        bounds(it).width() > bounds(it).height()
                    } == true
                }
                // The configuration change may recreate the activity; draw the screen again.
                scenario.onActivity { activity -> activity.setContent { screen() } }
                awaitCondition("The list and the selected take must both be on screen") {
                    tagged("gyro.row.${newest.id}").isNotEmpty() &&
                        tagged("gyro.row.${older.id}").isNotEmpty() &&
                        tagged("gyro.visual").size == 1
                }
                val row = tagged("gyro.row.${newest.id}").single()
                val take = tagged("gyro.visual").single()
                assertTrue(
                    "The list sits left of the take page",
                    bounds(row).right <= bounds(take).left,
                )
                assertEquals(
                    "The first entry is selected by default",
                    GyroCopy.verdict(newest.status),
                    deepLabel(take),
                )
            } finally {
                scenario.onActivity { activity ->
                    activity.requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
                }
            }
        }
    }

    private fun logEntry(
        startMillis: Long,
        status: GyroTakeStatus = GyroTakeStatus.Ready,
        camera: String = "SIMULATED camera",
        duration: Double = 48.0,
        rate: Double = 200.0,
        offset: Double = 0.12,
    ): GyroLogEntry {
        val id = UUID.randomUUID().toString().uppercase()
        val descriptor = JSONObject()
            .put("id", id)
            .put("cameraLabel", camera)
            .put("startDate", startMillis.toDouble())
            .put("filename", "$id.gcsv")
            .put("isPartial", false)
        if (status != GyroTakeStatus.NotCalibrated) {
            descriptor.put(
                "mountCalibration",
                JSONObject()
                    .put("rotation", JSONArray())
                    .put("validationErrorDegrees", 1.5)
                    .put("separationDegrees", 60),
            )
        }
        val summary = when (status) {
            GyroTakeStatus.CutShort, GyroTakeStatus.Recording -> null
            else -> JSONObject()
                .put("duration", duration)
                .put("measuredRate", rate)
                .put("largestGap", if (status == GyroTakeStatus.SmallGaps) 0.1 else 0.0)
                .put("rejectedSampleCount", 0)
                .put("approximateStartOffset", offset)
                .put("termination", "normal")
                .put("isPartial", false)
                .apply {
                    if (status is GyroTakeStatus.MountMoved) {
                        put("mountMovedOffset", status.offsetSeconds)
                    }
                }
        }
        return GyroLogEntry(
            descriptor = descriptor,
            summary = summary,
            file = File("SIMULATED-$id.gcsv"),
            active = status == GyroTakeStatus.Recording,
        )
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

    private fun bounds(node: AccessibilityNodeInfo): Rect = Rect().also { node.getBoundsInScreen(it) }

    /**
     * The platform reports an accessibility action both in the legacy action mask and in the action
     * list depending on its API level; either one carries the row's dismiss action.
     */
    @Suppress("DEPRECATION")
    private fun AccessibilityNodeInfo.canDismiss(): Boolean =
        (actions and AccessibilityNodeInfo.ACTION_DISMISS) != 0 ||
            actionList.any { it.id == AccessibilityNodeInfo.ACTION_DISMISS }

    /**
     * The platform bridge exposes a merged Compose node (a button, a row, a visual) as the tagged
     * wrapper with the merged text and description on its descendants, so a tagged element reads as
     * the first label found in its own subtree.
     */
    private fun deepLabel(node: AccessibilityNodeInfo): String? =
        label(node) ?: (0 until node.childCount).firstNotNullOfOrNull { index ->
            node.getChild(index)?.let(::deepLabel)
        }

    /** The node itself or the first descendant that takes a click. */
    private fun AccessibilityNodeInfo.clickTarget(): AccessibilityNodeInfo =
        if (isClickable) {
            this
        } else {
            (0 until childCount).firstNotNullOfOrNull { index ->
                getChild(index)?.takeIf { it.hasClickable() }?.clickTarget()
            } ?: this
        }

    private fun AccessibilityNodeInfo.hasClickable(): Boolean =
        isClickable || (0 until childCount).any { getChild(it)?.hasClickable() == true }

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

        /** A fixed clock so the test takes group under Today regardless of the run date. */
        const val NOW = 1_760_000_000_000L
    }
}
