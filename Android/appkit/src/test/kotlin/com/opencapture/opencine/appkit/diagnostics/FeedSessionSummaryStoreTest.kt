package com.opencapture.opencine.appkit.diagnostics

import com.opencapture.opencine.media.FeedIncidentSessionSummary
import com.opencapture.opencine.media.FeedIncidentTestSource
import java.io.File
import java.nio.file.Files
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import org.json.JSONObject

class FeedSessionSummaryStoreTest {
    private val id = "6f1d2c3b-4a5e-4f60-8a7b-9c0d1e2f3a4b"

    private fun summary(outcome: String = "live", sessionID: String = id) =
        FeedIncidentSessionSummary(
            sessionID = sessionID,
            healthyExposureSeconds = 12.5,
            incidentCount = 2,
            outcome = outcome,
            sourceRevision = "abc123",
            recordedAtMs = 1_700_000_000_000L,
            appVersion = "1.0",
            appBuild = "7",
            testSource = FeedIncidentTestSource.MANUAL,
            buildIdentity = "ci-42",
        )

    private fun root(): File = Files.createTempDirectory("summary").toFile()

    @Test
    fun persistsUnderSessionsAndLoadsTheSameRecord() {
        val root = root()
        FeedSessionSummaryStore.persist(summary(), root, nowMs = 1_700_000_000_000L)
        assertTrue(File(root, "sessions/$id.json").isFile)
        assertEquals(listOf(summary()), FeedSessionSummaryStore.load(root))
    }

    @Test
    fun rejectsNonUuidSessionsAndNegativeExposure() {
        val root = root()
        FeedSessionSummaryStore.persist(summary(sessionID = "not-a-uuid"), root)
        FeedSessionSummaryStore.persist(summary().copy(healthyExposureSeconds = -1.0), root)
        assertEquals(emptyList(), FeedSessionSummaryStore.load(root))
    }

    @Test
    fun markInterruptedRewritesOnlyLiveSessions() {
        val root = root()
        FeedSessionSummaryStore.persist(summary(), root)
        FeedSessionSummaryStore.markInterrupted(root)
        assertEquals("interrupted", FeedSessionSummaryStore.load(root).single().outcome)
        assertTrue(FeedSessionSummaryStore.deleteAll(root))
        assertEquals(emptyList(), FeedSessionSummaryStore.load(root))
    }

    @Test
    fun reportEncodingCarriesTheDocumentedKeys() {
        val json = JSONObject(FeedSessionSummaryStore.encodeForReport(summary()))
        assertEquals(
            setOf(
                "sessionID", "healthyExposureSeconds", "incidentCount", "outcome", "sourceRevision",
                "recordedAtMs", "appVersion", "appBuild", "testSource", "buildIdentity",
            ),
            json.keys().asSequence().toSet(),
        )
        assertEquals("manual", json.getString("testSource"))
    }
}
