package com.opencapture.opencine.dji

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
}
