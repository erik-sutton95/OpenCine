package com.opencapture.opencine.dji

import com.opencapture.opencine.core.MonitorLayoutCapabilities
import com.opencapture.opencine.core.MonotonicInstant
import com.opencapture.opencine.vocabulary.CameraCommands
import com.opencapture.opencine.vocabulary.CameraModel
import com.opencapture.opencine.vocabulary.CameraStatus
import com.opencapture.opencine.vocabulary.ControlCapabilities
import com.opencapture.opencine.vocabulary.ControlCapabilityVectors
import com.opencapture.opencine.vocabulary.MonitorLayoutCapabilities
import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.time.Duration.Companion.milliseconds
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.runTest

/**
 * The Kotlin twin renders the same per-body control model as the Swift DJI integration
 * (`Fixtures/control-capabilities-dji.tsv`, written by Swift `ControlCapabilityFixtureTests`).
 * Each body arrives as the facade's model JSON (Swift `DjiNativeWire.cameraModelJSON`).
 */
class ControlCapabilityFixtureTest {
    /** The facade fields of each body, in the Swift export order (Swift catalogue facts). */
    private val bodies = listOf(
        wire("Osmo Pocket 4 Pro", "pocket", gimbal = true, captured = true, zoom = "1,3,6,12"),
        wire("Osmo Pocket 4", "pocket", gimbal = true, captured = true, zoom = "1,2,4"),
        wire("Osmo Pocket 3", "pocket", gimbal = true, captured = true, zoom = "1,2,4"),
        wire("Osmo Nano", "nano", captured = true),
        wire("Osmo Action 6", "other", captured = true, aperture = true),
        wire("Osmo Action 5 Pro", "other"),
        wire("Osmo Action 4", "other"),
        wire("Osmo 360", "other"),
    )

    private fun wire(name: String, family: String, gimbal: Boolean = false, captured: Boolean = false,
        aperture: Boolean = false, zoom: String = "1"): String =
        """{"name":"$name","family":"$family","hasGimbal":$gimbal,"supportsZoom":$gimbal,""" +
            """"supportsTapFocus":$gimbal,"supportsFocusMode":$gimbal,"usesCapturedLiveEnable":$captured,""" +
            """"supportsAperture":$aperture,"isAction6":$aperture,"zoomStops":[$zoom]}"""

    /** A linked, idle body in video mode, manual exposure, its capture port reporting a shutter list. */
    private fun TestScope.controls(json: String): Pair<String, ControlCapabilities> {
        val model = CameraModel.fromJson(json)
        val port = DjiCameraSessionAdapterTest.FakePort()
        port.state = port.state.copy(model = model)
        port.capture = DjiCaptureControlState(
            CameraStatus(shootingMode = CameraCommands.SHOOT_VIDEO, expoMode = CameraCommands.EXPO_MANUAL,
                availableShutterDenoms = listOf(50, 100)), model)
        val seam = DjiCameraSessionAdapter(port, backgroundScope) { MonotonicInstant(testScheduler.currentTime.milliseconds) }
        return model.name to seam.controlCapabilities()
    }

    @Test
    fun fixtureMatchesTheSwiftIntegration() = runTest {
        val rendered = ControlCapabilityVectors.document("dji", bodies.map { controls(it) })
        val fixture = File(System.getProperty("opencine.fixtures"), "control-capabilities-dji.tsv")
        assertEquals(fixture.readText(), rendered)
    }

    @Test
    fun layoutIsAViewOfTheModel() = runTest {
        val base = MonitorLayoutCapabilities(audio = true, clipDelete = true, clipStar = true, requiresInternetHop = true)
        for (json in bodies) {
            val model = CameraModel.fromJson(json)
            val port = DjiCameraSessionAdapterTest.FakePort()
            port.state = port.state.copy(model = model)
            port.capture = DjiCaptureControlState(CameraStatus(), model)
            val seam = DjiCameraSessionAdapter(port, backgroundScope) { MonotonicInstant(testScheduler.currentTime.milliseconds) }
            assertEquals(seam.layout(base), MonitorLayoutCapabilities(seam.controlCapabilities(), base), model.name)
        }
    }
}
