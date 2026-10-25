package com.opencapture.opencine.cameracontrols

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

/** Twin of the SwiftUI MonitorOperatorPicturePlateTests: same cases. */
class MonitorOperatorPicturePlateTest {
    private fun picture(waiting: Boolean, notice: MonitorOperatorPictureNotice? = null) =
        MonitorOperatorLivePicture(16f / 9f, waiting, vertical = false, flipped = false, recovering = false, notice = notice)

    @Test
    fun `the source's notice replaces the waiting plate's words`() {
        val notice = MonitorOperatorPictureNotice("No camera")
        assertEquals(MonitorOperatorPicturePlate.Notice(notice), picture(waiting = true, notice = notice).plate)
        assertEquals(MonitorOperatorPicturePlate.Notice(notice), picture(waiting = false, notice = notice).plate)
    }

    @Test
    fun `without a notice a waiting picture shows the waiting plate and a live one none`() {
        assertEquals(MonitorOperatorPicturePlate.Waiting, picture(waiting = true).plate)
        assertNull(picture(waiting = false).plate)
    }

    @Test
    fun `a notice has no detail and no spinner unless the source says so`() {
        val notice = MonitorOperatorPictureNotice("Connecting…")
        assertNull(notice.detail)
        assertEquals(false, notice.progress)
    }

    /** Hardware pass 4.1: a taken-over monitor showed "Reconnecting" over "Camera taken over". */
    @Test
    fun `the reconnecting pill follows recovery unless the source says otherwise`() {
        val follows = MonitorOperatorLivePicture(16f / 9f, false, vertical = false, flipped = false, recovering = true)
        assertEquals(true, follows.reconnecting)
        val takenOver = MonitorOperatorLivePicture(
            16f / 9f, false, vertical = false, flipped = false, recovering = true, reconnecting = false,
        )
        assertEquals(true, takenOver.recovering)
        assertEquals(false, takenOver.reconnecting)
    }
}
