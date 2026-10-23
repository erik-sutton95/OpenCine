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
import com.opencapture.opencine.media.FeedIncidentSessionSummary
import com.opencapture.opencine.media.FeedIncidentSnapshot
import com.opencapture.opencine.media.FeedIncidentTestSource
import com.opencapture.opencine.media.FeedRepairPhase
import com.opencapture.opencine.media.FeedRepairRecord
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
            environment = "development",
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
    fun legacySinkConformerAllowsAnOptionalMetricSample() {
        val sink: ReliabilityReportingSink = NoSdk
        sink.record(ReliabilityMetric("feed.session.incidents", 1.0))
        assertFalse(reporting.isOptedIn)
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
        gate.register(fake)
        assertFalse(gate.shouldBlockUpload)
        assertTrue(gate.isConnected)
        val lease = gate.beginCameraPath()
        assertTrue(gate.shouldBlockUpload)
        assertFalse(gate.isConnected)
        assertTrue(fake.cancelled)
        lease.end()
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
        gate.register(fake)
        assertFalse(fake.cancelled)
        gate.cancelPending(includeIndependent = false)
        assertFalse(fake.cancelled)
        gate.beginCameraPath()
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
        gate.beginCameraPath()
        assertEquals(
            ReliabilityReportingLoadDecision.BLOCK_CAMERA_PATH,
            ReliabilityReportingNetwork.decision(allowed, dsnHost, gate),
        )
    }

    /**
     * A6-08: each connection owner holds its own lease from the connect attempt through recovery
     * and failure until it retires. A superseded owner ending late, or twice, never reopens its
     * successor's hold; uploads resume (and onClear runs) after the last lease ends.
     */
    @Test
    fun cameraPathLeaseIsFencedPerOwner() {
        consent.setOptedIn(true)
        gate.setCameraIPv4PathReadyForTests(false)
        val queued = FakeTask()
        gate.register(queued)
        var clears = 0
        val stale = gate.beginCameraPath { clears += 1 }
        assertTrue(queued.cancelled)
        val successor = gate.beginCameraPath { clears += 1 }
        stale.end()
        stale.close()
        assertTrue(stale.isEnded)
        assertTrue(gate.isCameraSessionActive)
        assertTrue(gate.shouldBlockUpload)
        assertEquals(0, clears)
        val late = FakeTask()
        gate.register(late)
        assertTrue(late.cancelled)
        successor.end()
        assertFalse(gate.shouldBlockUpload)
        assertEquals(1, clears)
        successor.end()
        assertEquals(1, clears)

        val outlived = gate.beginCameraPath()
        gate.resetForTests()
        val next = gate.beginCameraPath()
        outlived.close()
        assertTrue(gate.shouldBlockUpload, "a lease that outlived a reset cannot release a new holder")
        next.close()
        assertFalse(gate.shouldBlockUpload)
    }

    @Test
    fun revokedConsentDisconnectsTransportGate() {
        consent.setOptedIn(false)
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
    fun incidentTitleNamesItsKindAndTagsCarryTriggerRecoveryAndGapLikeIos() {
        consent.setOptedIn(true)
        gate.setCameraIPv4PathReadyForTests(false)
        val bundle = stallBundle("34343434343434343434343434343434")
        val start = bundle.header.startedAtMonotonic
        bundle.repairs =
            listOf(
                FeedRepairRecord(start, "session", FeedRepairPhase.REQUESTED, "bleDropped"),
                FeedRepairRecord(start + 1.0, "endpoint", FeedRepairPhase.REQUESTED),
            )
        bundle.header.worstGapSeconds = 16.3
        var event: ReliabilityEvent? = null
        reporting.setCaptureHandlerForTests { captured, _ -> event = captured }
        reporting.enqueueFinalized(bundle)
        waitUntil { event != null }
        val captured = assertNotNull(event)
        assertEquals(
            "feed incident ${bundle.header.failingStage.wire}: ${bundle.header.kind.wire}",
            captured.message,
        )
        assertEquals("bleDropped", captured.tags?.get("trigger"))
        assertEquals("endpoint", captured.tags?.get("recoveredBy"))
        assertEquals("10-20s", captured.tags?.get("gap"))
        assertEquals("bleDropped", captured.extras?.get("trigger"))
        assertEquals("endpoint", captured.contexts["feed"]?.get("recoveredBy"))
        // Diagnostics derived from the incident's own snapshots (Swift twin asserts the same).
        val envelope = FeedIncidentExport.envelope(bundle)
        assertEquals(envelope.background, captured.tags?.get("background"))
        assertEquals(envelope.awaitingIrap, captured.tags?.get("awaitingIrap"))
        assertEquals(envelope.background, captured.extras?.get("background"))
        assertTrue(captured.tags?.get("background") in setOf("yes", "no", "unknown"))
        assertEquals("other", ReliabilityReportingPrivacy.value("background", "SSID_ZR_6002199"))
    }

    @Test
    fun installIdExistsOnlyUnderConsentAndResetsWhenWithdrawn() {
        val stored = mutableMapOf<String, String>()
        fun bindStored() =
            consent.restorePersistedChoice(
                hasChoice = true,
                optedIn = consent.isOptedIn,
                installId = stored["id"],
                persistInstallId = { value -> if (value == null) stored.remove("id") else stored["id"] = value },
            )
        assertNull(consent.installId, "undecided: no id")
        consent.setOptedIn(false)
        bindStored()
        assertNull(consent.installId, "declined: no id")
        consent.setOptedIn(true)
        val first = assertNotNull(consent.installId)
        assertEquals(first, java.util.UUID.fromString(first).toString(), "a random UUID, nothing from the device")
        assertEquals(first, consent.installId)
        assertEquals(first, stored["id"], "kept across launches")
        consent.setOptedIn(false)
        assertNull(consent.installId)
        assertNull(stored["id"], "withdrawal deletes it")
        consent.setOptedIn(true)
        assertTrue(assertNotNull(consent.installId) != first, "a new opt-in starts a new id")
    }

    @Test
    fun sessionSummaryIsAMetricNotAnIssueEvent() {
        consent.setOptedIn(true)
        gate.setCameraIPv4PathReadyForTests(false)
        val summary =
            FeedIncidentSessionSummary(
                sessionID = java.util.UUID.randomUUID().toString(),
                healthyExposureSeconds = 42.5,
                incidentCount = 2,
                outcome = "ended",
                sourceRevision = "test",
                appVersion = "0.1.0",
                appBuild = "107",
                testSource = FeedIncidentTestSource.MANUAL,
            )
        val events = java.util.concurrent.CopyOnWriteArrayList<ReliabilityEvent>()
        val metrics = java.util.concurrent.CopyOnWriteArrayList<ReliabilityMetric>()
        reporting.setCaptureHandlerForTests { event, _ -> events.add(event) }
        reporting.setMetricHandlerForTests { metrics.add(it) }
        reporting.noteSessionSummary(summary)
        waitUntil { metrics.size >= 2 || events.isNotEmpty() }
        assertTrue(events.none { it.fingerprints?.firstOrNull() == "feed-session" }, "no issue event")
        val byName = metrics.associateBy { it.name }
        assertEquals(ReliabilityReportingPrivacy.metricAllowlist, byName.keys)
        assertEquals(42.5, byName.getValue("feed.session.healthy_exposure").value)
        assertEquals("second", byName.getValue("feed.session.healthy_exposure").unit)
        assertEquals(2.0, byName.getValue("feed.session.incidents").value)
        assertEquals("ended", byName.getValue("feed.session.incidents").attributes["outcome"])
        assertEquals("manual", byName.getValue("feed.session.incidents").attributes["testSource"])
        assertEquals("107", byName.getValue("feed.session.incidents").attributes["appBuild"])
        waitUntil { reporting.receipt("session-${summary.sessionID}") != null }
        reporting.noteSessionSummary(summary)
        Thread.sleep(300)
        assertEquals(2, metrics.size, "recorded once")
    }

    @Test
    fun theFeedUpscalerIsAScopeTagFromSdkStartOn() {
        reporting.noteFeedUpscaler("Quality")
        assertEquals("Quality", reporting.scopeTags()["feedUpscaler"], "remembered before the SDK starts")
        assertEquals("Quality", reporting.privacy.tags(mapOf("feedUpscaler" to "Quality"))?.get("feedUpscaler"))
    }

    /**
     * Security review (privacy-unsanitized-telemetry): free text planted in every runtime input that
     * reaches a reported field never reaches the sink. Inputs: repair action and reason (trigger,
     * recoveredBy, attachment), the build values (scope tags, incident tags and attachment, metric
     * attributes), the session outcome and build number (metrics), the feed upscaler (scope tag) and
     * a stored install id. Swift twin: testNoPlantedSecretReachesTheSink.
     */
    @Test
    fun noPlantedSecretReachesTheSink() {
        val secrets =
            listOf(
                "OpenCapture-Guest-5G",
                "ZR_6002199",
                "/\u0055sers/erik/Movies/take.mov",
                "tester@example.com",
                "203.0.113.7",
                "192.168.1.23",
            )
        consent.setOptedIn(true)
        gate.setCameraIPv4PathReadyForTests(false)
        val sent = java.util.concurrent.CopyOnWriteArrayList<String>()
        val captured = java.util.concurrent.atomic.AtomicInteger()
        val recorded = java.util.concurrent.atomic.AtomicInteger()
        reporting.setCaptureHandlerForTests { event, json ->
            sent += event.message
            sent += event.fingerprints.joinToString(" ")
            sent += event.tags.orEmpty().entries.joinToString(" ") { "${it.key}=${it.value}" }
            sent += event.extras.orEmpty().toString()
            sent += event.contexts.toString()
            sent += String(json, Charsets.UTF_8)
            captured.incrementAndGet()
        }
        reporting.setMetricHandlerForTests { metric ->
            sent += "${metric.name} ${metric.unit}"
            sent += metric.attributes.entries.joinToString(" ") { "${it.key}=${it.value}" }
            recorded.incrementAndGet()
        }
        secrets.forEachIndexed { index, secret ->
            val bundle = stallBundle("%032x".format(0xabc + index))
            bundle.header.sourceRevision = secret
            bundle.header.buildIdentity = secret
            bundle.repairs = listOf(FeedRepairRecord(3.5, secret, FeedRepairPhase.REQUESTED, secret))
            reporting.enqueueFinalized(bundle)
            reporting.noteSessionSummary(
                FeedIncidentSessionSummary(
                    sessionID = java.util.UUID.randomUUID().toString(),
                    healthyExposureSeconds = 3.0,
                    incidentCount = 1,
                    outcome = secret,
                    sourceRevision = secret,
                    appVersion = "0.1.0",
                    appBuild = secret,
                    testSource = FeedIncidentTestSource.MANUAL,
                    buildIdentity = secret,
                ),
            )
            origin.overrideBuildIdentityForTests = secret
            val planted = ReliabilityReporting(host.copy(sourceRevision = secret), consent, dsn, gate, origin, { NoSdk })
            planted.noteFeedUpscaler(secret)
            sent += planted.scopeTags().entries.joinToString(" ") { "${it.key}=${it.value}" }
            consent.restorePersistedChoice(hasChoice = true, optedIn = true, installId = secret)
            sent += consent.installId.orEmpty()
        }
        waitUntil { captured.get() == secrets.size && recorded.get() == secrets.size * 2 }
        assertEquals(secrets.size, captured.get())
        assertEquals(secrets.size * 2, recorded.get())
        for (secret in secrets) assertTrue(sent.none { secret in it }, "$secret reached the sink")
        assertTrue(sent.any { "trigger=other" in it }, "the field is still sent")
    }

    @Test
    fun onlyTheSdksLifecycleExceptionTextSurvives() {
        for (kept in listOf(
            "App hanging for at least 2000 ms.",
            "App hanging between 2.0 and 3.4 seconds.",
            "The OS watchdog terminated your app, possibly because it overused RAM.",
            "Application Not Responding for at least 5000 ms.",
            "Background ANR",
        )) {
            assertEquals(kept, ReliabilityReportingPrivacy.exceptionValue(kept))
        }
        for (replaced in listOf(
            "Application Not Responding for at least 5000 ms. tester@example.com",
            "Attempt to invoke virtual method on a null object reference",
        )) {
            assertEquals("Native exception", ReliabilityReportingPrivacy.exceptionValue(replaced))
        }
    }

    @Test
    fun queuedReplayOriginSurvivesJsonReloadAndCurrentRunOverride() {
        consent.setOptedIn(true)
        gate.setCameraIPv4PathReadyForTests(false)
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
        gate.beginCameraPath()
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

    @Test
    fun receiptsRefuseIdsThatLeaveTheReceiptsDirectory() {
        val outside = File(cacheRoot, "escape.json")
        for (id in listOf("../escape", "..", "a/b", "a\\b", "receipts/../../escape")) {
            ReliabilityReportingReceipts.store(
                ReliabilityReportingReceipt(id, "e", ReliabilityReportingReceiptState.QUEUED, System.currentTimeMillis()),
                cacheRoot,
            )
            assertNull(ReliabilityReportingReceipts.file(id, cacheRoot), id)
            assertNull(ReliabilityReportingReceipts.load(id, cacheRoot), id)
        }
        assertFalse(outside.exists())
        assertTrue(ReliabilityReportingReceipts.loadAll(cacheRoot).isEmpty())
        outside.writeText("""{"incidentID":"x","eventID":"e","state":"queued","updatedAt":"2026-10-05T12:00:00Z"}""")
        assertNull(ReliabilityReportingReceipts.load("../escape", cacheRoot))
        // A UUID or session ID behaves as before: one `<id>.json` under receipts.
        for (id in listOf("12c2d058-d584-4270-9aa2-eca08bf20986", "session-12c2d058d58442709aa2eca08bf20986")) {
            ReliabilityReportingReceipts.store(
                ReliabilityReportingReceipt(id, "e", ReliabilityReportingReceiptState.QUEUED, System.currentTimeMillis()),
                cacheRoot,
            )
            assertEquals(
                File(ReliabilityReportingReceipts.directory(cacheRoot), "$id.json"),
                ReliabilityReportingReceipts.file(id, cacheRoot),
            )
            assertEquals(id, ReliabilityReportingReceipts.load(id, cacheRoot)?.incidentID)
        }
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

    @Test fun mutatedRepairIsClosedBeforeExportAndAttachment() {
        val secret = "SIMULATED-private-network"
        val bundle = stallBundle("SIMULATED-mutated-repair")
        val repair = FeedRepairRecord(4.5, "decoder", FeedRepairPhase.REQUESTED, "outputSilence")
        bundle.repairs = listOf(repair.copy(action = secret, reason = secret))
        val envelope = FeedIncidentExport.envelope(bundle)
        assertEquals("other", envelope.trigger)
        assertEquals("other", envelope.recoveredBy)
        val payload = assertNotNull(ReliabilityReportingPrivacy.typedJson(bundle))
        assertFalse(secret in payload.decodeToString())
    }

    @Test fun undeclaredSocTagIsRemoved() {
        assertNull(ReliabilityReportingPrivacy(redact).tags(mapOf("soc" to "SIMULATED-private-device-value")))
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
