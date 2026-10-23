package com.opencapture.opencine.media

import kotlin.test.Test
import kotlin.test.assertEquals

/** Kotlin twin of the Swift `envelopeNamesTriggerAndTheRepairThatRecovered` (FeedIncidentTests). */
class FeedIncidentExportTest {
    @Test
    fun decodeFlowKeepsFirstRateSampleUnknown() {
        val sampler = FeedIncidentRateSampler()
        val rates = sampler.sample(1.0, FeedIncidentStageCounts(decodeSubmit = 25, decodeAccept = 25))
        assertEquals("unknown", decodeFlowTag(rates))
    }

    @Test
    fun decodeFlowKeepsJPEGAcceptanceUnknown() {
        val sampler = FeedIncidentRateSampler()
        sampler.sample(1.0, FeedIncidentStageCounts(decodeSubmit = 0, decodedOutput = 0))
        val rates = sampler.sample(2.0, FeedIncidentStageCounts(decodeSubmit = 25, decodedOutput = 25))
        assertEquals(25.0, rates.observed?.decodedOutputHz)
        assertEquals(null, rates.observed?.decodeAcceptHz)
        assertEquals("unknown", decodeFlowTag(rates))
    }

    @Test
    fun decodeFlowUsesExplicitObservationsAndKeepsLegacyRates() {
        val cases = listOf(
            Triple(null, 25.0, "unknown"),
            Triple(0.0, 0.0, "idle"),
            Triple(25.0, 0.0, "rejecting"),
            Triple(25.0, 12.0, "partial"),
            Triple(25.0, 25.0, "flowing"),
        )
        for ((submit, accept, expected) in cases) {
            // Compatibility fields cannot override an explicit measurement or its absence.
            val rates = FeedIncidentRates(
                decodeSubmitHz = 25.0, decodeAcceptHz = 0.0,
                observed = FeedIncidentRateObservation(decodeSubmitHz = submit, decodeAcceptHz = accept),
            )
            assertEquals(expected, decodeFlowTag(rates))
        }
        assertEquals("flowing", decodeFlowTag(FeedIncidentRates(decodeSubmitHz = 25.0, decodeAcceptHz = 25.0)))
    }

    private fun decodeFlowTag(rates: FeedIncidentRates): String {
        val recorder = FeedIncidentRecorder { "inc-observed-decode" }
        recorder.beginSession(
            FeedIncidentSessionContext(
                sessionId = "session-1", appVersion = "0.1.5", appBuild = "120", sourceRevision = "abc",
                osName = "Android", osVersion = "16", hardwareClass = "SIMULATED", cameraFamily = "camera",
            ),
        )
        recorder.recordSnapshot(
            FeedIncidentSnapshot(
                monotonicNow = 3.0, wallClockMs = 3_000L, rates = rates,
                ages = FeedIncidentAges(accessUnitAge = 0.04, decodedOutputAge = 0.04, presentAge = 0.04),
                lifecycle = FeedIncidentLifecycle(connected = true, liveEstablished = true),
            ),
        )
        val bundle = recorder.noteUnexpectedDisconnect(4.0)?.bundle ?: error("expected an incident")
        return FeedIncidentExport.envelope(bundle).decodeFlow
    }

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
        // Not even one tick before the opening snapshot.
        val tickBefore = early.copy(prelude = listOf(stale(3.0, foreground = false, awaiting = true)))
        assertEquals("unknown", FeedIncidentExport.envelope(tickBefore).background)
        // A session drop stops the snapshots; the scene breadcrumb still marks the app switch.
        val inactive = FeedIncidentBreadcrumb(5.0, FeedIncidentBreadcrumbKind.SCENE_ACTIVITY, "inactive")
        assertEquals("yes", FeedIncidentExport.envelope(early.copy(breadcrumbs = listOf(inactive))).background)
        val before = inactive.copy(monotonicAt = 1.0)
        assertEquals("unknown", FeedIncidentExport.envelope(early.copy(breadcrumbs = listOf(before))).background)
        // An app switch during the aftermath (the picture was already back) is not this incident's.
        val ended = early.copy(header = early.header.copy(endedAtMonotonic = 4.5), breadcrumbs = listOf(inactive))
        assertEquals("unknown", FeedIncidentExport.envelope(ended).background)
    }

    /** Swift twin: `envelopeTagsTheDecodeStateTheIncidentOpenedOn` (FeedIncidentTests). */
    @Test
    fun envelopeTagsTheDecodeStateTheIncidentOpenedOn() {
        val recorder = FeedIncidentRecorder { "inc-decode" }
        recorder.beginSession(
            FeedIncidentSessionContext(
                sessionId = "session-1", appVersion = "0.1.5", appBuild = "120", sourceRevision = "abc",
                osName = "Android", osVersion = "10", hardwareClass = "Lenovo TB-X606F", cameraFamily = "pocket",
            ),
        )
        // PA-1V: an IllegalArgumentException on the decoder rode a disconnect incident.
        recorder.recordSnapshot(
            FeedIncidentSnapshot(
                monotonicNow = 3.0,
                wallClockMs = 3_000L,
                rates = FeedIncidentRates(packetHz = 25.0, accessUnitHz = 25.0, decodeSubmitHz = 25.0,
                    decodeAcceptHz = 0.0, decodedOutputHz = 25.0, presentHz = 25.0),
                ages = FeedIncidentAges(packetAge = 0.04, accessUnitAge = 0.04, decodedOutputAge = 0.04, presentAge = 0.04),
                decoder = FeedIncidentDecoder(errorClass = "IllegalArgumentException", errorCall = "getInputBuffer",
                    awaitingIrap = true, lastIrapAge = 7.0),
                lifecycle = FeedIncidentLifecycle(connected = true, liveEstablished = true),
            ),
        )
        val bundle = recorder.noteUnexpectedDisconnect(4.0)?.bundle ?: error("expected an incident")
        assertEquals("IllegalArgumentException", bundle.header.errorClass)
        val envelope = FeedIncidentExport.envelope(bundle)
        assertEquals("getInputBuffer", envelope.decoderCall)
        assertEquals("awaiting", envelope.keyframeWait)
        assertEquals("5-30s", envelope.irapAge)
        assertEquals("rejecting", envelope.decodeFlow)

        val renamed = bundle.prelude.last().let { it.copy(decoder = it.decoder.copy(errorCall = "somethingNew")) }
        assertEquals("other", FeedIncidentExport.envelope(bundle.copy(prelude = bundle.prelude.dropLast(1) + renamed)).decoderCall)
        assertEquals("none", FeedIncidentExport.envelope(bundle.copy(header = bundle.header.copy(errorClass = null))).decoderCall)
        val empty = FeedIncidentExport.envelope(bundle.copy(prelude = emptyList(), during = emptyList()))
        assertEquals(listOf("unknown", "unknown", "unknown"), listOf(empty.keyframeWait, empty.irapAge, empty.decodeFlow))

        assertEquals("never", FeedIncidentExport.irapAgeBucket(null))
        assertEquals("0-1s", FeedIncidentExport.irapAgeBucket(0.4))
        assertEquals("1-5s", FeedIncidentExport.irapAgeBucket(1.0))
        assertEquals("30s+", FeedIncidentExport.irapAgeBucket(30.0))
        assertEquals("idle", FeedIncidentExport.decodeFlow(0.0, 0.0))
        assertEquals("partial", FeedIncidentExport.decodeFlow(25.0, 12.0))
        assertEquals("flowing", FeedIncidentExport.decodeFlow(25.0, 25.0))
        assertEquals(
            DecoderErrorCall.entries.map { it.wire }.toSet() +
                setOf("createSession", "decodeFrame", "outputCallback", "displayLayer"),
            FeedIncidentExport.decoderCalls,
        )
    }
}
