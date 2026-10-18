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

    private fun TestScope.fixture(
        display: MonitorDisplayPreferences = MonitorDisplayPreferences(DisplayPreferencesMemory().storage,
            MonitorDisplayPreferences.Keys("legacy.Live", "legacy.Clean")),
    ): Fixture {
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

    @Test fun commandReceiptRetiresSynchronouslyOnLockOrOwnerReplacementOnly() = runTest {
        val (model) = fixture()
        model.synchronize("SIMULATED-first")
        val first = model.captureCommandRevision()
        model.locked = false
        model.settingsTab = MonitorSettingsTab.DISPLAY
        model.openSettings()
        assertTrue(first(), "Same lock value and unrelated popup state keep a released command current")
        model.locked = true
        assertFalse(first(), "No snapshot notification or coroutine turn may be required")
        model.locked = false
        assertFalse(first(), "Unlock does not revive old work")
        val second = model.captureCommandRevision()
        assertTrue(second())
        model.synchronize("SIMULATED-replacement")
        assertFalse(second())
        val third = model.captureCommandRevision()
        model.close()
        assertFalse(third())
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

    /** A2-84: Settings opens on the operator's last tab whichever entry opens it, and each tab keeps its
     * scroll offset across Edit view and the cover closing. */
    @Test fun settingsKeepTheLastTabAndEachTabsScrollOffset() = runTest {
        val (model, shell) = fixture()
        assertEquals(MonitorSettingsTab.LINK, model.settingsTab)
        assertTrue(model.settingsScrollOffsets.isEmpty())
        model.settingsTab = MonitorSettingsTab.STORAGE
        model.openSettings()
        assertEquals(ShellModel.Cover.SETTINGS, shell.state.value.cover)
        assertEquals(MonitorSettingsTab.STORAGE, model.settingsTab)
        model.settingsTab = MonitorSettingsTab.DISPLAY
        model.noteSettingsScroll(MonitorSettingsTab.DISPLAY, 240)
        model.noteSettingsScroll(MonitorSettingsTab.STORAGE, 60)
        model.beginEditing(MonitorDisplayMode.LIVE)
        assertNull(shell.state.value.cover)
        model.finishEditing()
        assertEquals(ShellModel.Cover.SETTINGS, shell.state.value.cover)
        assertEquals(MonitorSettingsTab.DISPLAY, model.settingsTab)
        assertEquals(mapOf(MonitorSettingsTab.DISPLAY to 240, MonitorSettingsTab.STORAGE to 60), model.settingsScrollOffsets)
        shell.dismissCover()
        model.openSettings()
        assertEquals(MonitorSettingsTab.DISPLAY, model.settingsTab)
        assertEquals(240, model.settingsScrollOffsets[MonitorSettingsTab.DISPLAY])
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

    /** A1-08: the one display owner. Pocket and Insta keep Live and Clean; a source that supplies a
     * camera dashboard declares Command, and a mode leaving the set falls back to the first. */
    @Test fun declaredModesCycleInOrderAndLockRefusesTheCycle() = runTest {
        val (model, _, assist) = fixture()
        assertEquals(listOf(MonitorDisplayMode.LIVE, MonitorDisplayMode.CLEAN), model.modes)
        assertEquals(MonitorDisplayMode.LIVE, model.mode)
        assertFalse(model.select(MonitorDisplayMode.COMMAND), "an undeclared mode is refused")
        model.declare(listOf(MonitorDisplayMode.LIVE, MonitorDisplayMode.CLEAN, MonitorDisplayMode.COMMAND))
        assertTrue(model.cycle() && model.mode == MonitorDisplayMode.CLEAN && assist.clean)
        assertTrue(model.cycle() && model.mode == MonitorDisplayMode.COMMAND && !assist.clean)
        model.locked = true
        assertFalse(model.cycle())
        assertEquals(MonitorDisplayMode.COMMAND, model.mode, "the lock holds the mode")
        model.locked = false
        assertTrue(model.cycle() && model.mode == MonitorDisplayMode.LIVE)
        assertTrue(model.select(MonitorDisplayMode.COMMAND))
        model.locked = true
        model.declare(listOf(MonitorDisplayMode.LIVE, MonitorDisplayMode.CLEAN))
        assertEquals(MonitorDisplayMode.LIVE, model.mode, "a capability that leaves overrides the lock")
    }

    @Test fun commandOwnsOnlyTheRailAndPersistsUnderItsKey() = runTest {
        val memory = DisplayPreferencesMemory()
        val keys = MonitorDisplayPreferences.Keys("z.live", "z.clean", "z.command")
        val (model) = fixture(MonitorDisplayPreferences(memory.storage, keys))
        model.declare(listOf(MonitorDisplayMode.LIVE, MonitorDisplayMode.CLEAN, MonitorDisplayMode.COMMAND))
        model.toggle(MonitorDisplaySection.STATUS_BAR, MonitorDisplayMode.COMMAND)
        model.toggle(MonitorDisplaySection.RAIL_MEDIA, MonitorDisplayMode.COMMAND)
        assertTrue(model.command.statusBar && !model.command.railMedia, "only rail sections are configurable")
        val reloaded = MonitorDisplayPreferences(memory.storage, keys)
        assertFalse(reloaded.command.railMedia)
        assertTrue(reloaded.hasStoredLayout(MonitorDisplayMode.COMMAND) && !reloaded.hasStoredLayout(MonitorDisplayMode.LIVE))
        assertTrue(model.select(MonitorDisplayMode.COMMAND) && model.mounts(MonitorDisplaySection.STATUS_BAR))
        assertFalse(model.mounts(MonitorDisplaySection.RAIL_MEDIA))
        model.beginEditing(MonitorDisplayMode.COMMAND)
        assertTrue(model.mounts(MonitorDisplaySection.RAIL_MEDIA) && model.mounts(MonitorDisplaySection.STATUS_BAR))
    }

    /** A1-50: the lock lives with the monitor lifetime in the one owner, not in a view. */
    @Test fun lockLastsOneMonitorLifetime() = runTest {
        val (model) = fixture()
        model.synchronize("a")
        model.locked = true
        model.synchronize("a")
        assertTrue(model.locked, "a cover or re-render keeps the lock")
        model.synchronize("b")
        assertFalse(model.locked, "a new monitor starts unlocked")
        model.locked = true
        model.close()
        assertFalse(model.locked)
    }
}
