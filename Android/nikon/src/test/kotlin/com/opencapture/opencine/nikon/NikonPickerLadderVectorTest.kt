package com.opencapture.opencine.nikon

import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * The Kotlin half of `Fixtures/nikon-picker-ladders.tsv`. Swift owns the same ladders in
 * `Sources/OpenCineNikon/NikonPickerLadders.swift` and reads the same rows
 * (`NikonPickerLadderVectorTests`), so a ladder edited on one side only fails a test.
 */
class NikonPickerLadderVectorTest {
    private val rows: List<List<String>> =
        File(System.getProperty("opencine.fixtures"), "nikon-picker-ladders.tsv")
            .takeIf { it.isFile }
            ?.readLines()
            .orEmpty()
            .filter { it.isNotBlank() && !it.startsWith("#") }
            .map { it.split("\t") }

    private val ladders: Map<String, List<String>> =
        mapOf(
            "shutter.angle" to ShutterPickerPolicy.angleOptions,
            "shutter.speed" to ShutterPickerPolicy.speedOptions,
            "focus.afMode" to FocusPickerPolicy.afModeOptions,
            "focus.area" to FocusPickerPolicy.areaOptions,
            "focus.subject" to FocusPickerPolicy.subjectOptions,
            "still.iso" to StillPickerLadders.ISO_OPTIONS,
            "still.shutter" to StillPickerLadders.SHUTTER_OPTIONS,
            "still.iris" to StillPickerLadders.IRIS_OPTIONS,
            "still.drive" to StillPickerLadders.DRIVE_OPTIONS,
            "still.appTimer" to StillPickerLadders.APP_TIMER_OPTIONS,
            "still.focusMode" to StillPickerLadders.FOCUS_MODE_OPTIONS,
            "still.focusArea" to StillPickerLadders.FOCUS_AREA_OPTIONS,
            "still.focusSubject" to StillPickerLadders.FOCUS_SUBJECT_OPTIONS,
            "still.mode" to StillPickerLadders.MODE_OPTIONS,
            "still.userMode" to StillPickerLadders.USER_MODE_OPTIONS,
            "still.meter" to StillPickerLadders.METER_OPTIONS,
            "still.picture" to StillPickerLadders.PICTURE_OPTIONS,
            "still.area" to StillPickerLadders.AREA_OPTIONS,
            "still.size" to StillPickerLadders.SIZE_OPTIONS,
            "still.quality" to StillPickerLadders.QUALITY_OPTIONS,
            "still.nef" to StillPickerLadders.NEF_OPTIONS,
        )

    private val bases: Map<String, String> =
        mapOf(
            "shutter.angle" to ShutterPickerPolicy.ANGLE_BASE,
            "shutter.speed" to ShutterPickerPolicy.SPEED_BASE,
            "focus.afMode" to FocusPickerPolicy.AF_MODE_BASE,
            "focus.area" to FocusPickerPolicy.AREA_BASE,
            "focus.subject" to FocusPickerPolicy.SUBJECT_BASE,
        )

    @Test
    fun `every ladder matches the fixture`() {
        val fixture = rows.filter { it[0] == "ladder" }
        assertEquals(ladders.keys, fixture.map { it[1] }.toSet(), "fixture missing or a ladder unshared")
        for (row in fixture) assertEquals(row.drop(2), ladders[row[1]], row[1])
    }

    @Test
    fun `every base matches the fixture`() {
        val fixture = rows.filter { it[0] == "base" }
        assertEquals(bases.keys, fixture.map { it[1] }.toSet())
        for (row in fixture) {
            assertEquals(row[2], bases[row[1]], row[1])
            assertTrue(row[2] in ladders.getValue(row[1]), "${row[1]} base is off its ladder")
        }
    }

    @Test
    fun `tint labels match the fixture and parse back to clamped cells`() {
        val fixture = rows.filter { it[0] == "tint" }
        assertTrue(fixture.size >= 10, "fixture missing or truncated")
        for (row in fixture) {
            val ab = row[1].toInt()
            val gm = row[2].toInt()
            assertEquals(row[3], WhiteBalanceTint.label(ab, gm), "$ab,$gm")
            assertEquals(WhiteBalanceTint.clamp(ab) to WhiteBalanceTint.clamp(gm), WhiteBalanceTint.cellsFromLabel(row[3]))
        }
    }
}
