package com.opencapture.opencine.appkit.diagnostics

import com.opencapture.opencine.media.FeedIncidentAges
import com.opencapture.opencine.media.FeedIncidentBundle
import com.opencapture.opencine.media.FeedIncidentExport
import com.opencapture.opencine.media.FeedIncidentFailingStage
import com.opencapture.opencine.media.FeedIncidentKind
import com.opencapture.opencine.media.FeedIncidentLifecycle
import com.opencapture.opencine.media.FeedIncidentOutcome
import com.opencapture.opencine.media.FeedIncidentRates
import com.opencapture.opencine.media.FeedIncidentRecorder
import com.opencapture.opencine.media.FeedIncidentSessionContext
import com.opencapture.opencine.media.FeedIncidentSnapshot
import com.opencapture.opencine.media.FeedIncidentTestSource
import com.opencapture.opencine.media.PrivacyRedactor
import java.io.File
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** The SDK-free half of the apps' ReliabilityReportingTest; the Sentry half stays with each app. */
class ReliabilityReportingTest {
    private val redact: (String) -> String = { PrivacyRedactor.redact(it) }
    private val host =
        DiagnosticsHost(
            product = "Host",
            releasePackage = "com.opencapture.host",
            versionName = "1.0",
            versionCode = 1,
            debug = true,
            sourceRevision = "test",
            reportingDsn = null,
            reportingClient = "host-android",
            supportEmail = "support@host.invalid",
            preferencesName = "host.operator",
            redact = redact,
        )
    private val dsn = ReliabilityReportingDSN()
    private val consent = ReliabilityReportingConsent(dsn)
    private val gate = ReliabilityReportingGate(consent, ReliabilityReportingHostPolicy(), "192.168.2.")
    private val origin = FeedIncidentOrigin({ "android-test" }, redact)
    private val reporting = ReliabilityReporting(host, consent, dsn, gate, origin, { NoSdk })
    private lateinit var cacheRoot: File

    companion object {
        private const val CONFIGURED_DSN = "https://publickey@o0.ingest.sentry.io/0"
    }

    @BeforeTest
    fun setUp() {
        cacheRoot = File(System.getProperty("java.io.tmpdir"), "opc-rel-${System.nanoTime()}")
        cacheRoot.mkdirs()
        reporting.sdkCacheRoot = cacheRoot
        consent.resetForTests()
        dsn.buildDsn = null
        dsn.environment = emptyMap()
        reporting.setCaptureHandlerForTests(null)
        gate.resetForTests()
        reporting.dsnHost = "o0.ingest.sentry.io"
    }

    @AfterTest
    fun tearDown() {
        reporting.setCaptureHandlerForTests(null)
        consent.resetForTests()
        gate.resetForTests()
        origin.resetForTests()
        cacheRoot.deleteRecursively()
    }

    @Test
    fun onlyExhaustedIncidentsAreErrors() {
        assertEquals(ReliabilityEventLevel.ERROR, ReliabilityReporting.level("exhausted"))
        assertEquals(ReliabilityEventLevel.WARNING, ReliabilityReporting.level("interrupted"))
        assertEquals(ReliabilityEventLevel.INFO, ReliabilityReporting.level("recovered"))
        assertEquals(ReliabilityEventLevel.INFO, ReliabilityReporting.level("suppressed"))
    }

    @Test
    fun consentDefaultsOffAndRevokePurgesOnlySdkOwnedSpool() {
        assertFalse(consent.isOptedIn)
        assertFalse(reporting.isOptedIn)
        consent.setOptedIn(true)
        assertTrue(reporting.isOptedIn)
        val localDir = File(System.getProperty("java.io.tmpdir"), "opc-local-${System.nanoTime()}")
        localDir.mkdirs()
        val local = File(localDir, "incident-keep.json")
        local.writeText("keep")
        ReliabilityReportingReceipts.store(
            ReliabilityReportingReceipt(
                incidentID = "inc-1",
                eventID = "abc",
                state = ReliabilityReportingReceiptState.QUEUED,
                updatedAt = System.currentTimeMillis(),
            ),
            cacheRoot,
        )
        assertNotNull(ReliabilityReportingReceipts.load("inc-1", cacheRoot))
        reporting.setConsent(false)
        assertFalse(reporting.isOptedIn)
        waitUntil { ReliabilityReportingReceipts.load("inc-1", cacheRoot) == null }
        assertNull(ReliabilityReportingReceipts.load("inc-1", cacheRoot))
        assertTrue(local.isFile)
        localDir.deleteRecursively()
    }

    @Test
    fun dsnRequiresHttpsSentryShape() {
        assertNull(ReliabilityReportingDSN.validated(""))
        assertNull(ReliabilityReportingDSN.validated("http://key@host/1"))
        assertNull(ReliabilityReportingDSN.validated("https://ingest.sentry.io/1"))
        assertNull(ReliabilityReportingDSN.validated("https://key:secret@ingest.sentry.io/1"))
        assertNull(ReliabilityReportingDSN.validated("https://key@ingest.sentry.io/1?token=value"))
        assertNull(ReliabilityReportingDSN.validated("https://key@ingest.sentry.io/1#frag"))
        assertNull(ReliabilityReportingDSN.validated("https://key@ingest.sentry.io/not-a-project"))
        assertNotNull(ReliabilityReportingDSN.validated("https://publickey@o0.ingest.sentry.io/0"))
        dsn.buildDsn = ""
        assertFalse(dsn.isAvailable)
        dsn.buildDsn = "https://publickey@o0.ingest.sentry.io/0"
        assertTrue(dsn.isAvailable)
    }

    @Test
    fun cameraGateBlocksEvenWithInternetAndCancelsPending() {
        val fake = FakeTask()
        consent.setOptedIn(true)
        gate.setValidInternetForTests(true)
        gate.setCameraIPv4PathReadyForTests(false)
        gate.setCameraSessionActive(false)
        gate.register(fake)
        assertFalse(gate.shouldBlockUpload)
        assertTrue(gate.isConnected)
        gate.setCameraSessionActive(true)
        assertTrue(gate.shouldBlockUpload)
        assertFalse(gate.isConnected)
        assertTrue(fake.cancelled)
        gate.setCameraSessionActive(false)
        gate.setCameraIPv4PathReadyForTests(true)
        assertTrue(gate.shouldBlockUpload)
        assertFalse(gate.isConnected)
    }

    @Test
    fun manualRegisterSurvivesMissingConsentAndConsentRevoke() {
        val fake = object : ReliabilityReportingCancellable {
            var cancelled = false
            override val independentOfAutomaticConsent = true
            override fun cancel() {
                cancelled = true
            }
        }
        consent.setOptedIn(false)
        gate.setValidInternetForTests(true)
        gate.setCameraIPv4PathReadyForTests(false)
        gate.setCameraSessionActive(false)
        gate.register(fake)
        assertFalse(fake.cancelled)
        gate.cancelPending(includeIndependent = false)
        assertFalse(fake.cancelled)
        gate.setCameraSessionActive(true)
        assertTrue(fake.cancelled)
    }

    @Test
    fun automaticPromptIsOffUntilConfiguredAndUndecided() {
        dsn.buildDsn = null
        assertFalse(consent.shouldOfferAutomaticPrompt())
        dsn.buildDsn = "https://publickey@o0.ingest.sentry.io/0"
        assertTrue(consent.shouldOfferAutomaticPrompt())
        consent.setOptedIn(true)
        assertFalse(consent.shouldOfferAutomaticPrompt())
        consent.resetForTests()
        dsn.buildDsn = "https://publickey@o0.ingest.sentry.io/0"
        consent.setOptedIn(false)
        assertFalse(consent.shouldOfferAutomaticPrompt())
        assertFalse(consent.isOptedIn)
        assertTrue(consent.hasDecision)
    }

    @Test
    fun persistedChoiceRestoresWithoutRepromptingOrWritingUnasked() {
        data class Case(
            val name: String,
            val dsn: String?,
            val choice: Boolean?,
            val hasDecision: Boolean,
            val optedIn: Boolean?,
            val offersPrompt: Boolean,
        )
        val cases =
            listOf(
                Case("absent choice offers prompt when configured without writing", CONFIGURED_DSN, null,
                    hasDecision = false, optedIn = false, offersPrompt = true),
                Case("unavailable destination does not mark asked on absent choice", null, null,
                    hasDecision = false, optedIn = null, offersPrompt = false),
                Case("explicit decline persists across restore and does not reprompt", CONFIGURED_DSN, false,
                    hasDecision = true, optedIn = false, offersPrompt = false),
                Case("explicit accept persists across restore and does not reprompt", CONFIGURED_DSN, true,
                    hasDecision = true, optedIn = true, offersPrompt = false),
            )
        for (case in cases) {
            consent.resetForTests()
            val stored = mutableMapOf<String, Boolean>()
            dsn.buildDsn = case.dsn
            consent.restorePersistedChoice(
                hasChoice = false,
                persist = { stored[ReliabilityReportingConsent.KEY] = it },
            )
            val choice = case.choice
            if (choice == null) {
                assertTrue(stored.isEmpty(), case.name)
            } else {
                consent.setOptedIn(choice)
                assertEquals(choice, stored[ReliabilityReportingConsent.KEY], case.name)
                consent.resetForTests()
                consent.restorePersistedChoice(
                    hasChoice = stored.contains(ReliabilityReportingConsent.KEY),
                    optedIn = stored[ReliabilityReportingConsent.KEY] == true,
                    persist = { stored[ReliabilityReportingConsent.KEY] = it },
                )
            }
            assertEquals(case.hasDecision, consent.hasDecision, case.name)
            case.optedIn?.let { assertEquals(it, consent.isOptedIn, case.name) }
            assertEquals(case.offersPrompt, consent.shouldOfferAutomaticPrompt(), case.name)
        }
    }

    @Test
    fun hostIsolationRejectsNonDsnHosts() {
        val dsnHost = "o0.ingest.sentry.io"
        val allowed = "https://o0.ingest.sentry.io/api/0/envelope/"
        val other = "https://example.com/ingest"
        assertTrue(gate.hostPolicy.allows(allowed, dsnHost))
        assertFalse(gate.hostPolicy.allows(other, dsnHost))
        assertEquals(
            ReliabilityReportingLoadDecision.REJECT_HOST,
            ReliabilityReportingNetwork.decision(other, dsnHost, gate),
        )
        gate.setCameraSessionActive(true)
        assertEquals(
            ReliabilityReportingLoadDecision.BLOCK_CAMERA_PATH,
            ReliabilityReportingNetwork.decision(allowed, dsnHost, gate),
        )
    }

    @Test
    fun revokedConsentDisconnectsTransportGate() {
        consent.setOptedIn(false)
        gate.setCameraSessionActive(false)
        gate.setCameraIPv4PathReadyForTests(false)
        gate.setValidInternetForTests(true)
        assertFalse(gate.isConnected)
        consent.setOptedIn(true)
        assertTrue(gate.isConnected)
    }

    @Test
    fun eventIdAndFingerprintAreStable() {
        val id = "12c2d058-d584-4270-9aa2-eca08bf20986"
        val first = ReliabilityReportingPrivacy.eventId(id)
        val second = ReliabilityReportingPrivacy.eventId(id)
        assertEquals(first.toString(), second.toString())
        assertEquals("12c2d058d58442709aa2eca08bf20986", first.toString())
        val prints =
            reporting.privacy.fingerprint(
                schema = 1,
                kind = "freshInputStaleOutput",
                stage = "decodedOutput",
                errorClass = "invalidSession",
            )
        assertEquals(
            listOf(
                "feed-incident",
                "schema:1",
                "kind:freshInputStaleOutput",
                "stage:decodedOutput",
                "errorClass:invalidSession",
            ),
            prints,
        )
    }

    @Test
    fun queuedIncidentKeepsOriginalReleaseAndOccurrenceTime() {
        consent.setOptedIn(true)
        gate.setCameraIPv4PathReadyForTests(false)
        gate.setCameraSessionActive(false)
        val bundle = stallBundle("12121212121212121212121212121212")
        bundle.header.appVersion = "0.1.0"
        bundle.header.appBuild = "107"
        bundle.header.sourceRevision = "a".repeat(40)
        bundle.header.testSource = FeedIncidentTestSource.FAULT_INJECTION
        bundle.header.buildIdentity = "android-0123456789abcdef0123456789ab"
        bundle.header.kind = FeedIncidentKind.TRANSPORT_STALL
        bundle.header.startedAtWallClockMs = 1_780_000_000_000L
        origin.overrideTestSourceForTests = FeedIncidentTestSource.VERIFICATION
        origin.overrideBuildIdentityForTests = "android-current-run-identity-value"
        var captured = false
        reporting.setCaptureHandlerForTests { event, _ ->
            captured = true
            assertEquals("com.opencapture.host@0.1.0+107", event.release)
            assertEquals("107", event.dist)
            assertEquals(1_780_000_000_000L, event.timestampMs)
            assertEquals("a".repeat(40), event.tags?.get("sourceRevision"))
            assertEquals("faultInjection", event.tags?.get("testSource"))
            assertEquals("android-0123456789abcdef0123456789ab", event.tags?.get("buildIdentity"))
            assertTrue(event.fingerprints?.contains("kind:transportStall") == true)
            assertTrue(event.tags?.get("testSource") != "verification")
        }
        reporting.enqueueFinalized(bundle)
        waitUntil { captured }
        assertTrue(captured)
    }

    @Test
    fun queuedReplayOriginSurvivesJsonReloadAndCurrentRunOverride() {
        consent.setOptedIn(true)
        gate.setCameraIPv4PathReadyForTests(false)
        gate.setCameraSessionActive(false)
        val original = stallBundle("14141414141414141414141414141414")
        original.header.testSource = FeedIncidentTestSource.FAULT_INJECTION
        original.header.buildIdentity = "android-queuedorigin0123456789abcd"
        original.header.kind = FeedIncidentKind.TRANSPORT_STALL
        val encoded = FeedIncidentJson.encode(original)
        val json = org.json.JSONObject(String(encoded, Charsets.UTF_8))
        json.getJSONObject("header").remove("testSource")
        json.getJSONObject("header").remove("buildIdentity")
        val legacy = FeedIncidentJson.decode(json.toString().toByteArray(Charsets.UTF_8))
        assertNotNull(legacy)
        assertEquals(FeedIncidentTestSource.UNKNOWN, legacy.header.testSource)
        assertEquals("unknown", legacy.header.buildIdentity)
        val restored = FeedIncidentJson.decode(encoded)
        assertNotNull(restored)
        origin.overrideTestSourceForTests = FeedIncidentTestSource.VERIFICATION
        origin.overrideBuildIdentityForTests = "android-current-run-identity-value"
        var captured = false
        reporting.setCaptureHandlerForTests { event, _ ->
            captured = true
            assertEquals("faultInjection", event.tags?.get("testSource"))
            assertEquals("android-queuedorigin0123456789abcd", event.tags?.get("buildIdentity"))
            assertTrue(event.fingerprints?.contains("kind:transportStall") == true)
            assertTrue(event.tags?.get("testSource") != "verification")
        }
        reporting.enqueueFinalized(restored)
        waitUntil { captured }
        assertTrue(captured)
    }

    @Test
    fun queuedReceiptOlderThanFiveMinutesCanRetry() {
        consent.setOptedIn(true)
        gate.setCameraIPv4PathReadyForTests(false)
        gate.setCameraSessionActive(false)
        val id = "13131313131313131313131313131313"
        ReliabilityReportingReceipts.store(
            ReliabilityReportingReceipt(
                incidentID = id,
                eventID = id,
                state = ReliabilityReportingReceiptState.QUEUED,
                updatedAt = System.currentTimeMillis() - 301_000L,
            ),
            cacheRoot,
        )
        var captured = 0
        reporting.setCaptureHandlerForTests { _, _ -> captured += 1 }
        reporting.enqueueFinalized(stallBundle(id))
        waitUntil { captured == 1 }
        assertEquals(1, captured)
    }

    @Test
    fun captureEnqueueIsQueuedNotDeliveredAndDedupsConfirmed() {
        consent.setOptedIn(true)
        gate.setCameraIPv4PathReadyForTests(false)
        gate.setCameraSessionActive(false)
        val bundle = stallBundle("12c2d058d58442709aa2eca08bf20986")
        var captured = 0
        reporting.setCaptureHandlerForTests { event, data ->
            captured += 1
            assertEquals("12c2d058d58442709aa2eca08bf20986", event.eventId.toString())
            assertEquals("feed-incident", event.fingerprints?.first())
            assertTrue(event.fingerprints?.contains("kind:freshInputStaleOutput") == true)
            val text = String(data, Charsets.UTF_8)
            assertTrue(text.contains("prelude"))
            assertFalse(text.contains("control-live.log"))
        }
        reporting.enqueueFinalized(bundle)
        waitForReceipt("12c2d058d58442709aa2eca08bf20986", ReliabilityReportingReceiptState.QUEUED)
        assertEquals(1, captured)
        reporting.noteTransportSuccess("12c2d058d58442709aa2eca08bf20986")
        waitForReceipt("12c2d058d58442709aa2eca08bf20986", ReliabilityReportingReceiptState.CONFIRMED)
        reporting.setCaptureHandlerForTests { _, _ -> captured += 1 }
        reporting.enqueueFinalized(bundle)
        Thread.sleep(300)
        assertEquals(1, captured)
    }

    @Test
    fun openCheckpointDoesNotEnqueue() {
        consent.setOptedIn(true)
        gate.setCameraIPv4PathReadyForTests(false)
        val open = stallBundle("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", outcome = FeedIncidentOutcome.OPEN)
        assertFalse(ReliabilityReporting.isFinalized(open))
        var captured = false
        reporting.setCaptureHandlerForTests { _, _ -> captured = true }
        reporting.enqueueFinalized(open)
        Thread.sleep(400)
        assertFalse(captured)
        assertNull(reporting.receipt("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"))
    }

    @Test
    fun cameraPathDoesNotEnqueueWhileBlocked() {
        consent.setOptedIn(true)
        gate.setCameraSessionActive(true)
        val bundle = stallBundle("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")
        var captured = false
        reporting.setCaptureHandlerForTests { _, _ -> captured = true }
        reporting.enqueueFinalized(bundle)
        Thread.sleep(400)
        assertFalse(captured)
        assertNull(reporting.receipt("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"))
    }

    @Test
    fun vendorEnvelopeMapsStageAndErrorClass() {
        val bundle = stallBundle("cccccccccccccccccccccccccccccccc")
        bundle.header.failingStage = FeedIncidentFailingStage.DECODED_OUTPUT
        bundle.header.errorClass = "invalidSession"
        val envelope = ReliabilityReportingPrivacy.validatedEnvelope(bundle)
        assertNotNull(envelope)
        assertEquals("feed.incident", envelope.eventName)
        assertEquals(1, envelope.schemaVersion)
        assertEquals("decodedOutput", envelope.grouping.failingStage)
        assertEquals("invalidSession", envelope.grouping.errorClass)
        assertEquals(
            listOf(
                "feed-incident",
                "schema:1",
                "kind:freshInputStaleOutput",
                "stage:decodedOutput",
                "errorClass:invalidSession",
            ),
            reporting.privacy.fingerprint(
                envelope.schemaVersion,
                envelope.kind,
                envelope.grouping.failingStage,
                envelope.grouping.errorClass,
            ),
        )
        val json = ReliabilityReportingPrivacy.typedJson(bundle)
        assertNotNull(json)
        assertTrue(json.size <= 262_144)
    }

    @Test
    fun unknownStageIsRejected() {
        val bundle = stallBundle("dddddddddddddddddddddddddddddddd")
        bundle.header.failingStage = FeedIncidentFailingStage.PACKET
        val envelope = FeedIncidentExport.envelope(bundle)
        assertTrue(FeedIncidentFailingStage.isKnown(envelope.grouping.failingStage))
        assertFalse(FeedIncidentFailingStage.isKnown("not-a-stage"))
        assertNull(
            ReliabilityReportingPrivacy.validatedEnvelope(
                bundle.copy(
                    header = bundle.header.copy(incidentId = "unknown"),
                ),
            ),
        )
    }

    @Test
    fun sessionSummaryDoesNotClaimHealthyAtZeroExposure() {
        assertEquals("healthy", FeedIncidentRuntime.summaryOutcome(0, 12.0))
        assertEquals("no-exposure", FeedIncidentRuntime.summaryOutcome(0, 0.0))
        assertEquals("ended", FeedIncidentRuntime.summaryOutcome(2, 40.0))
    }

    @Test
    fun backoffGrowsWithJitterBound() {
        val first = ReliabilityReportingBackoff.delaySeconds(0, 0.0)
        val later = ReliabilityReportingBackoff.delaySeconds(5, 1.0)
        assertTrue(later > first)
        assertTrue(later <= 30.0)
    }

    @Test
    fun immediateConfirmationIsNotOverwrittenByQueuedReceipt() {
        consent.setOptedIn(true)
        gate.setCameraIPv4PathReadyForTests(false)
        val id = "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
        reporting.setCaptureHandlerForTests { event, _ ->
            reporting.noteTransportSuccess(event.eventId.toString())
        }
        reporting.enqueueFinalized(stallBundle(id))
        waitForReceipt(id, ReliabilityReportingReceiptState.CONFIRMED)
    }

    private fun waitForReceipt(id: String, state: ReliabilityReportingReceiptState) {
        waitUntil { reporting.receipt(id)?.state == state }
        assertEquals(state, reporting.receipt(id)?.state)
    }

    // Returns as soon as the predicate holds; the ceiling only matters on a loaded CI runner.
    private fun waitUntil(timeoutMs: Long = 10_000, predicate: () -> Boolean) {
        val deadline = System.currentTimeMillis() + timeoutMs
        while (System.currentTimeMillis() < deadline) {
            if (predicate()) return
            Thread.sleep(20)
        }
    }

    private fun stallBundle(
        id: String,
        outcome: FeedIncidentOutcome = FeedIncidentOutcome.RECOVERED,
    ): FeedIncidentBundle {
        val recorder = FeedIncidentRecorder(redact) { id }
        recorder.beginSession(
            FeedIncidentSessionContext(
                sessionId = "session-1",
                appVersion = "0.1.0",
                appBuild = "2",
                sourceRevision = "test",
                osName = "Android",
                osVersion = "16",
                hardwareClass = "Pixel",
                cameraFamily = "pocket",
            ),
        )
        recorder.recordSnapshot(healthy(1.0))
        recorder.recordSnapshot(staleOutput(3.0))
        val recovered = recorder.recordSnapshot(healthy(4.0))
        val bundle = recovered?.bundle ?: error("expected recovered bundle")
        bundle.header.outcome = outcome
        return bundle
    }

    private fun healthy(monotonic: Double) =
        FeedIncidentSnapshot(
            monotonicNow = monotonic,
            wallClockMs = 1_000L + (monotonic * 1000).toLong(),
            rates =
                FeedIncidentRates(
                    packetHz = 25.0,
                    accessUnitHz = 25.0,
                    decodedOutputHz = 25.0,
                    presentHz = 25.0,
                ),
            ages =
                FeedIncidentAges(
                    packetAge = 0.04,
                    accessUnitAge = 0.04,
                    decodedOutputAge = 0.04,
                    presentAge = 0.04,
                ),
            lifecycle = FeedIncidentLifecycle(connected = true, liveEstablished = true),
        )

    private fun staleOutput(monotonic: Double) =
        healthy(monotonic).copy(
            rates =
                FeedIncidentRates(
                    packetHz = 25.0,
                    accessUnitHz = 25.0,
                    decodeSubmitHz = 25.0,
                    decodedOutputHz = 0.0,
                ),
            ages =
                FeedIncidentAges(
                    packetAge = 0.04,
                    accessUnitAge = 0.04,
                    decodedOutputAge = 5.0,
                    presentAge = 5.0,
                ),
        )

    private class FakeTask : ReliabilityReportingCancellable {
        var cancelled = false
        override fun cancel() {
            cancelled = true
        }
    }

    /** The capture handler stands in for the SDK in these tests. */
    private object NoSdk : ReliabilityReportingSink {
        override fun start(context: android.content.Context, dsn: String, cacheDir: File) = Unit
        override fun close() = Unit
        override fun flush(timeoutMillis: Long) = Unit
        override fun addBreadcrumb(category: String, message: String, data: Map<String, String>) = Unit
        override fun setTags(tags: Map<String, String>) = Unit
        override fun capture(event: ReliabilityEvent, attachment: ByteArray, attachmentName: String) = Unit
    }
}
