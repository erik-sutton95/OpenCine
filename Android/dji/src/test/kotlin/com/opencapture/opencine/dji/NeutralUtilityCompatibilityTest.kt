package com.opencapture.opencine.dji

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

    @Test fun compatibilityPrivacyKeepsTheExistingNetworkAllowlistAndNestedReason() {
        assertEquals("ssid=OsmoPocket3-A1B2", FeedIncidentBuildIdentity.parse("ssid=OsmoPocket3-A1B2"))
        assertEquals("ssid=<redacted>", FeedIncidentPrivacy.token("ssid=CafeWiFi"))
        assertEquals("started", FeedIncidentPersistenceJob.Reason.STARTED.name.lowercase())
        assertEquals(mapOf("repairPhase" to "requested", "repairAction" to "decoder"), FeedIncidentNativeBreadcrumb.details(FeedRepairRecord(1.0, "decoder", FeedRepairPhase.REQUESTED)))
    }
}
