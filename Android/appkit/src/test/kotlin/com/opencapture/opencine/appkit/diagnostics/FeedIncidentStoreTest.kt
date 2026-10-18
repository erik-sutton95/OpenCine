package com.opencapture.opencine.appkit.diagnostics

import com.opencapture.opencine.media.FeedIncidentAges
import com.opencapture.opencine.media.FeedIncidentBreadcrumb
import com.opencapture.opencine.media.FeedIncidentBreadcrumbKind
import com.opencapture.opencine.media.FeedIncidentBundle
import com.opencapture.opencine.media.FeedIncidentDecodeErrorContext
import com.opencapture.opencine.media.FeedIncidentDecoder
import com.opencapture.opencine.media.FeedIncidentIngress
import com.opencapture.opencine.media.FeedIncidentFailingStage
import com.opencapture.opencine.media.FeedIncidentHeader
import com.opencapture.opencine.media.FeedIncidentKind
import com.opencapture.opencine.media.FeedIncidentLifecycle
import com.opencapture.opencine.media.FeedIncidentLimits
import com.opencapture.opencine.media.FeedIncidentOutcome
import com.opencapture.opencine.media.FeedIncidentPersistenceJob
import com.opencapture.opencine.media.FeedIncidentRates
import com.opencapture.opencine.media.FeedIncidentSnapshot
import com.opencapture.opencine.media.FeedIncidentWatchdogGate
import com.opencapture.opencine.media.PrivacyRedactor
import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import org.json.JSONObject
import kotlin.test.assertTrue

class FeedIncidentStoreTest {
    @Test fun optionalRatesRoundTripWithoutInventingUnavailableStages() {
        val sampler = com.opencapture.opencine.media.FeedIncidentRateSampler()
        sampler.sample(1.0, com.opencapture.opencine.media.FeedIncidentStageCounts(accessUnit = 0))
        val rates = sampler.sample(2.0, com.opencapture.opencine.media.FeedIncidentStageCounts(accessUnit = 3))
        val bundle = sampleBundle("observed-rates").let { it.copy(prelude = listOf(it.prelude.single().copy(rates = rates))) }
        val encoded = FeedIncidentJson.encode(bundle)
        val decoded = assertNotNull(FeedIncidentJson.decode(encoded)).prelude.single().rates
        assertEquals(rates, decoded)
        assertNull(decoded.observed?.packetHz)
        val json = org.json.JSONObject(String(encoded, Charsets.UTF_8))
        json.getJSONArray("prelude").getJSONObject(0).getJSONObject("rates").remove("observed")
        val legacy = assertNotNull(FeedIncidentJson.decode(json.toString().toByteArray())).prelude.single().rates
        assertEquals(3.0, legacy.accessUnitHz)
        assertNull(legacy.observed)
    }
    private companion object {
        const val PRODUCT = "Host"
        val REDACT: (String) -> String = { PrivacyRedactor.redact(it) }
    }

    @Test
    fun persistIsAtomicAndSurvivesRereadWithoutCredentialsOrFrames() {
        val dir = File.createTempFile("opc-incidents", "").apply { delete(); mkdirs() }
        try {
            val store = FeedIncidentStore(dir, PRODUCT, REDACT)
            val bundle = sampleBundle("inc-a")
            store.persist(
                FeedIncidentPersistenceJob(bundle, FeedIncidentPersistenceJob.Reason.STARTED),
                nowMs = bundle.header.startedAtWallClockMs,
            )
            val loaded = store.loadAll().single()
            assertEquals("inc-a", loaded.header.incidentId)
            assertEquals(FeedIncidentKind.FRESH_INPUT_STALE_OUTPUT, loaded.header.kind)
            val json = String(File(dir, "incident-inc-a.json").readBytes())
            assertTrue(json.contains("\"incidentID\":\"inc-a\""))
            assertTrue(json.contains("sourceRevision"))
            assertFalse(json.contains("password"))
            assertFalse(json.contains("192.168.1."))
            assertFalse(json.contains("00 00 00 01"))
            dir.listFiles()?.none { it.name.endsWith(".tmp") }?.let { assertTrue(it) }
        } finally {
            dir.deleteRecursively()
        }
    }

    @Test
    fun leftoverOpenIncidentsAreInterruptedNotCrashes() {
        val dir = File.createTempFile("opc-incidents", "").apply { delete(); mkdirs() }
        try {
            val store = FeedIncidentStore(dir, PRODUCT, REDACT)
            store.persist(
                FeedIncidentPersistenceJob(sampleBundle("inc-open"), FeedIncidentPersistenceJob.Reason.STARTED),
                nowMs = 1_000,
            )
            val changed = store.markInterrupted(nowMs = 1_000)
            assertEquals(listOf("inc-open"), changed)
            assertEquals(FeedIncidentOutcome.INTERRUPTED, store.loadAll().single().header.outcome)
            assertTrue(store.loadAll().single().header.processInterrupted)
        } finally {
            dir.deleteRecursively()
        }
    }

    @Test
    fun retentionDropsOldestWhenCountCapIsReached() {
        val dir = File.createTempFile("opc-incidents", "").apply { delete(); mkdirs() }
        try {
            val store = FeedIncidentStore(dir, PRODUCT, REDACT, FeedIncidentLimits(maxBundles = 2, ttlMs = 86_400_000))
            store.persist(job("id-0", started = 1_000), nowMs = 3_000)
            store.persist(job("id-1", started = 2_000), nowMs = 3_000)
            store.persist(job("id-2", started = 3_000), nowMs = 3_000)
            val ids = store.loadAll().map { it.header.incidentId }
            assertEquals(2, ids.size)
            assertFalse(ids.contains("id-0"))
        } finally {
            dir.deleteRecursively()
        }
    }

    @Test
    fun ttlEvictsExpiredBundlesAndCorruptFilesAreIgnored() {
        val dir = File.createTempFile("opc-incidents", "").apply { delete(); mkdirs() }
        try {
            val store = FeedIncidentStore(dir, PRODUCT, REDACT, FeedIncidentLimits(ttlMs = 1_000))
            store.persist(job("old", started = 1_000), nowMs = 1_000)
            File(dir, "incident-bad.json").writeText("{not-json")
            store.applyRetention(nowMs = 10_000)
            assertTrue(store.loadAll().isEmpty())
            assertTrue(File(dir, "incident-bad.json").exists())
            assertTrue(store.loadAll().none { it.header.incidentId == "bad" })
        } finally {
            dir.deleteRecursively()
        }
    }

    @Test
    fun exportExtrasIncludesTypedJsonNotOnlyAHeaderListing() {
        val dir = File.createTempFile("opc-incidents", "").apply { delete(); mkdirs() }
        try {
            val store = FeedIncidentStore(dir, PRODUCT, REDACT)
            store.persist(
                FeedIncidentPersistenceJob(sampleBundle("inc-json"), FeedIncidentPersistenceJob.Reason.STARTED),
                nowMs = 1_000,
            )
            val extras = store.exportExtras()
            val names = extras.map { it.first }
            assertTrue(names.contains("incidents.txt"))
            assertTrue(names.contains("incident-inc-json.json"))
            val listing = extras.first { it.first == "incidents.txt" }.second
            assertTrue(listing.contains("decoderGen="))
            assertTrue(listing.contains("breadcrumbs="))
            val json = extras.first { it.first.endsWith(".json") }.second
            assertTrue(json.contains("\"prelude\""))
            assertTrue(json.contains("\"during\""))
            assertTrue(json.contains("decodedOutputAge"))
            assertTrue(json.contains("outputObservable"))
            assertTrue(json.contains("presentationExpected"))
            assertFalse(json.contains("password"))
            assertFalse(json.contains("00 00 00 01"))
        } finally {
            dir.deleteRecursively()
        }
    }

    @Test
    fun exportExtrasRedactsIdentifiersAndOmitsAnnexB() {
        val dir = File.createTempFile("opc-incidents", "").apply { delete(); mkdirs() }
        try {
            val store = FeedIncidentStore(dir, PRODUCT, REDACT)
            val dirty =
                sampleBundle("inc-redact").copy(
                    breadcrumbs =
                        listOf(
                            FeedIncidentBreadcrumb(
                                1.0,
                                FeedIncidentBreadcrumbKind.SETTINGS_ENTER,
                                "password=hunter2 ssid=CafeWiFi aa:bb:cc:dd:ee:ff",
                            ),
                        ),
                )
            store.persist(
                FeedIncidentPersistenceJob(dirty, FeedIncidentPersistenceJob.Reason.STARTED),
                nowMs = 1_000,
            )
            val extras = store.exportExtras()
            val joined = extras.joinToString("\n") { it.second }
            assertFalse(joined.contains("hunter2"))
            assertTrue(joined.contains("password=<redacted>"))
            assertTrue(joined.contains("ssid=<redacted>"))
            assertTrue(joined.contains("<mac>"))
            assertFalse(joined.contains("00 00 00 01"))
        } finally {
            dir.deleteRecursively()
        }
    }

    @Test
    fun exportExtrasStopsBeforeTheTotalByteCap() {
        val dir = File.createTempFile("opc-incidents", "").apply { delete(); mkdirs() }
        try {
            val store = FeedIncidentStore(dir, PRODUCT, REDACT)
            store.persist(job("id-0", started = 1_000), nowMs = 3_000)
            store.persist(job("id-1", started = 2_000), nowMs = 3_000)
            val unlimited = store.exportExtras(maxTotalBytes = Int.MAX_VALUE)
            val listing = unlimited.first { it.first == "incidents.txt" }.second
            val firstJson = unlimited.first { it.first.endsWith(".json") }.second
            val capped = store.exportExtras(maxTotalBytes = listing.length + firstJson.length + 1)
            assertTrue(capped.any { it.first == "incidents.txt" })
            assertEquals(1, capped.count { it.first.endsWith(".json") })
            assertTrue(capped.sumOf { it.second.length } <= listing.length + firstJson.length + 1)
        } finally {
            dir.deleteRecursively()
        }
    }

    @Test
    fun enforceSizeEvictsSnapshotsToStayUnderTheByteCap() {
        val huge =
            sampleBundle("inc-size").copy(
                prelude = List(80) { sampleSnapshot(it.toDouble()) },
                during = List(80) { sampleSnapshot(100.0 + it) },
            )
        val limited = FeedIncidentStore.enforceSize(huge, maxBytes = 8_192)
        assertTrue(FeedIncidentJson.encodedSize(limited) <= 8_192)
        assertTrue(limited.header.evictions > 0)
        assertTrue(limited.prelude.size + limited.during.size < huge.prelude.size + huge.during.size)
    }

    @Test
    fun ingressStatusAgeAndDecoderStatusFlagsSurviveJsonRoundTrip() {
        val ingress = FeedIncidentIngress(4, 13, 7, 2, 1, 5, 3, 0.1, 0.2, 0.3, false)
        val snapshot = sampleSnapshot(5.0).copy(
            ages = FeedIncidentAges(statusAge = 0.4),
            decoder = FeedIncidentDecoder(lastStatus = -12909, lastFlags = 4_294_967_297L),
            ingress = ingress,
        )
        val bundle = sampleBundle("ingress-json").copy(prelude = listOf(snapshot))
        val decoded = assertNotNull(FeedIncidentJson.decode(FeedIncidentJson.encode(bundle)))
        assertEquals(snapshot, decoded.prelude.single())
    }

    /** PI-2E: the watchdog's gating inputs ride the incident; unknown inputs stay absent (Swift twin). */
    @Test
    fun watchdogGateSurvivesJsonRoundTripAndUnknownInputsStayAbsent() {
        val gate = FeedIncidentWatchdogGate(pathReady = true, repairReady = false, outputExpected = false, hold = "repairNotReady")
        val snapshot = sampleSnapshot(5.0).copy(watchdogGate = gate)
        val bundle = sampleBundle("watchdog-gate").copy(prelude = listOf(snapshot))
        val decoded = assertNotNull(FeedIncidentJson.decode(FeedIncidentJson.encode(bundle)))
        assertEquals(snapshot, decoded.prelude.single())

        val partial = sampleBundle("partial-gate").copy(
            prelude = listOf(sampleSnapshot(5.0).copy(watchdogGate = FeedIncidentWatchdogGate(hold = " " + "x".repeat(80)))),
        )
        val json = JSONObject(String(FeedIncidentJson.encode(partial), Charsets.UTF_8))
        val encodedGate = json.getJSONArray("prelude").getJSONObject(0).getJSONObject("watchdogGate")
        assertEquals(listOf("hold"), encodedGate.keys().asSequence().toList())
        assertEquals(32, encodedGate.getString("hold").length)

        val legacy = JSONObject(String(FeedIncidentJson.encode(sampleBundle("legacy-gate")), Charsets.UTF_8))
        val legacySnapshot = legacy.getJSONArray("prelude").getJSONObject(0)
        assertFalse(legacySnapshot.has("watchdogGate"))
        assertNull(assertNotNull(FeedIncidentJson.decode(legacy.toString().toByteArray(Charsets.UTF_8))).prelude.single().watchdogGate)
        legacySnapshot.put("watchdogGate", JSONObject().put("pathReady", "yes").put("hold", ""))
        val malformed = assertNotNull(FeedIncidentJson.decode(legacy.toString().toByteArray(Charsets.UTF_8))).prelude.single()
        assertEquals(FeedIncidentWatchdogGate(), malformed.watchdogGate, "Wrong types and empty holds are unknown")
    }

    @Test
    fun firstDecodeErrorContextBoundsMatchSwift() {
        val context = FeedIncidentDecodeErrorContext(
            status = 0, nalTypes = List(40) { 99 }, accessUnitBytes = -1,
            irapAge = -1.0, parameterSetChangeAge = Double.POSITIVE_INFINITY,
            inputHz = Double.NaN,
        )
        assertEquals(List(16) { 63 }, context.nalTypes)
        assertEquals(0, context.accessUnitBytes)
        assertEquals(null, context.irapAge)
        assertEquals(null, context.parameterSetChangeAge)
        assertEquals(0.0, context.inputHz)
        val bundle = sampleBundle("bounded-first-error").copy(
            prelude = listOf(sampleSnapshot(5.0).copy(decoder = FeedIncidentDecoder(firstError = context))),
        )
        val decoded = assertNotNull(FeedIncidentJson.decode(FeedIncidentJson.encode(bundle)))
        assertEquals(context, decoded.prelude.single().decoder.firstError)
    }

    @Test
    fun firstDecodeErrorContextSurvivesJsonRoundTripAndIsAbsentOnLegacyRecords() {
        val context = FeedIncidentDecodeErrorContext(
            status = -12909, nalTypes = listOf(1), accessUnitBytes = 1_234,
            irapAge = 0.5, parameterSetChangeAge = null, inputHz = 37.4,
        )
        val snapshot = sampleSnapshot(5.0).copy(
            decoder = FeedIncidentDecoder(lastStatus = -12909, firstError = context),
        )
        val bundle = sampleBundle("first-error-json").copy(prelude = listOf(snapshot))
        val decoded = assertNotNull(FeedIncidentJson.decode(FeedIncidentJson.encode(bundle)))
        assertEquals(snapshot, decoded.prelude.single())
        val legacy = JSONObject(String(FeedIncidentJson.encode(sampleBundle("legacy-first-error")), Charsets.UTF_8))
        assertFalse(legacy.getJSONArray("prelude").getJSONObject(0).getJSONObject("decoder").has("firstError"))
    }

    @Test
    fun legacyJsonOmitsUnknownIngressStatusAndDecoderFields() {
        val encoded = FeedIncidentJson.encode(sampleBundle("legacy-json"))
        val json = JSONObject(String(encoded, Charsets.UTF_8))
        val snapshot = json.getJSONArray("prelude").getJSONObject(0)
        assertFalse(snapshot.has("ingress"))
        assertFalse(snapshot.getJSONObject("ages").has("statusAge"))
        assertFalse(snapshot.getJSONObject("decoder").has("lastStatus"))
        assertFalse(snapshot.getJSONObject("decoder").has("lastFlags"))
        val legacy = assertNotNull(FeedIncidentJson.decode(encoded)).prelude.single()
        assertNull(legacy.ingress)
        assertNull(legacy.ages.statusAge)
        assertNull(legacy.decoder.lastStatus)
        assertNull(legacy.decoder.lastFlags)
        snapshot.put("ingress", JSONObject.NULL)
        snapshot.getJSONObject("decoder").put("lastStatus", JSONObject.NULL).put("lastFlags", JSONObject.NULL)
        val explicitNulls = assertNotNull(FeedIncidentJson.decode(json.toString().toByteArray(Charsets.UTF_8)))
        assertNull(explicitNulls.prelude.single().ingress)
        assertNull(explicitNulls.prelude.single().decoder.lastStatus)
        assertNull(explicitNulls.prelude.single().decoder.lastFlags)
    }

    @Test
    fun missingIngressCountsAndInvalidOptionalAgesRemainUnknown() {
        val ingress = FeedIncidentIngress(4, 13, 7, 2, 1, 5, 3, Double.NaN, -1.0, Double.POSITIVE_INFINITY, true)
        val bundle = sampleBundle("unknown-ingress").copy(prelude = listOf(sampleSnapshot(5.0).copy(
            ages = FeedIncidentAges(packetAge = Double.NaN, accessUnitAge = Double.POSITIVE_INFINITY, statusAge = Double.NaN), ingress = ingress,
        )))
        val encoded = FeedIncidentJson.encode(bundle)
        val decoded = assertNotNull(FeedIncidentJson.decode(encoded)).prelude.single()
        assertNull(decoded.ages.packetAge)
        assertNull(decoded.ages.accessUnitAge)
        assertNull(decoded.ages.statusAge)
        val observation = assertNotNull(decoded.ingress)
        assertEquals(13, observation.receivedDatagrams)
        assertNull(observation.lastDatagramAge)
        assertNull(observation.lastVideoDatagramAge)
        assertNull(observation.lastRegistrationSubmissionAge)
        val json = JSONObject(String(encoded, Charsets.UTF_8))
        json.getJSONArray("prelude").getJSONObject(0).getJSONObject("ingress").remove("videoDatagrams")
        assertNull(assertNotNull(FeedIncidentJson.decode(json.toString().toByteArray(Charsets.UTF_8))).prelude.single().ingress)
    }

    private fun job(id: String, started: Long) =
        FeedIncidentPersistenceJob(
            sampleBundle(id).copy(header = sampleBundle(id).header.copy(incidentId = id, startedAtWallClockMs = started)),
            FeedIncidentPersistenceJob.Reason.STARTED,
        )

    private fun sampleBundle(id: String) =
        FeedIncidentBundle(
            header =
                FeedIncidentHeader(
                    incidentId = id,
                    sessionId = "session-1",
                    kind = FeedIncidentKind.FRESH_INPUT_STALE_OUTPUT,
                    failingStage = FeedIncidentFailingStage.DECODED_OUTPUT,
                    startedAtWallClockMs = 1_000,
                    startedAtMonotonic = 1.0,
                    firstFailureAt = 1.0,
                    worstGapSeconds = 5.0,
                    appVersion = "0.1.0",
                    appBuild = "2",
                    sourceRevision = "abc1234+",
                    osName = "Android",
                    osVersion = "16",
                    hardwareClass = "Pixel",
                    cameraFamily = "pocket",
                ),
            prelude = listOf(sampleSnapshot(0.0)),
        )

    private fun sampleSnapshot(monotonic: Double) =
        FeedIncidentSnapshot(
            monotonicNow = monotonic,
            wallClockMs = 1_000,
            rates = FeedIncidentRates(packetHz = 25.0, decodedOutputHz = 0.0),
            ages = FeedIncidentAges(packetAge = 0.04, decodedOutputAge = 5.0),
            lifecycle = FeedIncidentLifecycle(connected = true, liveEstablished = true),
        )
}
