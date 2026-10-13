package com.opencapture.opencine.cameracontrols

import com.opencapture.opencine.vocabulary.CameraCommands
import com.opencapture.opencine.vocabulary.LutCatalog
import com.opencapture.opencine.vocabulary.LutCategory
import com.opencapture.opencine.vocabulary.LutEntry
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

/** A2-60 (Android): the shared picker's typed library slot and the Camera / Creative / Custom tabs. */
class LutPickerLibraryTest {
    private val copy = LutPickerCopy(
        cameraTab = "SIMULATED", autoId = LutCatalog.OFFICIAL_AUTO, customHint = "Import here",
        noLookCaption = "No look", officialCubeCaption = "Official", cameraLooksCaption = "Camera looks",
    )
    private val camera = listOf(LutEntry(LutCatalog.OFFICIAL_AUTO, "Auto", LutCategory.CAMERA))
    private val custom = listOf(LutEntry(LutCatalog.customId("A.cube"), "A", LutCategory.CUSTOM, "A.cube"))

    private fun libraries(selection: String, picks: MutableList<String> = mutableListOf(),
        cleared: MutableList<LutEntry> = mutableListOf()) =
        lutPickerLibraries(copy, selection, camera, LutCatalog.creative, custom, CameraCommands.COLOR_NORMAL,
            null, false, onPick = { picks += it }, onImport = {}, onClear = { cleared += it })

    @Test
    fun theDjiStyleLooksAreThreeTypedLibraries() {
        val tabs = libraries(LutCatalog.OFFICIAL_AUTO)
        assertEquals(listOf("SIMULATED", "Creative", "Custom"), tabs.map { it.title })
        assertEquals(listOf(LutPickerLayout.DRUM, LutPickerLayout.DRUM, LutPickerLayout.FILES), tabs.map { it.layout })
        assertEquals(listOf(true, false, false), tabs.map { it.isCurrent })
        assertEquals(LutCatalog.OFFICIAL_AUTO, tabs[0].selectedId)
        assertEquals("creativeMono", tabs[1].drumId)
        assertEquals("Looks for the displayed picture", tabs[1].caption)
        assertEquals("Import here", tabs[2].empty?.hint)
    }

    @Test
    fun picksAndClearsGoThroughTheAppsCallbacks() {
        val picks = mutableListOf<String>()
        val cleared = mutableListOf<LutEntry>()
        val tabs = libraries(LutCatalog.customId("A.cube"), picks, cleared)
        assertEquals(listOf(false, false, true), tabs.map { it.isCurrent })
        assertEquals(LutCatalog.customId("A.cube"), tabs[2].selectedId)
        tabs[1].representative?.let(tabs[1].onSelect)
        tabs[2].onDelete?.invoke(tabs[2].entries.single())
        assertEquals(listOf("creativeMono"), picks)
        assertEquals(custom, cleared)
    }

    @Test
    fun theDrumRestsOnTheAppliedLookThenTheRepresentativeAndStarsMarkedLooks() {
        val looks = listOf(LutPickerEntry("a", "A"), LutPickerEntry("b", "B"))
        fun library(selected: String?, representative: LutPickerEntry?) = LutPickerLibrary(
            title = "SIMULATED", entries = looks, isCurrent = selected != null, selectedId = selected,
            onSelect = {}, representative = representative, markedIds = setOf("b"),
        )
        assertEquals("b", library("b", looks[0]).drumId)
        assertEquals("b", library(null, looks[1]).drumId)
        assertEquals("a", library(null, null).drumId)
        assertEquals("a", library("gone", null).drumId)
        assertEquals("★ B", library(null, null).label(looks[1]))
        assertEquals("A", library(null, null).label(looks[0]))
        assertNull(LutPickerLibrary("", emptyList(), false, null, {}).drumId)
    }
}
