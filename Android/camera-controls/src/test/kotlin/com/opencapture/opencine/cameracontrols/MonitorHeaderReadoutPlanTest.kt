package com.opencapture.opencine.cameracontrols

import com.opencapture.opencine.appkit.MonitorDisplaySection
import com.opencapture.opencine.appkit.MonitorOperatorLiveReadout
import com.opencapture.opencine.vocabulary.MonitorHeaderAccent
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

private typealias HeaderReadout = MonitorOperatorLiveReadout<String, MonitorDisplaySection>

/**
 * The shared status-row readout plan: colour folds into the codec readout in portrait and
 * landscape, while a camera without a codec readout keeps its own colour target. Swift twin:
 * `MonitorHeaderReadoutPlanTests`.
 */
class MonitorHeaderReadoutPlanTest {
    private fun readout(id: String, title: String, value: String,
        section: MonitorDisplaySection? = null): HeaderReadout = HeaderReadout(id, title, value, section)

    private val format = readout("format", "Recording format", "6K · 25p")
    private val codec = readout("codec", "Codec", "R3D NE", MonitorDisplaySection.CODEC)
    private val color = readout("color", "Color mode", "D-Log2", MonitorDisplaySection.COLOR)
    private val mode = readout("mode", "Shooting mode", "Video")

    private fun plan(
        portrait: Boolean, photo: Boolean = false, format: List<HeaderReadout> = listOf(this.format, codec),
        color: HeaderReadout? = this.color, mode: HeaderReadout? = null,
        accent: MonitorHeaderAccent = MonitorHeaderAccent.SHOOTING_MODE,
        mounted: Set<MonitorDisplaySection> = MonitorDisplaySection.entries.toSet(),
    ): MonitorHeaderReadoutPlan<String, MonitorDisplaySection> =
        MonitorHeaderReadoutPolicy.plan(format, color, mode, accent, portrait, photo, mounted,
            MonitorDisplaySection.CODEC)

    @Test fun landscapeFoldsColorIntoTheCodecReadout() {
        val landscape = plan(portrait = false)
        assertTrue(landscape.foldsColor)
        assertNull(landscape.color)
        assertEquals("codec", landscape.combined?.codec?.id)
        assertEquals("Codec and color", landscape.accessibility(codec)?.first)
        assertEquals("R3D NE · D-Log2", landscape.accessibility(codec)?.second)
        assertNull(landscape.accessibility(format), "The format readout is not the combined control")
    }

    @Test fun portraitFoldsColorTheSameWay() {
        val portrait = plan(portrait = true)
        assertTrue(portrait.foldsColor)
        assertNull(portrait.color)
        assertNull(portrait.accessibility(codec), "Portrait keeps its existing spoken codec value")
    }

    @Test fun portraitPhotographyKeepsItsExistingStack() {
        val photo = plan(portrait = true, photo = true)
        assertFalse(photo.foldsColor)
        assertEquals("color", photo.color?.id)
        assertNull(photo.accessibility(codec))
    }

    @Test fun aCameraWithoutACodecReadoutKeepsItsColorTarget() {
        val colorOnly = plan(portrait = false, format = listOf(format))
        assertFalse(colorOnly.foldsColor)
        assertEquals("color", colorOnly.color?.id)
        assertNull(colorOnly.accessibility(color))
    }

    @Test fun anUnmountedCodecDoesNotFoldTheColor() {
        val hidden = plan(portrait = false, mounted = MonitorDisplaySection.entries.toSet() - MonitorDisplaySection.CODEC)
        assertEquals(listOf("format"), hidden.format.map { it.id })
        assertFalse(hidden.foldsColor)
        assertEquals("color", hidden.color?.id)
    }

    @Test fun anUnmountedColorIsNotFolded() {
        val hidden = plan(portrait = false, mounted = MonitorDisplaySection.entries.toSet() - MonitorDisplaySection.COLOR)
        assertFalse(hidden.foldsColor)
        assertNull(hidden.color)
        assertNull(hidden.accessibility(codec))
    }

    @Test fun shootingModeAccentStaysOnTheModeReadout() {
        val modeBody = plan(portrait = false, mode = mode)
        assertEquals("mode", modeBody.accented)
    }

    @Test fun aDeclaredCodecAccentMovesOffTheModeReadout() {
        val codecBody = plan(portrait = false, mode = mode, accent = MonitorHeaderAccent.CODEC)
        assertEquals("codec", codecBody.accented)
    }

    @Test fun aDeclaredCodecAccentWithoutAModeReadoutAccentsTheCodec() {
        // A body with no shooting-mode readout declares the codec.
        val codecBody = plan(portrait = false, accent = MonitorHeaderAccent.CODEC)
        assertEquals("codec", codecBody.accented)
    }

    @Test fun aShootingModeDeclarationNeverMovesTheAccentToTheCodec() {
        // Portrait (and a narrow landscape) draws no mode slot: a shooting-mode body stays
        // unaccented there, as before, instead of borrowing the codec.
        assertNull(plan(portrait = true).accented)
        assertNull(plan(portrait = false).accented)
    }

    @Test fun neitherReadoutLeavesTheHeaderUnaccented() {
        val none = plan(portrait = false, format = listOf(format))
        assertNull(none.accented)
    }
}
