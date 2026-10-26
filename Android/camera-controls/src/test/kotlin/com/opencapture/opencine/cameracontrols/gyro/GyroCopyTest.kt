package com.opencapture.opencine.cameracontrols.gyro

import com.opencapture.opencine.gyro.GyroCalibrationBlock
import com.opencapture.opencine.gyro.GyroCalibrationInvalidation
import com.opencapture.opencine.gyro.GyroNotice
import com.opencapture.opencine.gyro.GyroPillKind
import com.opencapture.opencine.gyro.GyroTakeStatus
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse

/**
 * The shared gyro screens' copy table. Swift twin: `GyroCopyTests`; the Swift
 * `GyroCopyParityTests` reads GyroCopy.kt and checks the same literals.
 */
class GyroCopyTest {
    private val statuses: List<GyroTakeStatus> = listOf(
        GyroTakeStatus.Recording,
        GyroTakeStatus.MountMoved(75.0),
        GyroTakeStatus.CutShort,
        GyroTakeStatus.SmallGaps,
        GyroTakeStatus.NotCalibrated,
        GyroTakeStatus.Ready,
    )

    /** Every string the shared gyro screens can show, except the Details sample rate. */
    private fun primaryCopy(): List<String> {
        val all = mutableListOf(
            GyroCopy.pillArmed, GyroCopy.pillRecording, GyroCopy.pillSaving, GyroCopy.pillGaps,
            GyroCopy.pillError, GyroCopy.pillOffline, GyroCopy.pillMountMoved,
            GyroCopy.ibisTitle, GyroCopy.ibisReason, GyroCopy.ibisLens, GyroCopy.ibisTurnOff,
            GyroCopy.ibisKeep, GyroCopy.phoneMount, GyroCopy.calibrateTitle, GyroCopy.calibrateBody,
            GyroCopy.getStarted,
            GyroCopy.useLastCalibration, GyroCopy.cancel, GyroCopy.stepCounter(1), GyroCopy.holdHint,
            GyroCopy.retry, GyroCopy.completeTitle, GyroCopy.completeBody, GyroCopy.done,
            GyroCopy.holdProgressA11y(25), GyroCopy.stepDoneA11y(1), GyroCopy.driftTitle,
            GyroCopy.driftQuestion, GyroCopy.recalibrate, GyroCopy.notNow, GyroCopy.logsTitle,
            GyroCopy.tip, GyroCopy.today, GyroCopy.yesterday, GyroCopy.select, GyroCopy.shareCount(2),
            GyroCopy.shareLog, GyroCopy.separator, GyroCopy.deleteTitle, GyroCopy.delete,
            GyroCopy.emptyTitle, GyroCopy.emptyBody, GyroCopy.turnOnGyro, GyroCopy.calibratedMount,
            GyroCopy.notCalibrated, GyroCopy.details, GyroCopy.startsLabel, GyroCopy.smoothnessLabel,
            GyroCopy.sampleRateLabel, GyroCopy.startOffset(0.12), GyroCopy.length(61.0),
            GyroCopy.settingsCalibrate,
        )
        for (kind in GyroPillKind.entries) {
            all += GyroCopy.pill(kind)
            all += GyroCopy.pillA11y(kind, false)
            all += GyroCopy.pillA11y(kind, true)
        }
        all += (0..2).map { GyroCopy.step(it) }
        all += GyroCalibrationBlock.entries.map { GyroCopy.block(it) }
        all += GyroCalibrationInvalidation.entries.map { GyroCopy.invalidation(it) }
        all += statuses.flatMap {
            listOf(GyroCopy.status(it), GyroCopy.verdict(it), GyroCopy.smoothness(it))
        }
        all += GyroNotice.entries.map { GyroCopy.notice(it) }
        return all
    }

    @Test
    fun noEmDash() {
        for (text in primaryCopy() + listOf(GyroCopy.sampleRate(200.0))) {
            assertFalse(text.contains('\u2014'), text)
        }
    }

    @Test
    fun noPrimaryCopyContainsDegreesOrMilliseconds() {
        for (text in primaryCopy()) {
            val words = text.lowercase().split(Regex("[^\\p{L}]+"))
            assertFalse(text.contains('\u00B0'), text)
            assertFalse("deg" in words || "degrees" in words, text)
            assertFalse("ms" in words || "hz" in words, text)
        }
    }

    @Test
    fun lengthAndOffsetFormatting() {
        assertEquals("0:48", GyroCopy.length(48.4))
        assertEquals("2:10", GyroCopy.length(130.0))
        assertEquals("62:05", GyroCopy.length(3725.0))
        assertEquals("0:00", GyroCopy.length(-3.0))
        assertEquals("35791394:07", GyroCopy.length(1e300))
        assertEquals("0:00", GyroCopy.length(-1e300))
        assertEquals("0.12 s before REC", GyroCopy.startOffset(0.123))
        assertEquals("0.30 s after REC", GyroCopy.startOffset(-0.3))
        assertEquals("Mount moved at 1:15", GyroCopy.status(GyroTakeStatus.MountMoved(75.0)))
        assertEquals("200 Hz", GyroCopy.sampleRate(199.6))
        assertEquals("0 Hz", GyroCopy.sampleRate(Double.NaN))
        assertEquals("0 Hz", GyroCopy.sampleRate(Double.POSITIVE_INFINITY))
    }

    @Test
    fun sampleRateMatchesSwiftRoundingAndSaturation() {
        val cases = listOf(
            Double.NaN to "0 Hz", Double.POSITIVE_INFINITY to "0 Hz", Double.NEGATIVE_INFINITY to "0 Hz",
            Double.MAX_VALUE to "2147483647 Hz", -Double.MAX_VALUE to "-2147483648 Hz",
            2147483646.5 to "2147483647 Hz", -2147483648.5 to "-2147483648 Hz",
            199.5 to "200 Hz", -199.5 to "-199 Hz",
            0.5 to "1 Hz", -0.5 to "0 Hz", -0.5000001 to "-1 Hz", 0.0 to "0 Hz",
            Math.nextDown(0.5) to "0 Hz", Math.nextUp(-0.5) to "0 Hz",
        )
        for ((rate, expected) in cases) {
            assertEquals(expected, GyroCopy.sampleRate(rate), "rate: $rate")
        }
    }

    @Test
    fun statusTexts() {
        assertEquals("REC", GyroCopy.status(GyroTakeStatus.Recording))
        assertEquals("Cut short", GyroCopy.status(GyroTakeStatus.CutShort))
        assertEquals("Small gaps", GyroCopy.status(GyroTakeStatus.SmallGaps))
        assertEquals("Not calibrated", GyroCopy.status(GyroTakeStatus.NotCalibrated))
        assertEquals("Ready", GyroCopy.status(GyroTakeStatus.Ready))
        assertEquals("No gaps", GyroCopy.smoothness(GyroTakeStatus.Ready))
        assertEquals("No gaps", GyroCopy.smoothness(GyroTakeStatus.MountMoved(1.0)))
        assertEquals("Small gaps", GyroCopy.smoothness(GyroTakeStatus.SmallGaps))
        assertEquals("Cut short", GyroCopy.smoothness(GyroTakeStatus.CutShort))
        assertEquals("Still recording", GyroCopy.smoothness(GyroTakeStatus.Recording))
    }

    @Test
    fun pillA11yAppendsTheIbisWarning() {
        assertEquals("Gyro armed. IBIS is still on", GyroCopy.pillA11y(GyroPillKind.ARMED, true))
        assertEquals("", GyroCopy.pillA11y(GyroPillKind.HIDDEN, true))
    }

    @Test
    fun verdictLeadsWithReadyForGyroflow() {
        assertEquals("Ready for Gyroflow", GyroCopy.verdict(GyroTakeStatus.Ready))
        assertEquals("Still recording", GyroCopy.verdict(GyroTakeStatus.Recording))
        assertEquals("Small gaps", GyroCopy.verdict(GyroTakeStatus.SmallGaps))
    }
}
