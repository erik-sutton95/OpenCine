package com.opencapture.opencine.cameracontrols

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class FaceDetectionPumpTest {
    @Test
    fun tracksAtFeedRateThenIdlesAt10HzAfterASecondWithoutFaces() {
        assertEquals(40L, FaceDetectionPump.pace(0))
        assertEquals(40L, FaceDetectionPump.pace(FaceDetectionPump.IDLE_AFTER_EMPTY_RUNS - 1))
        assertEquals(100L, FaceDetectionPump.pace(FaceDetectionPump.IDLE_AFTER_EMPTY_RUNS))
    }

    @Test
    fun trackingTakesEveryFrameAndIdleOnlyNearItsNextRun() {
        assertTrue(FaceDetectionPump.wantsFrame(emptyRuns = 0, sinceLastRunMs = 0))
        val idle = FaceDetectionPump.IDLE_AFTER_EMPTY_RUNS
        assertFalse(FaceDetectionPump.wantsFrame(idle, sinceLastRunMs = 20))
        assertTrue(FaceDetectionPump.wantsFrame(idle, sinceLastRunMs = 60), "readback lands by the 100 ms run")
    }

    @Test
    fun onlyFacesWithEyeOrNoseStructureBecomeBoxes() {
        fun face(leftEye: Float?, rightEye: Float?, nose: Boolean, right: Int = 200) =
            DetectedFace(100, 40, right, 140, leftEye, rightEye, nose)
        val project = { faces: List<DetectedFace> -> FaceDetectionPump.project(faces, 320, 180) }
        val kept = project(listOf(face(125f, 175f, nose = false)))
        assertEquals(1, kept.size, "eyes a quarter of the box apart")
        assertEquals(100.0 / 320, kept.single().minX, 1e-9)
        assertTrue(project(listOf(face(145f, 150f, nose = true))).isEmpty(), "eyes closer than the minimum separation")
        assertEquals(1, project(listOf(face(125f, null, nose = true))).size, "one eye and a nose")
        assertTrue(project(listOf(face(125f, null, nose = false))).isEmpty(), "one eye without a nose")
        assertTrue(project(listOf(face(null, null, nose = true))).isEmpty(), "no eyes")
        assertTrue(project(listOf(face(102f, 105f, nose = true, right = 106))).isEmpty(), "narrower than 8 px")
    }
}
