package com.opencapture.opencine.motion

import com.opencapture.opencine.core.CapabilitySnapshot
import com.opencapture.opencine.core.MonitorLayoutCapabilities
import com.opencapture.opencine.core.MonotonicInstant
import com.opencapture.opencine.core.ObservationOrigin.CAMERA_REPORTED
import com.opencapture.opencine.core.ObservationOrigin.IMAGE_ESTIMATED
import com.opencapture.opencine.core.ObservationValidity
import com.opencapture.opencine.core.ObservedValue
import com.opencapture.opencine.core.SupportStatus
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlin.time.Duration.Companion.milliseconds
import kotlin.time.Duration.Companion.seconds

/** Swift suite `MotionSeamTests` (the parts with a Kotlin twin). */
class MotionSeamTest {
    private val reach = MotionBounds(pan = -48.0..225.0, tilt = -44.0..70.0)
    private val service = MotionCapabilities(
        setOf(MotionAxis.PAN, MotionAxis.TILT), MotionReferenceFrame.HANDLE, reach,
        maxRateDegPerSec = 60.0, feedbackMaxAge = 300.milliseconds, arrivalToleranceDeg = 0.5,
    )

    private fun pose(yaw: Double, pitch: Double, zoom: Double = 1.0) = GimbalWaypoint(yaw, pitch, zoom, -pitch)

    @Test
    fun targetsExistOnlyInsideTheDeclaredBounds() {
        assertNotNull(service.target(pose(0.0, 0.0)))
        assertNotNull(service.target(pose(225.0, 70.0)))
        for (outside in listOf(pose(225.01, 0.0), pose(-48.01, 0.0), pose(0.0, 70.01), pose(0.0, -44.01), pose(Double.NaN, 0.0))) {
            assertNull(service.target(outside))
        }
        assertNull(service.copy(axes = setOf(MotionAxis.PAN)).target(pose(0.0, 0.0)))
        assertEquals(1.0, GimbalWaypoint(0.0, 0.0, Double.NaN).zoom, "zoom is never below 1")
    }

    @Test
    fun feedbackMustBeFreshValidAndReportedByTheCamera() {
        val at = MonotonicInstant(10.seconds)
        val reading = ObservedValue(pose(10.0, 5.0), CAMERA_REPORTED, at)
        assertEquals(pose(10.0, 5.0), service.feedback(reading, at + 300.milliseconds))
        assertNull(service.feedback(reading, at + 301.milliseconds))
        assertNull(service.feedback(ObservedValue(pose(10.0, 5.0), IMAGE_ESTIMATED, at), at))
        val invalid = ObservedValue(pose(10.0, 5.0), CAMERA_REPORTED, at, ObservationValidity.Invalid("recentering"))
        assertNull(service.feedback(invalid, at))
        assertNull(service.feedback(ObservedValue.unknown, at))
    }

    /**
     * gimbal = the service drives pan and tilt; head tracking also needs a camera-reported pose.
     * No service is no gimbal; unknown pose support keeps the base.
     */
    @Test
    fun layoutProjectionDerivesGimbalAndHeadTracking() {
        val none = CapabilitySnapshot()
        val base = MonitorLayoutCapabilities(gimbal = true, headTracking = true, timecode = true)
        assertEquals(base, MonitorLayoutCapabilities(none, base), "motion not known yet")
        val absent = MonitorLayoutCapabilities(none, null, base)
        assertTrue(!absent.gimbal && !absent.headTracking && absent.timecode)

        val tracked = MonitorLayoutCapabilities(none, service.copy(pose = SupportStatus.SUPPORTED))
        assertTrue(tracked.gimbal && tracked.headTracking)
        val unknown = service.copy(pose = SupportStatus.UNKNOWN)
        assertFalse(MonitorLayoutCapabilities(none, unknown).headTracking)
        assertTrue(MonitorLayoutCapabilities(none, unknown, base).headTracking)
        val stickOnly = MonitorLayoutCapabilities(none, service.copy(pose = SupportStatus.UNSUPPORTED), base)
        assertTrue(stickOnly.gimbal && !stickOnly.headTracking)
        val panOnly = MonitorLayoutCapabilities(
            none, service.copy(axes = setOf(MotionAxis.PAN, MotionAxis.ZOOM), pose = SupportStatus.SUPPORTED), base,
        )
        assertTrue(!panOnly.gimbal && !panOnly.headTracking)
    }
}
