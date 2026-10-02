package com.opencapture.opencine.media

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class NeutralIncidentPolicyTest {
    private fun live() = FeedIncidentSnapshot(
        monotonicNow = 20.0,
        rates = FeedIncidentRates(packetHz = 25.0, accessUnitHz = 25.0, decodeSubmitHz = 25.0),
        ages = FeedIncidentAges(packetAge = 0.04, decodedOutputAge = 4.0, presentAge = 4.0),
        lifecycle = FeedIncidentLifecycle(connected = true, liveEstablished = true),
    )

    @Test fun freshInputStaleOutputAndDecoderFailureKeepTheirEstablishedStages() {
        val stale = live()
        assertEquals(FeedIncidentKind.FRESH_INPUT_STALE_OUTPUT, FeedIncidentClassifier.classify(stale).kind)
        assertEquals(FeedIncidentFailingStage.DECODE_ACCEPT, FeedIncidentClassifier.classify(stale).failingStage)
        val error = stale.copy(decoder = FeedIncidentDecoder(errorAge = 1.0, lastSuccessfulOutputAge = 2.0))
        assertEquals(FeedIncidentKind.DECODER_ERROR, FeedIncidentClassifier.classify(error).kind)
        assertFalse(FeedIncidentClassifier.isCurrentDecoderFailure(error.decoder.copy(errorAge = 3.0)))
    }

    @Test fun playbackDisconnectedBackgroundAndNeverEstablishedAreSuppressed() {
        val input = live()
        val cases = listOf(
            input.lifecycle.copy(playbackActive = true) to FeedIncidentSuppression.PLAYBACK,
            input.lifecycle.copy(connected = false) to FeedIncidentSuppression.DISCONNECTED,
            input.lifecycle.copy(foreground = false) to FeedIncidentSuppression.BACKGROUND,
            input.lifecycle.copy(sceneActive = false) to FeedIncidentSuppression.BACKGROUND,
            input.lifecycle.copy(liveEstablished = false) to FeedIncidentSuppression.NEVER_ESTABLISHED,
        )
        for ((lifecycle, reason) in cases) {
            val snapshot = input.copy(lifecycle = lifecycle)
            assertEquals(reason, FeedIncidentClassifier.classify(snapshot).suppression)
            assertFalse(FeedIncidentClassifier.isRecovered(snapshot))
        }
    }

    @Test fun unobservableOutputNeedsExpectedFreshPresentationForRecovery() {
        val input = live().copy(lifecycle = live().lifecycle.copy(outputObservable = false))
        assertFalse(FeedIncidentClassifier.isRecovered(input))
        assertTrue(FeedIncidentClassifier.isRecovered(input.copy(ages = input.ages.copy(presentAge = 0.2))))
        assertFalse(FeedIncidentClassifier.isRecovered(input.copy(lifecycle = input.lifecycle.copy(presentationExpected = false))))
    }

    @Test fun privacyKeepsUnknownAgesAndOnlyAllowlistedBreadcrumbDetails() {
        assertNull(FeedIncidentPrivacy.age(Double.NaN))
        assertNull(FeedIncidentPrivacy.age(-1.0))
        assertNull(FeedIncidentPrivacy.age(null))
        assertEquals(mapOf("sceneState" to "active"), FeedIncidentNativeBreadcrumb.sanitized(mapOf(
            "sceneState" to "active", "password" to "fixture-secret", "path" to "not-an-allowed-value",
        )))
        assertEquals(listOf(0, 3, 6, 9), FeedIncidentSampling.downsample((0..9).toList(), 4))
        assertEquals("incident-abc123.json", FeedIncidentFileNaming.incident("a/b/c:123"))
    }
}
