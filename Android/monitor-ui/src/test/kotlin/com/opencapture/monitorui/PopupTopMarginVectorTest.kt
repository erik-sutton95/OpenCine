package com.opencapture.monitorui

import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * The Kotlin half of `Fixtures/popup-top-margin.tsv`. Swift owns the one capture popup top margin
 * in `MonitorCapturePopupLayout.topMargin(safeTop:)` and reads the same rows
 * (`PopupTopMarginVectorTests`), so a popup opens at the same distance from the top everywhere.
 */
class PopupTopMarginVectorTest {
    private val rows: List<List<String>> =
        File(System.getProperty("opencine.fixtures"), "popup-top-margin.tsv")
            .takeIf { it.isFile }
            ?.readLines()
            .orEmpty()
            .filter { it.isNotBlank() && !it.startsWith("#") }
            .map { it.split("\t") }

    @Test fun marginReadsTheSharedRule() {
        val margins = rows.filter { it.first() == "margin" }
        assertTrue(margins.size > 5)
        for (row in margins) {
            assertEquals(row[2].toFloat(), MonitorLayoutPolicy.popupTopMargin(row[1].toFloat()), .001f, "$row")
        }
    }

    @Test fun landscapeDrawerAndTopPopupOpenAtTheMargin() {
        val landscapes = rows.filter { it.first() == "landscape" }
        assertTrue(landscapes.size > 3)
        for (row in landscapes) {
            val (width, height, safeTop, expected) = row.drop(1).map { it.toFloat() }
            val drawer = MonitorLayoutPolicy.bottomPanel(height, width, height, 0f, 0f, safeTop, 0f)
            val top = MonitorLayoutPolicy.topPanel(height, width, height, 0f, 0f, safeTop, 0f)
            assertEquals(expected, drawer.y, .001f, "$row")
            assertEquals(expected, top.y, .001f, "$row")
        }
    }
}
