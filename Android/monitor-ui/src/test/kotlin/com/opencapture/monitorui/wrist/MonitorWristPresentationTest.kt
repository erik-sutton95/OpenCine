package com.opencapture.monitorui.wrist

import kotlin.test.*
import com.opencapture.opencine.media.BatteryFraction
import com.opencapture.opencine.media.BatterySteps

class MonitorWristPresentationTest {
    private val live = MonitorWristPresentation(3, true, MonitorWristConnection.CONNECTED, true,
        false, false, null, true, 0, "09:30:00:01", null, "64 GB · 40%", "Card")
    @Test fun roundAndSquareGeometryPreservesOriginalWristNumbers() {
        assertEquals(MonitorWristLayout(16f, 18f, 23.529411f), monitorWristLayout(true, 192f))
        assertEquals(MonitorWristLayout(16f, 18f, 24f), monitorWristLayout(true, 196f))
        assertEquals(MonitorWristLayout(6f, 10f, 24f), monitorWristLayout(false, 192f))
        assertEquals(14f, monitorWristLayout(true, 80f).timecodeFontSizeSp)
        assertEquals(8f, monitorWristSingleLineFontSize("Long storage description", 60f))
    }
    @Test fun capturedRecordRejectsBusyReplacementAndRecordingChange() {
        val held = requireNotNull(live.recordToken)
        assertTrue(live.isCurrent(held))
        assertFalse(live.copy(sendingCommand = true).isCurrent(held))
        assertFalse(live.copy(recording = true).isCurrent(held))
        assertFalse(live.copy(sourceRevision = 5).isCurrent(held))
        assertNull(live.copy(phoneReachable = false).recordToken)
        assertNull(live.copy(connection = MonitorWristConnection.NO_CAMERA).recordToken)
    }
    @Test fun unknownBatteryRemainsAbsentAndMeasuredZeroRemainsZero() {
        assertEquals(0, live.measuredBattery)
        assertNull(live.copy(batteryPercent = null).measuredBattery)
        assertNull(live.copy(batteryPercent = -1).measuredBattery)
        assertNull(live.copy(connection = MonitorWristConnection.NO_CAMERA).measuredBattery)
    }
    @Test fun frameTimecodeAndStorageStatusRetainTheirExactPrecedence() {
        val copy = MonitorWristCopy()
        assertEquals("09:30:00:01", live.timecodeLabel(copy))
        assertEquals("10:20:30:04", live.copy(frameTimecode = "10:20:30:04").timecodeLabel(copy))
        assertEquals("64 GB · 40%", live.storageLabel(copy))
        assertEquals("Card", live.copy(storageStatus = null).storageLabel(copy))
        assertEquals(copy.unavailable, live.copy(storageStatus = null, media = " ").storageLabel(copy))
    }
    @Test fun placeholderFollowsTruthfulConnectionAndActualPictureFacts() {
        val copy = MonitorWristCopy()
        assertNull(live.placeholder(copy))
        assertEquals(copy.openOnPhone, live.copy(phoneReachable = false).placeholder(copy))
        assertEquals(copy.waitingForPhone, live.copy(connection = null).placeholder(copy))
        assertEquals(copy.noCamera, live.copy(connection = MonitorWristConnection.NO_CAMERA).placeholder(copy))
        assertEquals(copy.feedPaused, live.copy(feedLive = false).placeholder(copy))
        assertEquals(copy.waitingForPreview, live.copy(hasPicture = false).placeholder(copy))
    }
    @Test fun sourceReplacementAndReentryNeverReplayOldTallyOrErrorFeedback() {
        val feedback = MonitorWristFeedback()
        assertNull(feedback.update(live))
        assertEquals(MonitorWristFeedbackEvent.RECORD_STARTED, feedback.update(live.copy(recording = true)))
        assertNull(feedback.update(live.copy(sourceRevision = 4)))
        assertEquals(MonitorWristFeedbackEvent.COMMAND_FAILED, feedback.update(live.copy(sourceRevision = 4, commandMessage = "Refused")))
        feedback.retire()
        assertNull(feedback.update(live.copy(sourceRevision = 4, commandMessage = "Refused")))
    }
    private fun typedBattery(reading: com.opencapture.opencine.media.BatteryReading?, exhausted: Boolean? = null) =
        MonitorWristPresentation(3, true, MonitorWristConnection.CONNECTED, true,
            false, false, null, true, 80, "09:30:00:01", null, null, null,
            batteryReading = reading, batteryExhausted = exhausted)

    @Test fun commonReadingPreservesDeclaredPrecisionAndIndependentExhaustion() {
        assertEquals(BatteryFraction(0.68), typedBattery(BatteryFraction(0.68)).measuredBatteryReading)
        for (exhausted in listOf(false, true)) {
            val gauge = typedBattery(BatterySteps(1, 4), exhausted)
            assertEquals(BatterySteps(1, 4), gauge.measuredBatteryReading)
            assertEquals(exhausted, gauge.batteryExhausted)
            assertEquals(gauge.measuredBatteryReading, gauge.copy(batteryPercent = 99).measuredBatteryReading)
            assertNull(gauge.copy(connection = MonitorWristConnection.NO_CAMERA).measuredBatteryReading)
        }
        assertEquals(BatteryFraction(0.0), typedBattery(BatteryFraction(0.0)).measuredBatteryReading)
        assertNull(typedBattery(null).measuredBatteryReading)
        assertNull(typedBattery(BatteryFraction(Double.NaN)).measuredBatteryReading)
        assertNull(typedBattery(BatterySteps(1, 0)).measuredBatteryReading)
        assertEquals(BatteryFraction(0.41), live.copy(batteryPercent = 41).measuredBatteryReading)
    }

}
