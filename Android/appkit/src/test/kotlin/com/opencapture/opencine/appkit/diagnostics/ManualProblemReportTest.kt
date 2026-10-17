package com.opencapture.opencine.appkit.diagnostics

import com.opencapture.monitorui.settings.MonitorReportStatus
import com.opencapture.opencine.media.PrivacyRedactor
import java.io.File
import java.io.IOException
import java.net.URI
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue
import org.json.JSONObject

class ManualProblemReportTest {
    private lateinit var root: File
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
            redact = { PrivacyRedactor.redact(it) },
        )
    private val dsn = ReliabilityReportingDSN()
    private val consent = ReliabilityReportingConsent(dsn)
    private val gate = ReliabilityReportingGate(consent, ReliabilityReportingHostPolicy(), "192.168.2.")
    private val server = FakeUpload()
    private val report = ManualProblemReport(host, dsn, gate, server)

    @BeforeTest
    fun setUp() {
        root = File(System.getProperty("java.io.tmpdir"), "opc-manual-${System.nanoTime()}")
        root.mkdirs()
        consent.resetForTests()
        dsn.buildDsn = null
        dsn.environment = emptyMap()
        gate.resetForTests()
        gate.hostPolicy.requireHttps = false
        report.resetForTests()
        report.filesRoot = root
        report.executeInlineForTests = true
        report.appInForeground = true
        report.envelopeUrlOverride = "http://localhost:8080/api/1/envelope/"
        report.sentryKeyOverride = "publickey"
        gate.setCameraIPv4PathReadyForTests(false)
        gate.setValidInternetForTests(true)
    }

    @AfterTest
    fun tearDown() {
        report.resetForTests()
        consent.resetForTests()
        gate.resetForTests()
        gate.hostPolicy.requireHttps = true
        root.deleteRecursively()
    }

    @Test
    fun settingsStatusHidesIdleAndExplainsAHeldReport() {
        assertNull(ManualProblemReportSnapshot(detail = "Saved").settingsStatus)
        assertEquals(
            MonitorReportStatus("Waiting to send", "This phone keeps one report until Sentry accepts it or you discard it.", "e1"),
            ManualProblemReportSnapshot(ManualProblemReportDelivery.WAITING, eventId = "e1").settingsStatus,
        )
        assertEquals(
            MonitorReportStatus("Failed", "Rejected by Sentry.", null),
            ManualProblemReportSnapshot(ManualProblemReportDelivery.FAILED, detail = "Rejected by Sentry.").settingsStatus,
        )
    }

    @Test
    fun retryAfterPreservesLongDelayAndHttpDate() {
        assertEquals(7_200_000L, parseRetryAfter("7200", 0))
        assertEquals(86_400_000L, parseRetryAfter("Fri, 02 Jan 1970 00:00:00 GMT", 0))
    }

    @Test
    fun storageFailureDoesNotCrashOrClaimQueued() {
        root.deleteRecursively()
        root.writeText("not a directory")
        assertEquals(ManualSubmitResult.STORAGE_ERROR, report.submit("A report", "", null))
        assertEquals(0, server.requestCount)
        assertEquals(ManualProblemReportDelivery.IDLE, report.current().delivery)
    }

    @Test
    fun envelopeKeepsUserMessageAndEmailButRedactsAttachment() {
        val userEmail = "operator.reply@example.com"
        val composed =
            ManualProblemReportEnvelope.compose(
                eventId = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                timestampMs = 1_700_000_000_000L,
                release = "com.opencapture.host@1.0+1",
                message = "Live view froze. Contact $userEmail",
                contactEmail = userEmail,
                diagnostics =
                    "crash /data/user/0/example/cache/report.txt email=secret.tester@example.com password=hunter2",
                host = host,
            )
        assertEquals("feedback", composed.items[0].header.getString("type"))
        val feedback = JSONObject(String(composed.items[0].payload, Charsets.UTF_8))
        assertEquals("feedback", feedback.getString("type"))
        assertEquals("java", feedback.getString("platform"))
        assertEquals("com.opencapture.host@1.0+1", feedback.getString("release"))
        val ctx = feedback.getJSONObject("contexts").getJSONObject("feedback")
        assertEquals("Live view froze. Contact $userEmail", ctx.getString("message"))
        assertEquals(userEmail, ctx.getString("contact_email"))
        assertEquals("custom", ctx.getString("source"))
        assertFalse(feedback.has("user"))
        assertEquals(host.environment, feedback.getString("environment"))
        assertEquals(host.versionCode.toString(), feedback.getString("dist"))
        assertEquals(
            host.sourceRevision.take(64),
            feedback.getJSONObject("tags").getString("sourceRevision"),
        )
        val attachment = composed.items[1]
        assertEquals("attachment", attachment.header.getString("type"))
        assertEquals("diagnostics.txt", attachment.header.getString("filename"))
        assertEquals("text/plain", attachment.header.getString("content_type"))
        val body = String(attachment.payload, Charsets.UTF_8)
        assertFalse(body.contains("secret.tester@example.com"))
        assertTrue(body.contains("<email>"))
        assertFalse(body.contains("hunter2"))
        assertTrue(body.contains("password=<redacted>"))
        assertTrue(body.contains(userEmail).not())
        val bytes = ManualProblemReportEnvelope.serialize(composed)
        val parsed = ManualProblemReportEnvelope.parse(bytes)
        assertEquals("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", parsed.header.getString("event_id"))
        assertEquals(2, parsed.items.size)
    }

    @Test
    fun limitsTruncateMessageEmailAndAttachment() {
        val message = "x".repeat(ManualProblemReport.MESSAGE_MAX + 50)
        val huge = "email=keep-this-out@example.com\n" + "n".repeat(ManualProblemReport.ATTACHMENT_MAX_CHARS + 8_000)
        val composed =
            ManualProblemReportEnvelope.compose(
                eventId = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
                timestampMs = 1L,
                release = "com.opencapture.host@1.0+1",
                message = ManualProblemReportEnvelope.sanitizeMessage(message),
                contactEmail = "operator.reply@example.com",
                diagnostics = huge,
                host = host,
            )
        val feedback = JSONObject(String(composed.items[0].payload, Charsets.UTF_8))
        val ctx = feedback.getJSONObject("contexts").getJSONObject("feedback")
        assertEquals(ManualProblemReport.MESSAGE_MAX, ctx.getString("message").length)
        assertTrue(composed.items[1].payload.size <= ManualProblemReport.ATTACHMENT_MAX_BYTES)
        val attachmentText = String(composed.items[1].payload, Charsets.UTF_8)
        assertTrue(attachmentText.length <= ManualProblemReport.ATTACHMENT_MAX_CHARS)
        assertNull(ManualProblemReportEnvelope.sanitizeEmail("  "))
        assertNull(ManualProblemReportEnvelope.sanitizeEmail("not-an-email"))
        assertNull(ManualProblemReportEnvelope.sanitizeEmail("a".repeat(ManualProblemReport.EMAIL_MAX + 1)))
        assertEquals("", ManualProblemReportEnvelope.sanitizeMessage("   "))
        val snowflake = "é".repeat(80)
        val clipped = ManualProblemReportEnvelope.utf8Prefix(snowflake, 10)
        assertTrue(clipped.toByteArray(Charsets.UTF_8).size <= 10)
    }

    @Test
    fun dsnEndpointIsHttpsEnvelopeOnDsnHost() {
        gate.hostPolicy.requireHttps = true
        val endpoint =
            ManualReportEndpoint.fromDsn("https://publickey@o0.ingest.sentry.io/123")
        assertNotNull(endpoint)
        assertEquals("https://o0.ingest.sentry.io/api/123/envelope/", endpoint.url)
        assertEquals("o0.ingest.sentry.io", endpoint.host)
        assertEquals("publickey", endpoint.sentryKey)
        assertNull(ManualReportEndpoint.fromDsn("http://publickey@o0.ingest.sentry.io/123"))
    }

    @Test
    fun submitDoesNotEnableAutomaticConsentOrStartWithoutExplicitSend() {
        assertFalse(consent.isOptedIn)
        assertEquals(0, root.listFiles()?.size ?: 0)
        val composed =
            ManualProblemReportEnvelope.compose(
                eventId = "cccccccccccccccccccccccccccccccc",
                timestampMs = 1L,
                release = "rel",
                message = "opened the form",
                contactEmail = null,
                diagnostics = null,
                host = host,
            )
        assertEquals(1, composed.items.size)
        assertEquals(0, root.listFiles()?.size ?: 0)
        assertFalse(consent.isOptedIn)
        server.enqueue(200)
        val result =
            report.submit(
                message = "Feed froze after LUT",
                replyEmail = "operator.reply@example.com",
                diagnostics = null,
            )
        assertEquals(ManualSubmitResult.QUEUED, result)
        assertFalse(consent.isOptedIn)
        assertEquals(ManualProblemReportDelivery.SENT, report.current().delivery)
        val recorded = server.takeRequest()
        assertNotNull(recorded)
        assertEquals("/api/1/envelope/", recorded.path)
        assertTrue(recorded.getHeader("X-Sentry-Auth")!!.contains("sentry_key=publickey"))
        assertEquals("application/x-sentry-envelope", recorded.getHeader("Content-Type"))
        val parsed = ManualProblemReportEnvelope.parse(recorded.body)
        val feedback = JSONObject(String(parsed.items[0].payload, Charsets.UTF_8))
        val ctx = feedback.getJSONObject("contexts").getJSONObject("feedback")
        assertEquals("Feed froze after LUT", ctx.getString("message"))
        assertEquals("operator.reply@example.com", ctx.getString("contact_email"))
        assertEquals("custom", ctx.getString("source"))
        assertEquals(1, parsed.items.size)
        assertEquals(ManualSubmitResult.INVALID, report.submit("still broken", "not-an-email", null))
    }

    @Test
    fun missingDsnIsUnavailableAndDoesNotFakeSuccess() {
        report.envelopeUrlOverride = null
        report.sentryKeyOverride = null
        dsn.buildDsn = null
        val result = report.submit("something broke", "", null)
        assertEquals(ManualSubmitResult.UNAVAILABLE, result)
        assertEquals(ManualProblemReportDelivery.IDLE, report.current().delivery)
        assertTrue(root.listFiles().isNullOrEmpty() || root.listFiles()!!.none { it.length() > 0 && it.extension == "envelope" })
        assertEquals(0, server.requestCount)
    }

    @Test
    fun cameraPathQueuesThenSendsOnceAndRejectsDuplicateSubmit() {
        server.enqueue(200)
        val lease = gate.beginCameraPath()
        val first =
            report.submit("Queued on camera Wi-Fi", "", "phase=live email=hidden@example.com")
        assertEquals(ManualSubmitResult.QUEUED, first)
        assertEquals(ManualProblemReportDelivery.WAITING, report.current().delivery)
        assertNull(server.takeRequest())
        val queuedId = report.current().eventId
        val duplicate = report.submit("second", "", null)
        assertEquals(ManualSubmitResult.PENDING_EXISTS, duplicate)
        assertEquals(queuedId, report.current().eventId)
        lease.end()
        report.noteCameraPathClear()
        assertEquals(ManualProblemReportDelivery.SENT, report.current().delivery)
        assertNotNull(server.takeRequest())
        assertEquals(1, server.requestCount)
        val id = report.current().eventId
        assertNotNull(id)
        assertEquals(32, id!!.length)
    }

    @Test
    fun retryAfterAndNonretryableFourHundred() {
        server.enqueue(429, "60")
        report.submit("rate limited", "", null)
        assertEquals(ManualProblemReportDelivery.WAITING, report.current().delivery)
        assertNotNull(server.takeRequest())
        report.flush()
        assertEquals(1, server.requestCount)
        report.discard()
        server.enqueue(400)
        report.submit("bad request", "", null)
        assertEquals(ManualProblemReportDelivery.FAILED, report.current().delivery)
        assertTrue(report.current().allowsDiscard)
        val failedId = report.current().eventId
        assertNotNull(failedId)
        report.discard()
        assertEquals(ManualProblemReportDelivery.IDLE, report.current().delivery)
        assertNull(report.current().eventId)
    }

    @Test
    fun expiredWaitingReportDropsEnvelopeKeepsMetadata() {
        server.enqueue(200)
        var now = 1_000L
        report.nowMs = { now }
        gate.setValidInternetForTests(false)
        report.submit("offline then expired", "operator.reply@example.com", "secret.tester@example.com")
        assertEquals(ManualProblemReportDelivery.WAITING, report.current().delivery)
        assertTrue(File(root, "pending.envelope").isFile)
        now += ManualProblemReport.TTL_MS + 1
        gate.setValidInternetForTests(true)
        report.flush()
        assertEquals(ManualProblemReportDelivery.FAILED, report.current().delivery)
        assertTrue(report.current().detail!!.contains("expired"))
        assertTrue(report.current().expiredMetadataOnly)
        assertFalse(File(root, "pending.envelope").exists())
        assertTrue(File(root, "pending.json").isFile)
        val meta = File(root, "pending.json").readText()
        assertFalse(meta.contains("operator.reply@example.com"))
        assertEquals(0, server.requestCount)
    }

    @Test
    fun discardInvalidatesInFlightResponseAndPreservesNewReport() {
        gate.setValidInternetForTests(false)
        report.submit("first report", "", null)
        val firstId = report.current().eventId!!
        val firstGen = report.currentGeneration()
        report.discard()
        report.submit("second report", "", null)
        val secondId = report.current().eventId!!
        val secondGen = report.currentGeneration()
        assertTrue(secondGen > firstGen)
        assertTrue(secondId != firstId)
        report.finishForTests(firstId, firstGen, 200)
        assertEquals(secondId, report.current().eventId)
        assertEquals(ManualProblemReportDelivery.WAITING, report.current().delivery)
        assertEquals(0, server.requestCount)
    }

    @Test
    fun cameraClearPreservesRetryAfterBackoff() {
        server.enqueue(429, "120")
        report.submit("rate limited then camera", "", null)
        assertEquals(ManualProblemReportDelivery.WAITING, report.current().delivery)
        assertNotNull(server.takeRequest())
        val after429 = File(root, "pending.json").readText()
        val nextAttempt = JSONObject(after429).getLong("nextAttemptAtMs")
        assertTrue(nextAttempt > report.nowMs())
        gate.beginCameraPath().end()
        report.noteCameraPathClear()
        assertEquals(1, server.requestCount)
        val afterClear = JSONObject(File(root, "pending.json").readText())
        assertEquals(nextAttempt, afterClear.getLong("nextAttemptAtMs"))
    }

    @Test
    fun dsnChangeDoesNotSendOldEnvelopeToNewProject() {
        gate.setValidInternetForTests(false)
        report.submit("queued against original DSN", "", null)
        assertEquals(ManualProblemReportDelivery.WAITING, report.current().delivery)
        report.envelopeUrlOverride = null
        dsn.buildDsn = "https://otherkey@o1.ingest.sentry.io/99"
        gate.setValidInternetForTests(true)
        report.flush()
        assertEquals(ManualProblemReportDelivery.FAILED, report.current().delivery)
        assertTrue(report.current().detail!!.contains("destination changed"))
        assertEquals(0, server.requestCount)
        assertFalse(File(root, "pending.envelope").exists())
    }

    @Test
    fun backgroundDoesNotTransmitUntilForeground() {
        server.enqueue(200)
        report.appInForeground = false
        report.submit("typed while backgrounded", "", null)
        assertEquals(ManualProblemReportDelivery.WAITING, report.current().delivery)
        assertNull(server.takeRequest())
        report.setForeground(true)
        assertEquals(ManualProblemReportDelivery.SENT, report.current().delivery)
        assertNotNull(server.takeRequest())
    }

    @Test
    fun imageAttachmentsUseGeneratedJpegNamesWithoutExifOrOriginalFilename() {
        val jpeg = jpegFixture(256)
        val composed =
            ManualProblemReportEnvelope.compose(
                eventId = "dddddddddddddddddddddddddddddddd",
                timestampMs = 1L,
                release = "com.opencapture.host@1.0+1",
                message = "black live view",
                contactEmail = null,
                diagnostics = null,
                images = listOf(jpeg),
                host = host,
            )
        assertEquals(2, composed.items.size)
        val image = composed.items[1]
        assertEquals("attachment", image.header.getString("type"))
        assertEquals("image-1.jpg", image.header.getString("filename"))
        assertEquals("image/jpeg", image.header.getString("content_type"))
        assertTrue(image.payload.contentEquals(jpeg))
        assertFalse(image.header.toString().contains("DSC_"))
        assertFalse(ManualReportImages.containsExif(image.payload))
        assertNull(ManualReportImages.accept(listOf(jpegFixture(64, exif = true))))
        assertNull(ManualReportImages.accept(listOf("not-an-image".toByteArray())))
        assertNull(ManualReportImages.accept(List(4) { jpegFixture(64) }))
        assertNull(ManualReportImages.accept(listOf(jpegFixture(ManualReportImages.MAX_EACH_BYTES + 1))))
        val almost = jpegFixture(ManualReportImages.MAX_EACH_BYTES)
        assertEquals(3, ManualReportImages.accept(listOf(almost, almost, almost))!!.size)
    }

    @Test
    fun queuedEnvelopeRoundtripsImageBytesAndRejectsInvalidCountWithoutWriting() {
        gate.setValidInternetForTests(false)
        val jpeg = jpegFixture(512)
        val result =
            report.submit(
                message = "with photo",
                replyEmail = "",
                diagnostics = "phase=live",
                images = listOf(jpeg, jpegFixture(128)),
            )
        assertEquals(ManualSubmitResult.QUEUED, result)
        assertEquals(ManualProblemReportDelivery.WAITING, report.current().delivery)
        val envelopeBytes = File(root, "pending.envelope").readBytes()
        val parsed = ManualProblemReportEnvelope.parse(envelopeBytes)
        assertEquals(4, parsed.items.size)
        assertEquals("diagnostics.txt", parsed.items[1].header.getString("filename"))
        assertEquals("image-1.jpg", parsed.items[2].header.getString("filename"))
        assertEquals("image/jpeg", parsed.items[2].header.getString("content_type"))
        assertEquals("image-2.jpg", parsed.items[3].header.getString("filename"))
        assertTrue(parsed.items[2].payload.contentEquals(jpeg))
        val restored = ManualProblemReportEnvelope.parse(File(root, "pending.envelope").readBytes())
        assertEquals(parsed.items.size, restored.items.size)
        assertTrue(restored.items[2].payload.contentEquals(jpeg))
        report.discard()
        assertEquals(
            ManualSubmitResult.INVALID,
            report.submit("too many", "", null, List(4) { jpegFixture(64) }),
        )
        assertEquals(ManualProblemReportDelivery.IDLE, report.current().delivery)
        assertFalse(File(root, "pending.envelope").exists())
        assertFalse(consent.isOptedIn)
    }

    private fun jpegFixture(size: Int, exif: Boolean = false): ByteArray {
        val bytes = ByteArray(size.coerceAtLeast(24))
        bytes[0] = 0xFF.toByte()
        bytes[1] = 0xD8.toByte()
        bytes[2] = 0xFF.toByte()
        if (exif) {
            bytes[3] = 0xE1.toByte()
            bytes[4] = 0x00
            bytes[5] = 0x10
            byteArrayOf(0x45, 0x78, 0x69, 0x66, 0x00, 0x00).copyInto(bytes, 6)
        } else {
            bytes[3] = 0xE0.toByte()
            bytes[4] = 0x00
            bytes[5] = 0x10
            byteArrayOf(0x4A, 0x46, 0x49, 0x46, 0x00).copyInto(bytes, 6)
        }
        bytes[bytes.lastIndex - 1] = 0xFF.toByte()
        bytes[bytes.lastIndex] = 0xD9.toByte()
        return bytes
    }

    /** Records each POST and answers from a queue, like the mock server the apps use. */
    private class FakeUpload : ManualReportUpload {
        class Sent(val url: String, val contentType: String, val body: ByteArray, val headers: Map<String, String>) {
            val path: String get() = URI(url).path
            fun getHeader(name: String): String? = headers[name]
        }

        private val sent = mutableListOf<Sent>()
        private val responses = ArrayDeque<ManualReportResponse>()
        private var taken = 0
        val requestCount: Int get() = sent.size

        fun enqueue(code: Int, retryAfter: String? = null) {
            responses.addLast(ManualReportResponse(code, retryAfter))
        }

        fun takeRequest(): Sent? = sent.getOrNull(taken)?.also { taken += 1 }

        override fun call(url: String, contentType: String, body: ByteArray, headers: Map<String, String>): ManualReportCall =
            object : ManualReportCall {
                private var canceled = false

                override fun execute(): ManualReportResponse {
                    if (canceled) throw IOException("Canceled")
                    sent += Sent(url, contentType, body, headers)
                    return responses.removeFirstOrNull() ?: throw IOException("no response")
                }

                override fun cancel() {
                    canceled = true
                }

                override val isCanceled: Boolean
                    get() = canceled
            }
    }
}
