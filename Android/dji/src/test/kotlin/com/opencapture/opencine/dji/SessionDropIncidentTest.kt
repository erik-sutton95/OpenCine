package com.opencapture.opencine.dji

import com.opencapture.opencine.media.FeedIncidentAges
import com.opencapture.opencine.media.FeedIncidentBreadcrumb
import com.opencapture.opencine.media.FeedIncidentBundle
import com.opencapture.opencine.media.FeedIncidentExport
import com.opencapture.opencine.media.FeedIncidentLifecycle
import com.opencapture.opencine.media.FeedIncidentNativeBreadcrumb
import com.opencapture.opencine.media.FeedIncidentPersistenceJob
import com.opencapture.opencine.media.FeedIncidentRates
import com.opencapture.opencine.media.FeedIncidentRecorder
import com.opencapture.opencine.media.FeedIncidentSessionContext
import com.opencapture.opencine.media.FeedIncidentSnapshot
import com.opencapture.opencine.media.FeedIncidentSource
import com.opencapture.opencine.media.FeedRepairRecord
import com.opencapture.opencine.vocabulary.SessionRecoveryTrigger
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class SessionDropIncidentTest {
    /** The real recorder behind the host's source interface; keeps the newest persisted bundle. */
    private class RecorderSource : FeedIncidentSource {
        val recorder = FeedIncidentRecorder { "inc-session-drop" }
        var bundle: FeedIncidentBundle? = null
        private fun keep(job: FeedIncidentPersistenceJob?) { job?.let { bundle = it.bundle } }
        override fun endSession(nowSeconds: Double) = keep(recorder.endSession(nowSeconds))
        override fun ingestSnapshot(snapshot: FeedIncidentSnapshot) = keep(recorder.recordSnapshot(snapshot))
        override fun recordBreadcrumb(breadcrumb: FeedIncidentBreadcrumb) = recorder.recordBreadcrumb(breadcrumb)
        override fun recordRepair(repair: FeedRepairRecord) = keep(recorder.recordRepair(repair))
        override fun noteDecoderGeneration(generation: Int) = recorder.noteDecoderGeneration(generation)
        override fun noteSocketGeneration(generation: Int) = recorder.noteSocketGeneration(generation)
        override fun noteExhausted(nowSeconds: Double) = keep(recorder.noteExhausted(nowSeconds))
        override fun noteUnexpectedDisconnect(nowSeconds: Double) = keep(recorder.noteUnexpectedDisconnect(nowSeconds))
    }

    private fun live(now: Double) =
        FeedIncidentSnapshot(
            monotonicNow = now,
            wallClockMs = (now * 1000).toLong(),
            rates = FeedIncidentRates(packetHz = 30.0, accessUnitHz = 30.0, decodeSubmitHz = 30.0,
                decodedOutputHz = 30.0, presentHz = 30.0),
            ages = FeedIncidentAges(packetAge = 0.03, accessUnitAge = 0.03, decodeAcceptAge = 0.03,
                decodedOutputAge = 0.03, presentAge = 0.03),
            lifecycle = FeedIncidentLifecycle(connected = true, liveEstablished = true),
        )

    /** PA-A shape: a BLE drop, a long reconnect, the picture back with no feed repair at all. */
    @Test fun sessionDropNamesItsTriggerAndTheSessionRungThatRecovered() {
        val source = RecorderSource()
        source.recorder.beginSession(
            FeedIncidentSessionContext(
                sessionId = "session-1", appVersion = "0.1.5", appBuild = "128", sourceRevision = "1b329d07109d",
                osName = "Android", osVersion = "16", hardwareClass = "SM-S938B", cameraFamily = "pocket",
            ),
        )
        for (t in 1..5) source.ingestSnapshot(live(t.toDouble()))
        SessionDropIncident.record(source, SessionRecoveryTrigger.BLE_DROPPED, nowSeconds = 6.0)
        // Session recovery reconnects; the picture is back later with no feed repair in between.
        source.ingestSnapshot(live(296.0))
        val bundle = source.bundle ?: error("expected the disconnect to open an incident")
        val envelope = FeedIncidentExport.envelope(bundle)
        assertEquals("unexpectedDisconnect", envelope.kind)
        assertEquals("recovered", envelope.grouping.outcome)
        assertEquals("bleDropped", envelope.trigger)
        assertEquals("session", envelope.recoveredBy)
    }

    @Test fun everyTriggerIsInTheClosedRepairReasonVocabulary() {
        for (trigger in SessionRecoveryTrigger.entries) {
            val reason = SessionDropIncident.reason(trigger)
            assertEquals(reason, FeedIncidentNativeBreadcrumb.closed("repairReason", reason), "$trigger -> $reason")
        }
        assertTrue(SessionDropIncident.reason(SessionRecoveryTrigger.FEED_WATCHDOG) == "feedWatchdogStall")
    }

    @Test fun noSourceRecordsNothing() {
        SessionDropIncident.record(null, SessionRecoveryTrigger.SOFTAP_LOST, 1.0)
    }
}
