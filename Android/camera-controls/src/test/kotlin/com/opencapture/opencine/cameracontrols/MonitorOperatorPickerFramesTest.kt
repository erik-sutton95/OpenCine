package com.opencapture.opencine.cameracontrols

import com.opencapture.monitorui.MonitorFieldLayout
import com.opencapture.monitorui.MonitorRect
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/** The one capture popup placement every app's camera panel opens in (moved from the Z app's wrapper tests). */
class MonitorOperatorPickerFramesTest {
    @Test
    fun portraitFillPickerClearsTheCaptureStripAndSystemRail() {
        val viewport = MonitorRect(0f, 0f, 400f, 800f)
        val zones = zones(values = MonitorRect(0f, 610f, 400f, 64f))

        val frame = monitorOperatorPickerFrame(viewport, zones, isPortrait = true)

        assertEquals(12f, frame.x)
        assertEquals(376f, frame.width)
        assertTrue(frame.y >= zones.status.y + zones.status.height + 8f)
        assertTrue(frame.y + frame.height <= zones.values.y - 10f)
        assertTrue(frame.y + frame.height < zones.system.y)
    }

    @Test
    fun landscapePickerAlignsToTheCaptureStripAndStaysOnScreen() {
        val viewport = MonitorRect(0f, 0f, 848f, 393f)
        val zones = landscapeZones(viewport.height)

        val frame = monitorOperatorPickerFrame(viewport, zones, isPortrait = false)

        val strip = zones.values
        assertEquals(strip.x, frame.x, 0.01f)
        assertEquals(strip.x + strip.width, frame.x + frame.width, 0.01f)
        assertTrue(frame.x >= viewport.x)
        assertTrue(frame.x + frame.width <= viewport.x + viewport.width)
    }

    @Test
    fun shortLandscapePickerIsTallEnoughForTheTintPad() {
        // A short phone in landscape (about 853 x 384 dp): header, the 180 dp pad cluster and the tabs.
        val viewport = MonitorRect(0f, 0f, 853f, 384f)
        val zones = zones(values = MonitorRect(430f, 320f, 363f, 48f)).copy(
            picture = MonitorRect(59f, 0f, 734f, 384f), status = MonitorRect(80f, 8f, 690f, 46f))

        val frame = monitorOperatorPickerFrame(viewport, zones, isPortrait = false)

        assertTrue(frame.height >= 300f, "picker height ${frame.height} must fit the tint pad")
        assertTrue(frame.y + frame.height <= zones.values.y - 10f)
    }

    @Test
    fun measuredCaptureBarTrailingAlignsTheLandscapePicker() {
        val viewport = MonitorRect(0f, 0f, 848f, 393f)
        val measured = MonitorRect(520f, 332f, 260f, 44f)

        val frame = monitorOperatorPickerFrame(viewport, landscapeZones(viewport.height), isPortrait = false,
            measuredCaptureBar = measured)

        assertEquals(measured.width, frame.width, 0.01f)
        assertEquals(measured.x + measured.width, frame.x + frame.width, 0.01f)
        assertEquals(measured.y - 10f, frame.y + frame.height, 0.01f)
    }

    @Test
    fun wideCaptureBarCentresThePickerAtThe420Cap() {
        val viewport = MonitorRect(0f, 0f, 900f, 400f)
        val zones = zones(values = MonitorRect(200f, 330f, 640f, 48f)).copy(status = MonitorRect(80f, 8f, 740f, 46f))
        val measured = MonitorRect(220f, 334f, 600f, 44f)

        val frame = monitorOperatorPickerFrame(viewport, zones, isPortrait = false, measuredCaptureBar = measured)

        assertEquals(420f, frame.width)
        assertEquals(measured.x + measured.width / 2f, frame.x + frame.width / 2f, 0.01f)
        assertEquals(measured.y - 10f, frame.y + frame.height, 0.01f)
    }

    @Test
    fun topPopdownDropsBelowTheStatusBarAt340() {
        val viewport = MonitorRect(0f, 0f, 848f, 393f)
        val zones = landscapeZones(viewport.height)

        val frame = monitorOperatorTopPickerFrame(viewport, zones)

        assertEquals(340f, frame.width)
        assertTrue(frame.y >= zones.status.y + zones.status.height + 8f - 0.1f)
        assertTrue(frame.x >= viewport.x + 8f)
        assertTrue(frame.x + frame.width <= viewport.x + viewport.width - 8f)
    }

    @Test
    fun topPopdownCentresUnderItsPillAndAWidePanelTakesTheRoomBelow() {
        val viewport = MonitorRect(0f, 0f, 848f, 393f)
        val zones = zones(values = MonitorRect(430f, 329f, 363f, 48f)).copy(status = MonitorRect(80f, 8f, 690f, 46f))
        val pill = MonitorRect(600f, 14f, 90f, 30f)

        val frame = monitorOperatorTopPickerFrame(viewport, zones, anchor = pill)
        assertEquals(pill.x + pill.width / 2f, frame.x + frame.width / 2f, 0.01f)
        assertEquals(pill.y + pill.height + 8f, frame.y, 0.01f)

        // A two-drum panel asks for 400 x 380 and gets the full space under the anchor.
        val pair = monitorOperatorTopPickerFrame(viewport, zones, preferredWidth = 400f, maximumHeight = 380f, anchor = pill)
        assertEquals(400f, pair.width)
        assertEquals(viewport.height - pair.y - 8f, pair.height, 0.01f)
        assertTrue(pair.height > 300f)
    }

    private fun landscapeZones(height: Float): MonitorFieldLayout =
        zones(values = MonitorRect(430f, 329f, 363f, 48f)).copy(
            picture = MonitorRect(59f, 0f, 734f, height), status = MonitorRect(80f, 8f, 690f, 46f))

    private fun zones(values: MonitorRect): MonitorFieldLayout {
        val empty = MonitorRect(0f, 0f, 0f, 0f)
        return MonitorFieldLayout(viewport = empty, picture = MonitorRect(0f, 52f, 400f, 622f),
            status = MonitorRect(0f, 0f, 400f, 44f), values = values, system = MonitorRect(0f, 690f, 400f, 100f),
            lock = MonitorRect(10f, 710f, 40f, 40f), gauges = empty, settings = MonitorRect(330f, 708f, 63f, 63f),
            media = MonitorRect(260f, 708f, 63f, 63f), record = MonitorRect(160f, 698f, 83f, 83f),
            display = MonitorRect(70f, 708f, 74f, 44f), assists = values, stick = empty, zoom = empty, gimbal = empty,
            headTrack = empty, aspectToggle = empty, focusReset = empty, portrait = false, tablet = false,
            fillsPicture = false, controlsFloor = 0f)
    }
}
