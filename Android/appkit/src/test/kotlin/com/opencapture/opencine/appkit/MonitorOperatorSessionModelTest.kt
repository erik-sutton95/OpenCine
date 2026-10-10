package com.opencapture.opencine.appkit

import com.opencapture.monitorui.settings.MonitorSettingsTab
import com.opencapture.opencine.core.ConnectedCamera
import com.opencapture.opencine.core.testing.FakeCameraSession
import com.opencapture.opencine.core.testing.lunaLike
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** Swift mirror: MonitorOperatorSessionModelTests, same scenarios over the real shell owner. */
@OptIn(ExperimentalCoroutinesApi::class)
class MonitorOperatorSessionModelTest {
    private data class Fixture(val model: MonitorOperatorSessionModel, val shell: ShellModel,
        val assist: MonitorAssistState, val display: MonitorDisplayPreferences)

    private fun TestScope.fixture(): Fixture {
        val display = MonitorDisplayPreferences(DisplayPreferencesMemory().storage,
            MonitorDisplayPreferences.Keys("legacy.Live", "legacy.Clean"))
        val assist = MonitorAssistState()
        val shell = ShellModel(Values.model(emptyList(), backgroundScope), MonitorControlModel(backgroundScope))
        return Fixture(MonitorOperatorSessionModel(shell, assist, display, backgroundScope), shell, assist, display)
    }

    @Test fun editedModePersistsWithoutChangingOtherMode() = runTest {
        val (model, _, _, display) = fixture()
        model.clean = MonitorDisplayChrome.liveDefaults
        model.toggle(MonitorDisplaySection.STATUS_BAR, MonitorDisplayMode.CLEAN)
        assertTrue(model.live.statusBar && display.live.statusBar)
        assertFalse(model.clean.statusBar || display.clean.statusBar)
        model.toggle(MonitorDisplaySection.RAIL_MEDIA, MonitorDisplayMode.LIVE)
        assertTrue(!display.live.railMedia && display.clean.railMedia)
    }

    @Test fun editorDoneReturnsToSettingsWithoutClosingBorrowedCamera() = runTest {
        val (model, shell, assist) = fixture()
        val camera = FakeCameraSession.lunaLike()
        var releases = 0
        shell.borrow(ConnectedCamera(Values.camera, camera)) { releases += 1 }
        val source = shell.state.value.monitor?.id
        shell.open(ShellModel.Cover.SETTINGS)
        model.beginEditing(MonitorDisplayMode.CLEAN)
        assertNull(shell.state.value.cover)
        assertTrue(assist.clean && model.editingMode == MonitorDisplayMode.CLEAN)
        model.finishEditing()
        assertEquals(ShellModel.Cover.SETTINGS, shell.state.value.cover)
        assertEquals(MonitorSettingsTab.DISPLAY, model.settingsTab)
        assertEquals(MonitorDisplayMode.CLEAN, model.returnedMode)
        assertNull(model.editingMode)
        model.close(); runCurrent()
        assertEquals(0, releases)
        assertEquals(source, shell.state.value.monitor?.id)
        assertTrue(camera.wire.isEmpty())
    }

    @Test fun editorForceMountAndSettingsEscapePreserveSavedVisibility() = runTest {
        val (model) = fixture()
        model.live = model.live.copy(railSettings = false, cameraValues = false)
        model.clean = model.clean.copy(railSettings = false)
        assertTrue(model.mounts(MonitorDisplaySection.RAIL_SETTINGS))
        assertFalse(model.mounts(MonitorDisplaySection.CAMERA_VALUES))
        model.beginEditing(MonitorDisplayMode.LIVE)
        assertTrue(model.mounts(MonitorDisplaySection.CAMERA_VALUES))
        assertFalse(model.live.cameraValues)
        model.finishEditing()
        assertFalse(model.mounts(MonitorDisplaySection.CAMERA_VALUES))
        assertTrue(model.mounts(MonitorDisplaySection.RAIL_SETTINGS))
    }

    @Test fun replacementCannotBeArmedByOldWake() = runTest {
        val (model) = fixture()
        model.synchronize("a"); runCurrent(); advanceTimeBy(200)
        model.synchronize("b"); runCurrent(); advanceTimeBy(350); runCurrent()
        assertFalse(model.interactive)
        advanceTimeBy(200); runCurrent()
        assertTrue(model.interactive)
    }

    @Test fun closeAndSameSourceReentryRetireEditorAndOldWake() = runTest {
        val (model) = fixture()
        model.synchronize("a"); runCurrent()
        model.beginEditing(MonitorDisplayMode.CLEAN); model.finishEditing(); model.close()
        assertTrue(model.interactive)
        assertNull(model.editingMode); assertNull(model.returnedMode)
        advanceTimeBy(300)
        model.synchronize("a"); runCurrent(); advanceTimeBy(250); runCurrent()
        assertFalse(model.interactive)
        advanceTimeBy(300); runCurrent()
        assertTrue(model.interactive)
    }

    @Test fun coversBorrowWithoutRestartingArmingOrEditorReturn() = runTest {
        val (model, shell) = fixture()
        model.synchronize("a"); runCurrent(); advanceTimeBy(550); runCurrent()
        model.beginEditing(MonitorDisplayMode.LIVE); model.finishEditing()
        shell.open(ShellModel.Cover.MEDIA); model.synchronize("a"); shell.dismissCover()
        assertTrue(model.interactive)
        assertEquals(MonitorDisplayMode.LIVE, model.returnedMode)
    }
}
