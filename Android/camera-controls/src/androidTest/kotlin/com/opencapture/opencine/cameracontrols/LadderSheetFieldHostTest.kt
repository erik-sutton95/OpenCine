package com.opencapture.opencine.cameracontrols

import android.os.Bundle
import android.os.SystemClock
import android.view.accessibility.AccessibilityNodeInfo
import androidx.activity.compose.setContent
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.opencapture.opencine.appkit.MonitorCaptureChoice
import com.opencapture.opencine.appkit.MonitorCaptureField
import com.opencapture.opencine.appkit.MonitorCapturePresentation
import com.opencapture.opencine.appkit.MonitorControlModel
import com.opencapture.opencine.appkit.captureField
import com.opencapture.opencine.core.CameraTimecode
import com.opencapture.opencine.core.ISOValue
import com.opencapture.opencine.core.SettingKey
import com.opencapture.opencine.core.SettingValue
import com.opencapture.opencine.core.testing.FakeCameraSession
import com.opencapture.opencine.core.testing.lunaLike
import com.opencapture.opencine.vocabulary.CaptureLadder
import com.opencapture.opencine.vocabulary.LadderSheetPresentation
import com.opencapture.opencine.vocabulary.LadderTab
import com.opencapture.opencine.vocabulary.LadderWrite
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

/** SIMULATED camera, real retained editor, production field ladder and native drum input. */
@RunWith(AndroidJUnit4::class)
class LadderSheetFieldHostTest {
    @Test fun observationsPreviewAndDismissalDoNotWriteWhileFilteredNativeInputCommitsOnce() = withField { fixture, scenario ->
        assertTrue(fixture.field.choices.any { it.label == "400" })
        assertEquals(listOf("200", "800"), fixture.choices.map { it.label })
        node("200", action = progressAction)
        scenario.onActivity { fixture.assertNoWrites() }
        val report = CameraTimecode(1, 2, 3, 0)
        scenario.onActivity { fixture.camera.cameraReportsTimecode(report) }
        awaitCondition(scenario, "Control must consume the camera's external report") {
            fixture.control.timecode.value == report
        }
        node("200", action = progressAction)
        scenario.onActivity {
            fixture.assertNoWrites()
            fixture.previewPosition = 1f; fixture.previewSelection = "800"
        }
        val preview = node("800", forbiddingAction = progressAction)
        assertFalse("A readout preview must expose no native commit action", preview.performAction(progressAction, progress(1f)))
        scenario.onActivity { fixture.assertNoWrites(); fixture.presented = false }
        awaitCondition(scenario, "The field ladder must actually be dismissed") { !fixture.presented }
        awaitNodes("Dismissed ladder must leave the native tree") { nodes -> nodes.none { it.contentDescription?.toString() in listOf("200", "800") } }
        scenario.onActivity {
            fixture.assertNoWrites()
            fixture.previewPosition = null; fixture.previewSelection = null; fixture.presented = true
        }
        assertTrue(node("200", action = progressAction).performAction(progressAction, progress(1f)))
        awaitCondition(scenario, "Native input must reach exactly one admitted backend command") { fixture.camera.wire.size == 1 }
        node("800", action = progressAction)
        scenario.onActivity {
            assertEquals(listOf("set ${SettingValue.Iso(ISOValue.Manual(800))}"), fixture.camera.wire)
            assertEquals(listOf(SettingValue.Iso(ISOValue.Manual(800))), fixture.commits)
            assertTrue("Typed field must not fall through the label-write route", fixture.labelWrites.isEmpty())
            assertEquals(SettingValue.Iso(ISOValue.Manual(800)), fixture.control.shown(SettingKey.ISO))
            assertEquals(SettingValue.Iso(ISOValue.Manual(200)), fixture.control.state.value.snapshot?.value(SettingKey.ISO)?.value)
            fixture.camera.cameraReportsStatus()
        }
        InstrumentationRegistry.getInstrumentation().waitForIdleSync()
        scenario.onActivity {
            assertEquals("Later reports cannot replay the edit", 1, fixture.camera.wire.size)
            assertEquals(1, fixture.commits.size)
        }
    }

    @Test fun replacingTheSourceRejectsTheRetainedEditorAndCallback() = withField { fixture, scenario ->
        node("200", action = progressAction)
        val successor = FakeCameraSession.lunaLike()
        scenario.onActivity {
            successor.cameraReportsStatus()
            fixture.control.bind(successor)
        }
        awaitCondition(scenario, "New camera must retire the original editor") {
            fixture.control.captureField(SettingKey.ISO)?.editor != fixture.field.editor
        }
        val retired = node("200", forbiddingAction = progressAction)
        assertFalse(retired.performAction(progressAction, progress(1f)))
        scenario.onActivity {
            fixture.assertNoWrites()
            assertTrue("Stale editor cannot target the successor camera", successor.wire.isEmpty())
            assertNotEquals(fixture.field.editor, fixture.control.captureField(SettingKey.ISO)?.editor)
        }
    }

    @Test fun emptyCapturedChoicesDoNotWidenToTheCameraOrPresentationDomain() = withField(emptyChoices = true) { fixture, scenario ->
        assertTrue(fixture.field.choices.size > 2)
        awaitNodes("Actual empty ladder header must be mounted") { nodes -> nodes.any { it.text?.toString() == "ISO field" } }
        awaitNodes("Empty captured domain cannot publish an adjustable fallback") { nodes -> nodes.none { node -> node.actionList.any { it.id == progressAction } } }
        scenario.onActivity {
            fixture.assertNoWrites()
            assertEquals(SettingValue.Iso(ISOValue.Manual(200)), fixture.control.shown(SettingKey.ISO))
        }
    }

    private fun withField(emptyChoices: Boolean = false, block: (FieldFixture, ActivityScenario<GalleryOpeningTestActivity>) -> Unit) {
        ActivityScenario.launch(GalleryOpeningTestActivity::class.java).use { scenario ->
            lateinit var fixture: FieldFixture
            scenario.onActivity { activity ->
                fixture = FieldFixture(emptyChoices)
                activity.setContent { fixture.ladder() }
            }
            try { block(fixture, scenario) } finally {
                scenario.onActivity { fixture.control.unbind(); fixture.scope.cancel() }
            }
        }
    }

    private class FieldFixture(emptyChoices: Boolean) {
        val camera = FakeCameraSession.lunaLike().also { it.cameraReportsStatus() }
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
        val control = MonitorControlModel(scope).also { it.bind(camera) }
        val field = requireNotNull(control.captureField(SettingKey.ISO)).also { check(it.isEditable) }
        val choices = if (emptyChoices) emptyList() else field.choices.filter { it.label in listOf("200", "800") }
        var previewPosition by mutableStateOf<Float?>(null)
        var previewSelection by mutableStateOf<String?>(null)
        var presented by mutableStateOf(true)
        val commits = mutableListOf<SettingValue>()
        val labelWrites = mutableListOf<LadderWrite<SettingKey>>()

        @Composable fun ladder() {
            val state by control.state.collectAsState()
            if (presented) LadderSheet(
                LadderSheetPresentation("ISO field", "Sensitivity", listOf(
                    LadderTab("ISO", SettingKey.ISO, CaptureLadder(field.label, field.choices.map { it.label }), applyOnActivate = false))),
                enabled = true, onWrite = { labelWrites += it }, onClose = {}, control = control,
                host = LadderSheetHost(0,
                    previewSelection ?: state.snapshot?.let { control.shown(SettingKey.ISO) }?.let(MonitorCapturePresentation::label),
                    LadderSheetDrum.Field(field, choices), previewPosition = previewPosition,
                    onSelectTab = {}, onCommitted = { commits += it }))
        }

        fun assertNoWrites() {
            assertTrue(camera.wire.isEmpty())
            assertTrue(commits.isEmpty())
            assertTrue(labelWrites.isEmpty())
            assertTrue(control.state.value.pending.isEmpty())
        }
    }

    private fun progress(value: Float) = Bundle().apply { putFloat(AccessibilityNodeInfo.ACTION_ARGUMENT_PROGRESS_VALUE, value) }
    private val progressAction get() = AccessibilityNodeInfo.AccessibilityAction.ACTION_SET_PROGRESS.id

    private fun node(label: String, action: Int? = null, forbiddingAction: Int? = null): AccessibilityNodeInfo {
        var found: AccessibilityNodeInfo? = null
        awaitNodes("Actual field node $label with required native input state must be published") { nodes ->
            found = nodes.firstOrNull { node -> node.contentDescription?.toString() == label &&
                (action == null || node.actionList.any { it.id == action }) &&
                (forbiddingAction == null || node.actionList.none { it.id == forbiddingAction }) }
            found != null
        }
        return requireNotNull(found)
    }

    private fun awaitNodes(message: String, predicate: (List<AccessibilityNodeInfo>) -> Boolean) {
        val automation = InstrumentationRegistry.getInstrumentation().uiAutomation
        fun tree(node: AccessibilityNodeInfo): List<AccessibilityNodeInfo> = listOf(node) +
            (0 until node.childCount).flatMap { index -> node.getChild(index)?.let(::tree).orEmpty() }
        val deadline = SystemClock.uptimeMillis() + 5_000
        while (SystemClock.uptimeMillis() < deadline) {
            automation.rootInActiveWindow?.let { if (predicate(tree(it))) return }
            SystemClock.sleep(20)
        }
        assertTrue(message, automation.rootInActiveWindow?.let { predicate(tree(it)) } == true)
    }

    private fun awaitCondition(scenario: ActivityScenario<GalleryOpeningTestActivity>, message: String, predicate: () -> Boolean) {
        val deadline = SystemClock.uptimeMillis() + 5_000
        var met = false
        while (SystemClock.uptimeMillis() < deadline) {
            scenario.onActivity { met = predicate() }
            if (met) return
            SystemClock.sleep(20)
        }
        assertTrue(message, met)
    }
}
