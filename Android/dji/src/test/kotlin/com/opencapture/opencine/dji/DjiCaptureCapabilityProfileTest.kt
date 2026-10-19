package com.opencapture.opencine.dji

import com.opencapture.opencine.vocabulary.CameraCommands
import com.opencapture.opencine.vocabulary.CameraModel
import com.opencapture.opencine.vocabulary.CaptureNativeISOCapabilities
import kotlin.test.Test
import kotlin.test.assertEquals

/** Swift `DJICaptureProfileTests`: what the DJI integration declares for each body. */
class DjiCaptureCapabilityProfileTest {
    /**
     * Behavior audit PAA-200..203 / PAB-D-49..51: every Osmo body answered the Auto ISO ceiling
     * GET/SET and hopped to the new curve's native ISO in the standalone apps, so the DJI profile
     * declares both services. A drone declares nothing (unknown).
     */
    @Test
    fun osmoBodiesDeclareNativeIsoServices() {
        val bodies = listOf(
            djiBodyProfile("Osmo Pocket 3"), djiBodyProfile("Osmo Pocket 4"),
            djiBodyProfile("Osmo Pocket 4 Pro"), djiBodyProfile("Osmo Nano", family = "nano"),
            djiBodyProfile("Osmo Action 6", family = "other"),
        )
        for (body in bodies) {
            assertEquals(CaptureNativeISOCapabilities(hop = true, ceiling = true),
                DjiCaptureCapabilityProfile.make(body).nativeISO, body.name)
        }
        val drone = CameraModel(name = "DJI Neo", isDrone = true)
        assertEquals(CaptureNativeISOCapabilities(), DjiCaptureCapabilityProfile.make(drone).nativeISO)
    }

    /**
     * Behavior audit PAA-342: a named Pocket 3 / Pocket 4 / Pocket 4 Pro cycles its own zoom stops
     * whatever a saved record's `zoomStops` says (the Swift profile already derives them by name);
     * only an unnamed pocket-family body follows the saved list.
     */
    @Test
    fun namedPocketsKeepTheirZoomStopsOverASavedList() {
        fun stops(name: String, saved: List<Double>, mode: Int = CameraCommands.SHOOT_VIDEO): List<Double> {
            val model = CameraModel(name = name, family = "pocket", supportsZoom = true, zoomStops = saved)
            return model.copy(captureProfile = DjiCaptureCapabilityProfile.make(model))
                .activeZoomStops(CameraCommands.RES_1080, mode)
        }
        assertEquals(listOf(1.0, 2.0, 4.0), stops("Osmo Pocket 3", listOf(1.0, 2.0)))
        assertEquals(listOf(1.0, 2.0, 4.0), stops("Osmo Pocket 4", listOf(1.0, 3.0)))
        assertEquals(listOf(1.0, 3.0, 6.0, 12.0), stops("Osmo Pocket 4 Pro", listOf(1.0, 2.0)))
        assertEquals(listOf(1.0, 3.0), stops("Osmo Pocket 4 Pro", listOf(1.0, 2.0), CameraCommands.SHOOT_SLOWMO))
        assertEquals(listOf(1.0, 2.0), stops("DJI Osmo camera", listOf(1.0, 2.0)))
    }
}
