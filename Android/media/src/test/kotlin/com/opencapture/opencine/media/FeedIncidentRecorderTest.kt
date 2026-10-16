package com.opencapture.opencine.media

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class FeedIncidentRecorderTest {
    @Test
    fun freshInputStaleOutputStartsAnOpenIncidentAndPersistsAJob() {
        val recorder = FeedIncidentRecorder { "inc-fresh" }
        recorder.beginSession(session())
        repeat(3) { index ->
            recorder.recordSnapshot(healthy(monotonic = index.toDouble()))
        }
        val job = recorder.recordSnapshot(staleOutput(monotonic = 3.0))
        assertNotNull(job)
        assertEquals(FeedIncidentPersistenceJob.Reason.STARTED, job.reason)
        assertEquals(FeedIncidentKind.FRESH_INPUT_STALE_OUTPUT, job.bundle.header.kind)
        assertEquals(FeedIncidentOutcome.OPEN, job.bundle.header.outcome)
        assertEquals("inc-fresh", job.bundle.header.incidentId)
        assertTrue(job.bundle.prelude.isNotEmpty())
        assertTrue(job.bundle.header.sourceRevision.contains("abc"))
    }

    @Test
    fun recoveredOutputCollectsAftermathThenCloses() {
        val recorder = FeedIncidentRecorder { "inc-rec" }
        recorder.beginSession(session())
        recorder.recordSnapshot(healthy(0.0))
        recorder.recordSnapshot(staleOutput(3.0))
        val recovered = recorder.recordSnapshot(healthy(4.0))
        assertEquals(FeedIncidentOutcome.RECOVERED, recovered?.bundle?.header?.outcome)
        assertTrue(recorder.isCollectingAftermath)
        val closed = recorder.recordSnapshot(healthy(4.0 + FeedIncidentBounds.AFTERMATH_SECONDS))
        assertNotNull(closed)
        assertNull(recorder.openHeader)
        assertTrue(closed.bundle.aftermath.isNotEmpty())
    }

    @Test
    fun exhaustedOutcomeSurvivesTheDisconnectThatFollows() {
        val recorder = FeedIncidentRecorder { "inc-exh" }
        recorder.beginSession(session())
        recorder.recordSnapshot(staleOutput(3.0))
        recorder.noteExhausted(5.0)
        val stale = staleOutput(6.0)
        val job = recorder.recordSnapshot(stale.copy(lifecycle = stale.lifecycle.copy(connected = false)))
        assertEquals(FeedIncidentOutcome.EXHAUSTED, job?.bundle?.header?.outcome)
        assertEquals(5.0, job?.bundle?.header?.endedAtMonotonic)
        assertNull(recorder.openHeader)
    }

    @Test
    fun operatorDisconnectDuringOpenIncidentIsUserEnded() {
        val recorder = FeedIncidentRecorder { "inc-user" }
        recorder.beginSession(session())
        recorder.recordSnapshot(staleOutput(3.0))
        assertEquals(FeedIncidentOutcome.USER_ENDED, recorder.endSession(4.0)?.bundle?.header?.outcome)
        recorder.beginSession(session())
        recorder.recordSnapshot(staleOutput(3.0))
        recorder.recordSnapshot(healthy(4.0))
        assertEquals(
            FeedIncidentOutcome.RECOVERED,
            recorder.endSession(5.0)?.bundle?.header?.outcome,
            "a disconnect during the aftermath keeps the observed recovery",
        )
    }

    @Test
    fun repairRecordsUseFixedTokens() {
        val recorder = FeedIncidentRecorder { "inc-rep" }
        recorder.beginSession(session())
        recorder.recordSnapshot(staleOutput(3.0))
        val job =
            recorder.recordRepair(
                FeedRepairRecord(3.1, "decoder", FeedRepairPhase.REQUESTED, "outputSilence"),
            )
        assertNotNull(job)
        val repair = job.bundle.repairs.single()
        assertEquals("decoder", repair.action)
        assertEquals(FeedRepairPhase.REQUESTED, repair.phase)
        assertEquals("outputSilence", repair.reason)
    }

    @Test
    fun missingAssistAgeIsNotAnAssistStall() {
        val snapshot =
            healthy(3.0).copy(
                rates = FeedIncidentRates(packetHz = 25.0, decodedOutputHz = 25.0, assistOutputHz = 0.0, presentHz = 25.0),
                ages =
                    FeedIncidentAges(
                        packetAge = 0.04,
                        decodedOutputAge = 0.04,
                        assistOutputAge = null,
                        presentAge = 0.04,
                    ),
            )
        val verdict = FeedIncidentClassifier.classify(snapshot)
        assertTrue(verdict.kind != FeedIncidentKind.ASSIST_STALLED)
        assertTrue(snapshot.rates.assistOutputHz == 0.0)
        assertTrue(snapshot.ages.assistOutputAge == null)
    }

    @Test
    fun neitherObservableStageIsNotHealthyExposure() {
        val snapshot =
            healthy(2.0).copy(
                lifecycle =
                    FeedIncidentLifecycle(
                        connected = true,
                        liveEstablished = true,
                        outputObservable = false,
                        presentationExpected = false,
                    ),
            )
        assertTrue(!FeedIncidentClassifier.isRecovered(snapshot))
        val recorder = FeedIncidentRecorder { "inc-exp" }
        recorder.beginSession(session())
        recorder.recordSnapshot(healthy(0.0))
        recorder.recordSnapshot(snapshot)
        assertEquals(0.0, recorder.healthyExposure, 0.001)
    }

    // Swift twin: FeedIncidentRecorderTests (OPENPOCKETCINE-IOS-2E event 1f04a311).
    @Test
    fun unobservableDecoderFailureIsADecoderErrorNotAPresentationStall() {
        val snapshot =
            healthy(30.0).copy(
                rates = FeedIncidentRates(decodeSubmitHz = 5.5, decodeAcceptHz = 5.4, decodedOutputHz = 5.4, presentHz = 10.9),
                ages =
                    FeedIncidentAges(
                        packetAge = 0.01, accessUnitAge = 0.01, decodeAcceptAge = 9.3,
                        decodedOutputAge = 9.3, presentAge = 9.3,
                    ),
                decoder =
                    FeedIncidentDecoder(errorClass = "nativeDecoder", errorCount = 2, decoderFailed = true, errorAge = 9.1),
                lifecycle = FeedIncidentLifecycle(connected = true, liveEstablished = true, outputObservable = false),
            )
        val verdict = FeedIncidentClassifier.classify(snapshot)
        assertEquals(FeedIncidentKind.DECODER_ERROR, verdict.kind)
        assertEquals(FeedIncidentFailingStage.DECODE_ACCEPT, verdict.failingStage)
    }

    // Swift twin (OPENPOCKETCINE-IOS-K event 0d4710fd): camera input stopped.
    @Test
    fun unobservableOutputWithStaleInputIsATransportStall() {
        val snapshot =
            healthy(10.0).copy(
                rates = FeedIncidentRates(),
                ages = FeedIncidentAges(packetAge = 4.7, accessUnitAge = 4.7, presentAge = 4.7),
                lifecycle = FeedIncidentLifecycle(connected = true, liveEstablished = true, outputObservable = false),
            )
        val verdict = FeedIncidentClassifier.classify(snapshot)
        assertEquals(FeedIncidentKind.TRANSPORT_STALL, verdict.kind)
        assertEquals(FeedIncidentFailingStage.PACKET, verdict.failingStage)
    }

    @Test
    fun unobservableOutputWithFreshInputStaysAPresentationStall() {
        val snapshot =
            healthy(10.0).copy(
                rates = FeedIncidentRates(packetHz = 25.0, accessUnitHz = 25.0),
                ages = FeedIncidentAges(packetAge = 0.04, accessUnitAge = 0.04, presentAge = 4.0),
                lifecycle = FeedIncidentLifecycle(connected = true, liveEstablished = true, outputObservable = false),
            )
        val verdict = FeedIncidentClassifier.classify(snapshot)
        assertEquals(FeedIncidentKind.PRESENT_STALLED, verdict.kind)
        assertEquals(FeedIncidentFailingStage.PRESENTATION, verdict.failingStage)
    }

    @Test
    fun androidThermalStatusUsesTheIOSScale() {
        assertEquals("nominal", FeedIncidentThermal.fromAndroidThermalStatus(null))
        assertEquals("0", FeedIncidentThermal.fromAndroidThermalStatus(0))
        assertEquals("1", FeedIncidentThermal.fromAndroidThermalStatus(1))
        assertEquals("1", FeedIncidentThermal.fromAndroidThermalStatus(2))
        assertEquals("2", FeedIncidentThermal.fromAndroidThermalStatus(3))
        assertEquals("3", FeedIncidentThermal.fromAndroidThermalStatus(4))
        assertEquals("3", FeedIncidentThermal.fromAndroidThermalStatus(6))
        assertEquals("nominal", FeedIncidentThermal.fromAndroidThermalStatus(-1))
    }

    @Test
    fun sessionOriginIsCopiedAndDoesNotDowngrade() {
        val recorder = FeedIncidentRecorder { "inc-origin" }
        recorder.beginSession(
            session().copy(
                testSource = FeedIncidentTestSource.AUTOMATION,
                buildIdentity = "android-0123456789abcdef0123456789ab",
            ),
        )
        val job = recorder.recordSnapshot(staleOutput(monotonic = 3.0))
        assertEquals(FeedIncidentTestSource.AUTOMATION, job?.bundle?.header?.testSource)
        assertEquals("android-0123456789abcdef0123456789ab", job?.bundle?.header?.buildIdentity)
        recorder.noteTestSource(FeedIncidentTestSource.MANUAL)
        assertEquals(FeedIncidentTestSource.AUTOMATION, recorder.openHeader?.testSource)
        recorder.noteTestSource(FeedIncidentTestSource.FAULT_INJECTION)
        assertEquals(FeedIncidentTestSource.AUTOMATION, recorder.openHeader?.testSource)
    }

    @Test
    fun playbackSuppressesRecording() {
        val recorder = FeedIncidentRecorder { "inc-none" }
        recorder.beginSession(session())
        val job =
            recorder.recordSnapshot(
                staleOutput(3.0).copy(lifecycle = staleOutput(3.0).lifecycle.copy(playbackActive = true)),
            )
        assertNull(job)
        assertNull(recorder.openHeader)
    }

    private fun session() =
        FeedIncidentSessionContext(
            sessionId = "session-1",
            appVersion = "0.1.0",
            appBuild = "2",
            sourceRevision = "abc1234+",
            osName = "Android",
            osVersion = "16",
            hardwareClass = "Pixel",
            cameraFamily = "pocket",
        )

    private fun healthy(monotonic: Double) =
        FeedIncidentSnapshot(
            monotonicNow = monotonic,
            wallClockMs = 1_000L + (monotonic * 1000).toLong(),
            rates = FeedIncidentRates(packetHz = 25.0, accessUnitHz = 25.0, decodedOutputHz = 25.0, presentHz = 25.0),
            ages = FeedIncidentAges(packetAge = 0.04, accessUnitAge = 0.04, decodedOutputAge = 0.04, presentAge = 0.04),
            lifecycle = FeedIncidentLifecycle(connected = true, liveEstablished = true),
        )

    private fun staleOutput(monotonic: Double) =
        healthy(monotonic).copy(
            rates = FeedIncidentRates(packetHz = 25.0, accessUnitHz = 25.0, decodeSubmitHz = 25.0, decodedOutputHz = 0.0),
            ages = FeedIncidentAges(packetAge = 0.04, accessUnitAge = 0.04, decodedOutputAge = 5.0, presentAge = 5.0),
        )
}
