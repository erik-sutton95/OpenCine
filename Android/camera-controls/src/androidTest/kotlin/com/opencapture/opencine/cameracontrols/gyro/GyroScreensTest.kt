package com.opencapture.opencine.cameracontrols.gyro

import android.content.pm.ActivityInfo
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
import com.opencapture.opencine.gyro.GyroRingEvent
import com.opencapture.opencine.gyro.GyroRingPhase
import com.opencapture.opencine.gyro.GyroRingState
import com.opencapture.opencine.gyro.GyroTakeStatus
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicInteger
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/** SIMULATED arming sheet, calibration, logs and drift screens and the feature host in a real activity. */
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
    fun ringTokenAnnouncesAConflatedCaptureOnce() {
        val state = mutableStateOf(ringState(GyroRingPhase.POSING, step = 0, inZone = false, hold = 0.0))
        val token = mutableStateOf(4)
        val announcements = CopyOnWriteArrayList<String>()
        ActivityScenario.launch(GalleryOpeningTestActivity::class.java).use { scenario ->
            scenario.onActivity { activity ->
                activity.setContent {
                    GyroRingCalibrationScreen(
                        state = state.value,
                        canUseLast = false,
                        actions = GyroSetupActions(),
                        eventToken = token.value,
                        announcer = { announcements += it },
                    )
                }
            }
            awaitNodes("The posing screen must be on screen") { nodes ->
                nodes.any { tag(it) == "gyro.visual" }
            }
            assertTrue("An existing token is not replayed", announcements.isEmpty())
            // The capture reply was conflated away: the state already shows the next pose.
            scenario.onActivity {
                state.value = ringState(GyroRingPhase.POSING, step = 1, inZone = false, hold = 0.0, completedSteps = 1)
                token.value = 5
            }
            InstrumentationRegistry.getInstrumentation().waitForIdleSync()
            awaitCondition("The conflated capture must be announced") { announcements.size >= 1 }
            assertEquals(listOf(GyroCopy.stepDoneA11y(1)), announcements.toList())
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
                val badges = tagged("gyro.badge")
                assertEquals("One badge per row", 2, badges.size)
                assertTrue(
                    "A badge is not a second TalkBack stop after its merged row",
                    badges.all { label(it) == null && !it.isFocusable },
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

    @Test
    fun driftSheetHasOnePrimaryButton() {
        val recalibrated = AtomicInteger()
        val notNow = AtomicInteger()
        withScreen(
            screen = {
                GyroDriftSheet(
                    onRecalibrate = { recalibrated.incrementAndGet() },
                    onNotNow = { notNow.incrementAndGet() },
                )
            },
            assertions = {
                awaitNodes("The drift sheet must show its question") { nodes ->
                    labelsOf(nodes).contains(GyroCopy.driftQuestion)
                }
                assertEquals(1, tagged("gyro.primary").size)
                assertEquals(GyroCopy.recalibrate, deepLabel(tagged("gyro.primary").single()))
                assertTrue(labels().contains(GyroCopy.driftTitle))
                assertTrue(labels().contains(GyroCopy.notNow))
                val dismiss = tagged("gyro.drift.notNow").single()
                assertTrue(dismiss.clickTarget().performAction(AccessibilityNodeInfo.ACTION_CLICK))
                awaitCondition("Not now must reach the host") { notNow.get() == 1 }
                assertEquals(0, recalibrated.get())
                val primary = tagged("gyro.primary").single()
                assertTrue(primary.clickTarget().performAction(AccessibilityNodeInfo.ACTION_CLICK))
                awaitCondition("Recalibrate must reach the host") { recalibrated.get() == 1 }
            },
        )
    }

    @Test
    fun featureHostPresentsSetupForNewSession() {
        withFeatureHost { host ->
            host.coordinator.setEnabled(true)
            host.coordinator.setHostEligible(true)
            host.coordinator.bind(host.adapter)
            host.adapter.connect()
            awaitNodes("A new session with IBIS on must present the stabilization step") { nodes ->
                nodes.any { tag(it) == "gyro.setup.turnOff" }
            }
            assertEquals(1, tagged("gyro.primary").size)
            assertTrue(labels().contains(GyroCopy.ibisTitle))
            val turnOff = tagged("gyro.setup.turnOff").single()
            assertTrue(turnOff.clickTarget().performAction(AccessibilityNodeInfo.ACTION_CLICK))
            awaitCondition("Turn off must write OFF to the camera") {
                host.adapter.writes.toList() == listOf(mapOf("ibis" to "OFF"))
            }
            awaitNodes("The calibration step must follow") { nodes ->
                labelsOf(nodes).contains(GyroCopy.getStarted)
            }
            assertTrue(tagged("gyro.setup.turnOff").isEmpty())
            assertEquals(1, tagged("gyro.primary").size)
        }
    }

    @Test
    fun featureHostPresentsLogsAndTurnsGyroOn() {
        withFeatureHost { host ->
            assertFalse(host.coordinator.state.value.enabled)
            host.coordinator.presentLogs()
            awaitNodes("The logs screen must open on its empty state") { nodes ->
                labelsOf(nodes).contains(GyroCopy.emptyTitle)
            }
            val turnOn = tagged("gyro.primary").single()
            assertEquals(GyroCopy.turnOnGyro, deepLabel(turnOn))
            assertTrue(turnOn.clickTarget().performAction(AccessibilityNodeInfo.ACTION_CLICK))
            awaitCondition("Turn on Gyro must save the toggle") { host.coordinator.state.value.enabled }
            assertTrue(host.coordinator.state.value.logsPresented)
            host.coordinator.dismissLogs()
            awaitCondition("Dismissing the logs must close the screen") {
                !labels().contains(GyroCopy.emptyTitle)
            }
        }
    }
}
