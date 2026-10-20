package com.opencapture.opencine.nikon

import com.opencapture.opencine.core.CapabilitySnapshot
import com.opencapture.opencine.core.SessionCloseReason
import com.opencapture.opencine.vocabulary.ControlCapabilities
import com.opencapture.opencine.vocabulary.ControlCapabilityVectors
import com.opencapture.opencine.vocabulary.MonitorHeaderAccent
import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlinx.coroutines.test.runTest

/**
 * The Kotlin twin renders the same control model as the Swift Nikon integration
 * (`Fixtures/control-capabilities-nikon.tsv`, written by Swift `NikonControlCapabilityFixtureTests`).
 */
class ControlCapabilityFixtureTest {
    /** A ZR in movie mode, exposure M, H.265 at 25p, idle, with its shutter and aperture lists read. */
    private val movie = CameraPropertySnapshot(
        iso = 800, isoAuto = false, exposureMode = "M", shutterMode = CameraShutterMode.SPEED,
        shutterSpeed = "1/50", iris = "f/2.8", whiteBalanceMode = "Auto", whiteBalanceKelvin = 5560,
        resolution = "3840x2160", frameRate = 25, codec = "H.265 10-bit MOV", batteryPercent = 80,
        captureSelector = "video",
        controlCapabilities = CameraControlCapabilities(
            isoValues = listOf("200", "800", "6400", "25600"),
            shutterValues = listOf("1/50", "1/100"),
            irisValues = listOf("f/2.8", "f/4"),
            whiteBalanceValues = listOf("Auto", "Natural auto", "Sunny", "2500K", "5560K", "10000K"),
        ),
    )

    @Test
    fun fixtureMatchesTheSwiftIntegration() = runTest {
        val seam = NikonOpenCineSession(NikonOpenCineSessionTest.FakeNikon(movie), backgroundScope)
        seam.refresh()
        val rendered = ControlCapabilityVectors.document("nikon", listOf("ZR movie" to seam.controlCapabilities()))
        val fixture = File(System.getProperty("opencine.fixtures"), "control-capabilities-nikon.tsv")
        assertEquals(fixture.readText(), rendered)
        seam.closeNow(SessionCloseReason.REQUESTED)
    }

    @Test
    fun theHeaderAccentsTheCodec() {
        val controls = ControlCapabilities.derive(CapabilitySnapshot(), NIKON_CAPTURE_PROFILE)
        assertEquals(MonitorHeaderAccent.CODEC, controls.headerAccent)
    }
}
