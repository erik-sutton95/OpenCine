package com.opencapture.opencine.media

import kotlin.test.Test
import kotlin.test.assertEquals

/** Kotlin twin of the Swift `envelopeNamesTriggerAndTheRepairThatRecovered` (FeedIncidentTests). */
class FeedIncidentExportTest {
    @Test
    fun envelopeNamesTriggerAndTheRepairThatRecovered() {
        val recorder = FeedIncidentRecorder { "inc-ladder" }
        recorder.beginSession(
            FeedIncidentSessionContext(
                sessionId = "session-1", appVersion = "0.1.0", appBuild = "2", sourceRevision = "abc",
                osName = "Android", osVersion = "16", hardwareClass = "Pixel", cameraFamily = "pocket",
            ),
        )
        val stale =
            FeedIncidentSnapshot(
                monotonicNow = 4.0,
                wallClockMs = 5_000L,
                rates = FeedIncidentRates(packetHz = 25.0, accessUnitHz = 25.0, decodeSubmitHz = 25.0, decodedOutputHz = 0.0),
                ages = FeedIncidentAges(packetAge = 0.04, accessUnitAge = 0.04, decodedOutputAge = 3.0, presentAge = 3.0),
                lifecycle = FeedIncidentLifecycle(connected = true, liveEstablished = true),
            )
        val bundle = recorder.recordSnapshot(stale)?.bundle ?: error("expected an incident")
        bundle.repairs =
            listOf(
                FeedRepairRecord(1.0, "enable", FeedRepairPhase.LOCALLY_SENT),
                FeedRepairRecord(4.0, "session", FeedRepairPhase.REQUESTED, "bleDropped"),
                FeedRepairRecord(5.0, "enable", FeedRepairPhase.LOCALLY_SENT),
                FeedRepairRecord(9.0, "endpoint", FeedRepairPhase.REQUESTED),
            )
        bundle.header.outcome = FeedIncidentOutcome.RECOVERED
        val envelope = FeedIncidentExport.envelope(bundle)
        assertEquals("bleDropped", envelope.trigger, "repairs before the incident are not its trigger")
        assertEquals("endpoint", envelope.recoveredBy)
        val resend = FeedRepairRecord(11.0, "enable", FeedRepairPhase.LOCALLY_SENT, FeedRepairRecord.FIRST_PICTURE_REASON)
        assertEquals(
            "endpoint",
            FeedIncidentExport.envelope(bundle.copy(repairs = bundle.repairs + resend)).recoveredBy,
            "a first-picture resend inside the endpoint repair does not take its credit",
        )

        assertEquals("0-2s", FeedIncidentExport.gapBucket(0.4))
        assertEquals("10-20s", FeedIncidentExport.gapBucket(16.3))
        assertEquals("20-40s", FeedIncidentExport.gapBucket(20.0))
        assertEquals("120s+", FeedIncidentExport.gapBucket(900.0))

        bundle.header.outcome = FeedIncidentOutcome.EXHAUSTED
        assertEquals("none", FeedIncidentExport.envelope(bundle).recoveredBy)
        bundle.repairs = emptyList()
        assertEquals("none", FeedIncidentExport.envelope(bundle).trigger)
    }

    /** Swift twin: `envelopeCarriesBackgroundAndIrapDiagnostics` (FeedIncidentTests). */
    @Test
    fun envelopeCarriesBackgroundAndIrapDiagnostics() {
        val recorder = FeedIncidentRecorder { "inc-diagnostics" }
        recorder.beginSession(
            FeedIncidentSessionContext(
                sessionId = "session-2", appVersion = "0.1.5", appBuild = "128", sourceRevision = "abc",
                osName = "Android", osVersion = "16", hardwareClass = "SM-A145F", cameraFamily = "nano",
            ),
        )
        fun stale(now: Double, foreground: Boolean, awaiting: Boolean) =
            FeedIncidentSnapshot(
                monotonicNow = now,
                rates = FeedIncidentRates(packetHz = 25.0, accessUnitHz = 25.0, decodeSubmitHz = 25.0),
                ages = FeedIncidentAges(packetAge = 0.04, accessUnitAge = 0.04, decodedOutputAge = now, presentAge = now),
                decoder = FeedIncidentDecoder(awaitingIrap = awaiting),
                lifecycle = FeedIncidentLifecycle(foreground = foreground, sceneActive = foreground,
                    connected = true, liveEstablished = true),
            )
        var bundle = recorder.recordSnapshot(stale(4.0, foreground = true, awaiting = false))?.bundle
            ?: error("expected an incident")
        var envelope = FeedIncidentExport.envelope(bundle)
        assertEquals("no", envelope.background)
        assertEquals("no", envelope.awaitingIrap)
        // Still open: an app switch, then back with the decoder waiting for a keyframe.
        recorder.recordSnapshot(stale(5.0, foreground = false, awaiting = false))
        recorder.recordSnapshot(stale(6.0, foreground = true, awaiting = true))
        bundle = recorder.exportOpen() ?: error("expected the incident to stay open")
        envelope = FeedIncidentExport.envelope(bundle)
        assertEquals("yes", envelope.background, "one off-screen snapshot inside the incident")
        assertEquals("yes", envelope.awaitingIrap, "the newest snapshot decides")
        // Snapshots before the incident opened are not its own.
        val early = bundle.copy(prelude = listOf(stale(1.0, foreground = false, awaiting = true)), during = emptyList())
        assertEquals("unknown", FeedIncidentExport.envelope(early).background)
        assertEquals("unknown", FeedIncidentExport.envelope(early).awaitingIrap)
    }
}
