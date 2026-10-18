package com.opencapture.opencine.vocabulary

import com.opencapture.opencine.media.FeedIncidentAges
import com.opencapture.opencine.media.FeedIncidentBuildIdentity
import com.opencapture.opencine.media.FeedIncidentClassifier
import com.opencapture.opencine.media.FeedIncidentDecoder
import com.opencapture.opencine.media.FeedIncidentFailingStage
import com.opencapture.opencine.media.FeedIncidentKind
import com.opencapture.opencine.media.FeedIncidentLifecycle
import com.opencapture.opencine.media.FeedIncidentNativeBreadcrumb
import com.opencapture.opencine.media.FeedIncidentPersistenceJob
import com.opencapture.opencine.media.FeedIncidentPrivacy
import com.opencapture.opencine.media.FeedIncidentRates
import com.opencapture.opencine.media.FeedIncidentSnapshot
import com.opencapture.opencine.media.FeedIncidentSuppression
import com.opencapture.opencine.media.FeedRepairPhase
import com.opencapture.opencine.media.FeedRepairRecord
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

class NeutralUtilityCompatibilityTest {
    @Test fun oldCaptureValuesKeepFallbackAndWireEncoding() {
        assertEquals(180.0, ShutterAngle.degrees(0, 0))
        assertEquals(180.0, ShutterAngle.degrees(48, 0))
        assertNull(com.opencapture.opencine.media.ShutterAngle.degrees(48, 0))
        for (thirds in EvComp.MIN_THIRDS..EvComp.MAX_THIRDS) {
            val value = EvComp(thirds)
            assertEquals(value, EvComp.fromRaw(value.rawValue))
            assertEquals(value, EvComp.fromLabel(value.label))
            assertEquals(0x10 + thirds, value.rawValue)
        }
    }

    @Test fun malformedCaptureLabelsStayUnknownAtCompatibilityPaths() {
        assertNull(ShutterAngle.parse("NaN°"))
        assertNull(EvComp.fromLabel("+1431655766.0"))
        assertNull(EvComp.fromLabel("-9223372036854775807.0"))
    }

    @Test fun oldIncidentClassifierProjectsAllFailureAndLifecycleInputs() {
        val snapshot = FeedIncidentSnapshot(
            monotonicNow = 20.0,
            rates = FeedIncidentRates(packetHz = 25.0, decodeSubmitHz = 25.0),
            ages = FeedIncidentAges(packetAge = 0.04, decodedOutputAge = 4.0),
            decoder = FeedIncidentDecoder(errorAge = 1.0, lastSuccessfulOutputAge = 2.0),
            lifecycle = FeedIncidentLifecycle(connected = true, liveEstablished = true),
        )
        val verdict = FeedIncidentClassifier.classify(snapshot)
        assertEquals(FeedIncidentKind.DECODER_ERROR, verdict.kind)
        assertEquals(FeedIncidentFailingStage.DECODE_ACCEPT, verdict.failingStage)
        assertTrue(verdict.shouldRecord)
        assertEquals(FeedIncidentSuppression.PLAYBACK, FeedIncidentClassifier.classify(snapshot.copy(lifecycle = snapshot.lifecycle.copy(playbackActive = true))).suppression)
        assertEquals(4.0, FeedIncidentPrivacy.gapSeconds(snapshot, FeedIncidentFailingStage.DECODED_OUTPUT))
    }

    @Test fun compatibilityPrivacyRedactsEveryNetworkAndKeepsNestedReason() {
        assertEquals("ssid=<redacted>", FeedIncidentBuildIdentity.parse("ssid=OsmoPocket3-A1B2", PrivacyRedactor::redact))
        assertEquals("ssid=<redacted>", FeedIncidentPrivacy.token("ssid=CafeWiFi", redact = PrivacyRedactor::redact))
        assertEquals("started", FeedIncidentPersistenceJob.Reason.STARTED.name.lowercase())
        assertEquals(mapOf("repairPhase" to "requested", "repairAction" to "decoder"), FeedIncidentNativeBreadcrumb.details(FeedRepairRecord(1.0, "decoder", FeedRepairPhase.REQUESTED)))
    }
}
