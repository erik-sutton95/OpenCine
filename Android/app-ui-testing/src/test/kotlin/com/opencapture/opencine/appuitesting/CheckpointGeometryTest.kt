package com.opencapture.opencine.appuitesting

import kotlin.test.Test
import kotlin.test.assertEquals

class CheckpointGeometryTest {
    private val window = Box(0, 0, 1000, 2000)
    private val hidden = listOf("system bar" to Box(0, 0, 1000, 100), "display cutout" to Box(450, 20, 550, 80))

    private fun control(tag: String, box: Box, window: Int = 1, covered: Boolean = false) =
        CheckpointControl(tag, box, window, this.window, covered)

    @Test
    fun controlsInsideTheSafeAreaAndApartPass() {
        val controls = listOf(control("monitor.a", Box(10, 200, 110, 300)), control("monitor.b", Box(120, 200, 220, 300)))
        assertEquals(emptyList(), CheckpointGeometry.violations("x", controls, hidden, "monitor.", 1, 3))
    }

    @Test
    fun aControlUnderTheStatusBarOrPastTheWindowFails() {
        val under = control("monitor.top", Box(10, 50, 110, 150))
        val past = control("monitor.edge", Box(950, 500, 1050, 600))
        assertEquals(
            listOf(
                "x: monitor.top [10,50][110,150] lies under the system bar [0,0][1000,100]",
                "x: monitor.edge [950,500][1050,600] leaves its window [0,0][1000,2000]",
            ),
            CheckpointGeometry.violations("x", listOf(under, past), hidden, "monitor.", 1, 3),
        )
        // Without hidden areas (the behavior scenarios) only the window counts.
        assertEquals(
            listOf("x: monitor.edge [950,500][1050,600] leaves its window [0,0][1000,2000]"),
            CheckpointGeometry.violations("x", listOf(under, past), emptyList(), "monitor.", 1, 3),
        )
    }

    @Test
    fun theCornersBesideACutoutAreUsableButTheCutoutIsNot() {
        val hidden = listOf("display cutout" to Box(450, 20, 550, 80))
        val beside = control("monitor.corner", Box(20, 20, 120, 120))
        val under = control("monitor.hole", Box(400, 40, 480, 120))
        val coveredUnder = control("monitor.paged", Box(400, 40, 480, 120), covered = true)
        assertEquals(
            listOf("x: monitor.hole [400,40][480,120] lies under the display cutout [450,20][550,80]"),
            CheckpointGeometry.violations("x", listOf(beside, under, coveredUnder), hidden, "monitor.", 1, 3),
        )
    }

    @Test
    fun onePixelOfToleranceAndSlackIsAllowed() {
        val edge = control("monitor.edge", Box(0, 99, 100, 199))
        val touching = control("monitor.next", Box(97, 120, 200, 220))
        assertEquals(emptyList(), CheckpointGeometry.violations("x", listOf(edge, touching), hidden, "monitor.", 1, 3))
    }

    @Test
    fun overlapsCountOnlyForUncoveredOperableControlsOfOneWindow() {
        val a = control("monitor.a", Box(100, 500, 300, 700))
        val b = control("monitor.b", Box(200, 600, 400, 800))
        val otherWindow = control("monitor.c", Box(200, 600, 400, 800), window = 2)
        val covered = control("monitor.d", Box(200, 600, 400, 800), covered = true)
        val inert = control("monitor.rail", Box(200, 600, 400, 800))
        assertEquals(
            listOf("x: monitor.a [100,500][300,700] overlaps monitor.b [200,600][400,800]"),
            CheckpointGeometry.violations("x", listOf(a, b, otherWindow, covered), hidden, "monitor.", 1, 3),
        )
        assertEquals(
            emptyList(),
            CheckpointGeometry.violations("x", listOf(a, inert), hidden, "monitor.chromeEdit.", 1, 3),
        )
    }

    @Test
    fun evidenceNamesMatchTheSwiftKit() {
        assertEquals(
            "OpenZCine-phone411dp-landscape-GalleryRoundTrip-after-return",
            CheckpointGeometry.evidenceName("OpenZCine", "phone411dp", true, "GalleryRoundTrip", "after-return"),
        )
        assertEquals("a-b-portrait-c-d_e", CheckpointGeometry.evidenceName("a", "b", false, "c", "d/e"))
    }
}
