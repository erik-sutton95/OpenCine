package com.opencapture.opencine.cameracontrols.gyro

import android.content.pm.ActivityInfo
import android.graphics.Rect
import android.os.ParcelFileDescriptor
import android.os.SystemClock
import android.view.KeyEvent
import android.view.accessibility.AccessibilityNodeInfo
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.key
import androidx.compose.ui.Modifier
import androidx.core.view.WindowInsetsCompat
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.opencapture.opencine.cameracontrols.GalleryOpeningTestActivity
import com.opencapture.opencine.gyro.GyroArmingStep
import com.opencapture.opencine.gyro.GyroCalibrationBlock
import com.opencapture.opencine.gyro.GyroCalibrationInvalidation
import com.opencapture.opencine.gyro.GyroLogEntry
import com.opencapture.opencine.gyro.GyroPillKind
import com.opencapture.opencine.gyro.GyroPillState
import com.opencapture.opencine.gyro.GyroRingPhase
import com.opencapture.opencine.gyro.GyroRingState
import com.opencapture.opencine.gyro.GyroStabilizationState
import com.opencapture.opencine.gyro.GyroTakeStatus
import com.opencapture.opencine.gyro.GyroVector3
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * SIMULATED sweep over every gyro screen state: both orientations, activity recreation, Back as
 * the screen's cancel, and a TalkBack label on every reachable element. With the instrumentation
 * argument `gyroScreenshots=true` the orientation sweep also saves one PNG per state and
 * orientation under [SHOT_DIR].
 */
@RunWith(AndroidJUnit4::class)
class GyroScreensSweepTest {
    @Test
    fun everyScreenRendersInBothOrientations() {
        val capture = InstrumentationRegistry.getArguments().getString("gyroScreenshots") == "true"
        if (capture) {
            // executeShellCommand runs one command without a shell, so no && chaining.
            shell("rm -rf $SHOT_DIR")
            shell("mkdir -p $SHOT_DIR")
        }
        ActivityScenario.launch(GalleryOpeningTestActivity::class.java).use { scenario ->
            try {
                for (landscape in listOf(false, true)) {
                    orient(scenario, landscape)
                    val orientation = if (landscape) "landscape" else "portrait"
                    for (state in sweepStates()) {
                        show(scenario, state)
                        if (capture) screenshot("${state.name}-$orientation")
                        val safe = safeArea(scenario)
                        val where = "${state.name} in $orientation"
                        for (text in state.visible) {
                            val node = nodes().firstOrNull { label(it) == text && it.isVisibleToUser }
                            assertNotNull("$where must show \"$text\"", node)
                            assertTrue(
                                "$where: \"$text\" ${bounds(node!!)} must lie inside $safe",
                                safe.contains(bounds(node)),
                            )
                        }
                        if (state.present.isNotEmpty()) {
                            // A list's scroll actions can land a frame after its first draw; retry.
                            var reached: Set<String> = emptySet()
                            awaitCondition("$where must reach ${state.present}") {
                                reached = reached + reachableLabels()
                                state.present.all { wanted -> reached.any { it.contains(wanted) } }
                            }
                        }
                        val primaries = tagged("gyro.primary")
                        val visuals = tagged("gyro.visual")
                        val pane = landscape && state.landscapePane
                        assertEquals("$where primary count", if (state.primary || pane) 1 else 0, primaries.size)
                        assertEquals("$where visual count", if (state.visual || pane) 1 else 0, visuals.size)
                        primaries.singleOrNull()?.let { primary ->
                            val button = bounds(primary)
                            assertTrue("$where: primary $button must lie inside $safe", safe.contains(button))
                            visuals.singleOrNull()?.let { visual ->
                                assertFalse(
                                    "$where: primary $button must not overlap the visual ${bounds(visual)}",
                                    Rect.intersects(button, bounds(visual)),
                                )
                            }
                        }
                    }
                }
            } finally {
                scenario.onActivity { it.requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_PORTRAIT }
            }
        }
    }

    @Test
    fun recreationKeepsCalibrationStep() {
        withFeatureHost { host ->
            armWithIbisOff(host)
            host.coordinator.beginCalibration()
            host.coordinator.startRing()
            awaitCondition("The ring must start posing") {
                host.coordinator.state.value.ring?.phase == GyroRingPhase.POSING
            }
            holdUntil(host) { it.phase == GyroRingPhase.POSING && it.step == 1 && it.hold == 0.5 }
            val counter = GyroCopy.stepCounter(2).uppercase()
            awaitNodes("The second pose must read its counter") { nodes -> labelsOf(nodes).contains(counter) }
            val before = host.coordinator.state.value.ring

            host.scenario.recreate()
            host.showHost()

            awaitNodes("The recreated activity must show the same step") { nodes ->
                labelsOf(nodes).contains(counter)
            }
            assertTrue(labels().contains(GyroCopy.step(1)))
            assertEquals("Recreation must not touch the ring", before, host.coordinator.state.value.ring)
        }
    }

    @Test
    fun backActsAsCancel() {
        withFeatureHost { host ->
            host.coordinator.setEnabled(true)
            host.coordinator.setHostEligible(true)
            host.coordinator.bind(host.adapter)
            host.adapter.connect()
            awaitNodes("A new session with IBIS on must present the stabilization step") { nodes ->
                nodes.any { tag(it) == "gyro.setup.turnOff" }
            }
            pressBack()
            awaitCondition("Back on the stabilization step must keep IBIS on") {
                val state = host.coordinator.state.value
                state.setupSteps.none { it is GyroArmingStep.Stabilization } && state.pill.stabilizationWarning
            }
            assertTrue("Keep it on writes nothing to the camera", host.adapter.writes.isEmpty())

            awaitNodes("The calibration step must follow") { nodes ->
                labelsOf(nodes).contains(GyroCopy.getStarted)
            }
            val start = tagged("gyro.primary").single()
            assertTrue(start.clickTarget().performAction(AccessibilityNodeInfo.ACTION_CLICK))
            awaitCondition("Get started must start the ring") {
                host.coordinator.state.value.ring?.phase == GyroRingPhase.POSING
            }
            awaitNodes("The posing step must be on screen") { nodes ->
                labelsOf(nodes).contains(GyroCopy.holdHint)
            }
            pressBack()
            awaitCondition("Back on a calibration step must close the calibration and stay armed") {
                val state = host.coordinator.state.value
                state.ring == null && state.setupSteps.isEmpty() && state.isArmed
            }
            awaitCondition("The calibration screen must close") { !labels().contains(GyroCopy.holdHint) }
        }
    }

    @Test
    fun everyStateHasATalkBackLabel() {
        ActivityScenario.launch(GalleryOpeningTestActivity::class.java).use { scenario ->
            orient(scenario, landscape = false)
            for (state in sweepStates()) {
                show(scenario, state)
                for (node in nodes().filter { it.isVisibleToUser }) {
                    if (node.text != null) {
                        assertTrue("${state.name}: a text node must not be blank", !node.text.isNullOrBlank())
                    }
                    if (node.isClickable) {
                        assertNotNull(
                            "${state.name}: clickable ${node.className} at ${bounds(node)} needs a label",
                            deepLabel(node)?.takeIf { it.isNotBlank() },
                        )
                    }
                }
            }
            val pills = GyroPillKind.entries.flatMap { kind -> listOf(false, true).map { GyroPillState(kind, it) } }
            scenario.onActivity { activity ->
                activity.setContent {
                    Column { pills.forEach { GyroPillChip(state = it, onClick = {}) } }
                }
            }
            val expected = pills.filter { it.kind != GyroPillKind.HIDDEN }
                .map { GyroCopy.pillA11y(it.kind, it.stabilizationWarning) }
            var read: List<String?> = emptyList()
            awaitCondition("Each pill reads GyroCopy.pillA11y for its kind and warning; HIDDEN renders nothing") {
                read = tagged("gyro.pill").map { deepLabel(it) }
                read == expected
            }
            assertEquals(expected, read)
        }
    }

    /** One screen state of the sweep and what must be on screen in it. */
    private class SweepState(
        /** Kebab-case, stable: the screenshot file name without the orientation. */
        val name: String,
        /** Texts that must be visible inside the safe area in both orientations. */
        val visible: List<String>,
        /** Texts that must be read somewhere in the tree, alone or inside a merged row label. */
        val present: List<String> = emptyList(),
        val primary: Boolean,
        val visual: Boolean,
        /** Landscape adds the take pane (one primary and one visual) beside the list. */
        val landscapePane: Boolean = false,
        val screen: @Composable () -> Unit,
    )

    private fun sweepStates(): List<SweepState> {
        val actions = GyroSetupActions()
        fun ring(state: GyroRingState): @Composable () -> Unit = {
            GyroRingCalibrationScreen(state = state, canUseLast = false, actions = actions, announcer = {})
        }
        fun setup(step: GyroArmingStep): @Composable () -> Unit = {
            GyroSetupSheet(step = step, ring = null, actions = actions)
        }
        fun logs(entries: List<GyroLogEntry>, enabled: Boolean): @Composable () -> Unit = {
            GyroLogsScreen(
                entries = entries,
                tipVisible = false,
                gyroEnabled = enabled,
                nowMillis = NOW,
                actions = GyroLogsActions(),
            )
        }
        val badges = listOf(
            GyroTakeStatus.Ready,
            GyroTakeStatus.SmallGaps,
            GyroTakeStatus.CutShort,
            GyroTakeStatus.MountMoved(75.0),
            GyroTakeStatus.NotCalibrated,
            GyroTakeStatus.Recording,
        )
        val badgeEntries = badges.mapIndexed { index, status ->
            logEntry(startMillis = NOW - (index + 1) * 60_000L, status = status)
        }
        val ready = logEntry(startMillis = NOW - 60_000)
        val uncalibrated = logEntry(startMillis = NOW - 60_000, status = GyroTakeStatus.NotCalibrated)
        val ibis = listOf(GyroCopy.ibisTitle, GyroCopy.ibisReason, GyroCopy.ibisTurnOff, GyroCopy.ibisKeep)
        val intro = listOf(GyroCopy.calibrateTitle, GyroCopy.calibrateBody, GyroCopy.getStarted, GyroCopy.cancel)
        return buildList {
            add(SweepState("setup-ibis", ibis, primary = true, visual = true, screen = setup(GyroArmingStep.Stabilization(false))))
            add(
                SweepState(
                    "setup-ibis-lens",
                    ibis + GyroCopy.ibisLens,
                    primary = true,
                    visual = true,
                    screen = setup(GyroArmingStep.Stabilization(true)),
                ),
            )
            add(SweepState("calibration-intro", intro, primary = true, visual = true, screen = setup(GyroArmingStep.Calibration(false))))
            add(
                SweepState(
                    "calibration-intro-use-last",
                    intro + GyroCopy.useLastCalibration,
                    primary = true,
                    visual = true,
                    screen = setup(GyroArmingStep.Calibration(true)),
                ),
            )
            add(
                SweepState(
                    "posing-out-of-zone",
                    listOf(GyroCopy.stepCounter(1).uppercase(), GyroCopy.step(0), GyroCopy.holdHint, GyroCopy.cancel),
                    primary = false,
                    visual = true,
                    screen = ring(ringState(GyroRingPhase.POSING, step = 0, inZone = false, hold = 0.0)),
                ),
            )
            add(
                SweepState(
                    "posing-in-zone-hold",
                    listOf(GyroCopy.stepCounter(2).uppercase(), GyroCopy.step(1), GyroCopy.holdHint, GyroCopy.cancel),
                    primary = false,
                    visual = true,
                    screen = ring(
                        ringState(GyroRingPhase.POSING, step = 1, inZone = true, hold = 0.5, completedSteps = 1),
                    ),
                ),
            )
            for (block in GyroCalibrationBlock.entries) {
                add(
                    SweepState(
                        "blocked-${kebab(block.name)}",
                        listOf(GyroCopy.block(block), GyroCopy.step(0), GyroCopy.cancel),
                        primary = false,
                        visual = true,
                        screen = ring(ringState(GyroRingPhase.BLOCKED, step = 0, inZone = false, block = block)),
                    ),
                )
            }
            add(
                SweepState(
                    "retrying",
                    listOf(GyroCopy.retry, GyroCopy.step(0), GyroCopy.cancel),
                    primary = false,
                    visual = true,
                    screen = ring(ringState(GyroRingPhase.RETRYING, step = null)),
                ),
            )
            for (reason in GyroCalibrationInvalidation.entries) {
                add(
                    SweepState(
                        "invalidated-${kebab(reason.name)}",
                        listOf(GyroCopy.invalidation(reason), GyroCopy.done, GyroCopy.cancel),
                        primary = true,
                        visual = true,
                        screen = ring(ringState(GyroRingPhase.INVALIDATED, step = null, invalidation = reason)),
                    ),
                )
            }
            add(
                SweepState(
                    "complete",
                    listOf(GyroCopy.completeTitle, GyroCopy.completeBody, GyroCopy.done),
                    primary = true,
                    visual = true,
                    screen = ring(
                        ringState(GyroRingPhase.COMPLETE, step = null, completedSteps = 3, calibrationJSON = "{}"),
                    ),
                ),
            )
            add(
                SweepState(
                    "logs-empty-gyro-off",
                    listOf(GyroCopy.logsTitle, GyroCopy.emptyTitle, GyroCopy.emptyBody, GyroCopy.turnOnGyro, GyroCopy.done),
                    primary = true,
                    visual = false,
                    screen = logs(emptyList(), enabled = false),
                ),
            )
            add(
                SweepState(
                    "logs-empty-gyro-on",
                    listOf(GyroCopy.logsTitle, GyroCopy.emptyTitle, GyroCopy.emptyBody, GyroCopy.done),
                    primary = false,
                    visual = false,
                    screen = logs(emptyList(), enabled = true),
                ),
            )
            add(
                SweepState(
                    "logs-badges",
                    // Badges are not TalkBack stops; each status is read by its merged row.
                    listOf(GyroCopy.logsTitle, GyroCopy.select, GyroCopy.done),
                    present = badges.map(GyroCopy::status),
                    primary = false,
                    visual = false,
                    landscapePane = true,
                    screen = logs(badgeEntries, enabled = true),
                ),
            )
            add(
                SweepState(
                    "take-ready",
                    listOf(GyroCopy.verdict(ready.status), GyroCopy.shareLog),
                    primary = true,
                    visual = true,
                    screen = { GyroTakeScreen(ready, onShare = {}) },
                ),
            )
            add(
                SweepState(
                    "take-not-calibrated",
                    listOf(GyroCopy.verdict(uncalibrated.status), GyroCopy.shareLog),
                    primary = true,
                    visual = true,
                    screen = { GyroTakeScreen(uncalibrated, onShare = {}) },
                ),
            )
            add(
                SweepState(
                    "drift-sheet",
                    listOf(GyroCopy.driftTitle, GyroCopy.driftQuestion, GyroCopy.recalibrate, GyroCopy.notNow),
                    primary = true,
                    visual = false,
                    screen = { GyroDriftSheet(onRecalibrate = {}, onNotNow = {}) },
                ),
            )
        }
    }

    /** Clears the window, then draws [state] in a fresh composition and waits for its texts. */
    private fun show(scenario: ActivityScenario<GalleryOpeningTestActivity>, state: SweepState) {
        scenario.onActivity { activity -> activity.setContent { Box(Modifier.fillMaxSize()) } }
        awaitNodes("The window must clear before ${state.name}") { nodes -> labelsOf(nodes).isEmpty() }
        scenario.onActivity { activity -> activity.setContent { key(state.name) { state.screen() } } }
        awaitNodes("${state.name} must draw its texts") { nodes ->
            val visible = nodes.filter { it.isVisibleToUser }.mapNotNull { label(it) }
            visible.containsAll(state.visible)
        }
    }

    /**
     * Every label on screen plus those a scrollable list brings into view: each scrollable node is
     * scrolled forward until it stops, then back to the top so later checks see the first screen.
     */
    private fun reachableLabels(): Set<String> {
        val found = labels().toMutableSet()
        val scrollables = nodes().filter { it.isScrollable }
        for (list in scrollables) {
            var steps = 0
            while (steps++ < 20 && list.performAction(AccessibilityNodeInfo.ACTION_SCROLL_FORWARD)) {
                found += settledLabels()
            }
            while (steps-- > 0 && list.performAction(AccessibilityNodeInfo.ACTION_SCROLL_BACKWARD)) {
                settledLabels()
            }
        }
        return found
    }

    /**
     * The labels once a scroll animation has come to rest: two reads a frame apart agree. Every
     * read on the way is kept, so a row passing through the viewport is still counted.
     */
    private fun settledLabels(): Set<String> {
        val seen = mutableSetOf<String>()
        var previous: List<String>? = null
        val deadline = SystemClock.uptimeMillis() + 2_000
        while (SystemClock.uptimeMillis() < deadline) {
            InstrumentationRegistry.getInstrumentation().waitForIdleSync()
            val current = labels()
            seen += current
            if (current == previous) break
            previous = current
            SystemClock.sleep(SETTLE_MILLIS)
        }
        return seen
    }

    /** Requests the orientation and waits until the window's aspect matches it. */
    private fun orient(scenario: ActivityScenario<GalleryOpeningTestActivity>, landscape: Boolean) {
        scenario.onActivity { activity ->
            activity.requestedOrientation = if (landscape) {
                ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE
            } else {
                ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
            }
        }
        awaitCondition("The window must turn ${if (landscape) "landscape" else "portrait"}") {
            var matches = false
            scenario.onActivity { activity ->
                val decor = activity.window.decorView
                matches = decor.width > 0 && (decor.width > decor.height) == landscape
            }
            matches
        }
    }

    /** The activity window's bounds on screen minus the visible system bars. */
    private fun safeArea(scenario: ActivityScenario<GalleryOpeningTestActivity>): Rect {
        val area = Rect()
        scenario.onActivity { activity ->
            val decor = activity.window.decorView
            val origin = IntArray(2).also(decor::getLocationOnScreen)
            val insets = WindowInsetsCompat.toWindowInsetsCompat(decor.rootWindowInsets, decor)
                .getInsets(WindowInsetsCompat.Type.systemBars())
            area.set(
                origin[0] + insets.left,
                origin[1] + insets.top,
                origin[0] + decor.width - insets.right,
                origin[1] + decor.height - insets.bottom,
            )
        }
        return area
    }

    /** Arms a new session with IBIS already off, so setup opens on the calibration step. */
    private fun armWithIbisOff(host: FeatureHostFixture) {
        host.coordinator.setEnabled(true)
        host.coordinator.setHostEligible(true)
        host.coordinator.bind(host.adapter)
        host.adapter.connect(stabilization = GyroStabilizationState(mapOf("ibis" to "OFF"), null))
        awaitCondition("The session must arm on the calibration step") {
            val state = host.coordinator.state.value
            state.canCalibrate && state.setupSteps.singleOrNull() is GyroArmingStep.Calibration
        }
    }

    /**
     * Feeds one camera level and one steady phone reading at a time, each processed before the
     * next, until the ring matches [done]. The fake ring fills half a hold per in-zone reading.
     */
    private fun holdUntil(host: FeatureHostFixture, done: (GyroRingState) -> Boolean) {
        val deadline = SystemClock.uptimeMillis() + 15_000
        while (true) {
            val ring = host.coordinator.state.value.ring
            if (ring != null && done(ring)) return
            assertTrue("The ring must reach the wanted pose, last $ring", SystemClock.uptimeMillis() < deadline)
            val timestamp = SystemClock.elapsedRealtimeNanos() / 1e9
            host.adapter.emitLevel(LEVEL_DOWN, timestamp)
            SystemClock.sleep(40)
            host.sensors.emitSteady(timestamp)
            val settle = SystemClock.uptimeMillis() + 2_000
            while (host.coordinator.state.value.ring == ring && SystemClock.uptimeMillis() < settle) {
                SystemClock.sleep(10)
            }
        }
    }

    /** Back through the focused window, as the system back gesture or key delivers it. */
    private fun pressBack() {
        InstrumentationRegistry.getInstrumentation().sendKeyDownUpSync(KeyEvent.KEYCODE_BACK)
        InstrumentationRegistry.getInstrumentation().waitForIdleSync()
    }

    /** Saves the screen as [name].png under [SHOT_DIR] once the frame has settled. */
    private fun screenshot(name: String) {
        InstrumentationRegistry.getInstrumentation().waitForIdleSync()
        SystemClock.sleep(SETTLE_MILLIS)
        shell("screencap -p $SHOT_DIR/$name.png")
    }

    /** Runs one shell command as the shell user and waits for it by draining its output. */
    private fun shell(command: String) {
        val output = InstrumentationRegistry.getInstrumentation().uiAutomation.executeShellCommand(command)
        ParcelFileDescriptor.AutoCloseInputStream(output).use { it.readBytes() }
    }

    private fun kebab(name: String): String = name.lowercase().replace('_', '-')

    private companion object {
        /** Where the screenshots go; the emulator script pulls this folder. */
        const val SHOT_DIR = "/data/local/tmp/gyro-shots"

        /** About one frame plus a margin for the last draw before capturing. */
        const val SETTLE_MILLIS = 50L

        /** The camera's down vector the fake level reports. */
        val LEVEL_DOWN = GyroVector3(-1.0, 0.0, 0.0)
    }
}
