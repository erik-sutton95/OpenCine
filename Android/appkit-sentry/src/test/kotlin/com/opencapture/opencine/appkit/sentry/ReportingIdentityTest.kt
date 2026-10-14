package com.opencapture.opencine.appkit.sentry

import com.opencapture.opencine.appkit.diagnostics.ReliabilityEvent
import com.opencapture.opencine.appkit.diagnostics.ReliabilityEventLevel
import io.sentry.Hint
import io.sentry.ScopeObserverAdapter
import io.sentry.Sentry
import io.sentry.SentryEvent
import io.sentry.SentryMetricsEvent
import io.sentry.protocol.SentryException
import io.sentry.protocol.SentryId
import io.sentry.protocol.User
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CopyOnWriteArrayList
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** What the adapter stamps on, keeps in and keeps out of what the SDK sends. */
class ReportingIdentityTest {
    private val consent = Fixture.consent

    @AfterTest
    fun tearDown() {
        Sentry.close()
        consent.resetForTests()
    }

    @Test
    fun incidentTagsStayOnTheirEventAndNeverReachTheNativeScope() {
        val observed = ConcurrentHashMap<String, String>()
        val sent = CopyOnWriteArrayList<SentryEvent>()
        Sentry.init { options ->
            options.dsn = "https://publickey@o0.ingest.sentry.io/0"
            // Stands in for the NDK and persisting observers, which see every scope tag.
            options.addScopeObserver(
                object : ScopeObserverAdapter() {
                    override fun setTag(key: String, value: String) {
                        observed[key] = value
                    }

                    override fun setTags(tags: Map<String, String>) {
                        observed.putAll(tags)
                    }
                },
            )
            options.setBeforeSend { event, _ ->
                sent.add(event)
                null
            }
        }
        val incident =
            ReliabilityEvent(
                eventId = "12c2d058d58442709aa2eca08bf20986",
                level = ReliabilityEventLevel.WARNING,
                timestampMs = 1_780_000_000_000L,
                release = Fixture.host.release("0.1.0", "107"),
                dist = "107",
                message = "feed incident decodedOutput: transportStall",
                fingerprints = listOf("feed-incident", "schema:1", "kind:transportStall"),
                tags = mapOf("kind" to "sessionSummary", "outcome" to "interrupted", "failingStage" to "decodedOutput"),
                extras = emptyMap(),
                contexts = emptyMap(),
            )
        SentryReliabilitySink(Fixture.reporting).capture(incident, "{}".toByteArray(), "incident.json")
        assertEquals("interrupted", sent.single().tags?.get("outcome"), "the event keeps its own tags")
        assertTrue(
            observed.keys.none { it in setOf("kind", "outcome", "failingStage") },
            "scope observers saw incident tags: $observed",
        )
    }

    @Test
    fun eventsCarryOnlyTheAnonymousInstallIdAsUser() {
        consent.setOptedIn(true)
        val options = makeOptions("https://publickey@o0.ingest.sentry.io/0", Fixture.reporting)
        val event =
            SentryEvent().apply {
                user =
                    User().apply {
                        id = "device-name"
                        email = "tester@example.com"
                        ipAddress = "192.0.2.1"
                    }
            }
        val sent = assertNotNull(options.beforeSend?.execute(event, Hint()))
        val installId = assertNotNull(consent.installId)
        assertEquals(installId, sent.user?.id)
        assertNull(sent.user?.email)
        assertNull(sent.user?.ipAddress)
        consent.setOptedIn(false)
        assertNull(options.beforeSend?.execute(SentryEvent(), Hint()))
    }

    @Test
    fun anrTextSurvivesTheScrubButOtherExceptionTextDoesNot() {
        val event =
            SentryEvent().apply {
                exceptions =
                    listOf(
                        SentryException().apply { value = "Application Not Responding for at least 5000 ms." },
                        SentryException().apply { value = "Attempt to read tester@example.com" },
                    )
            }
        Fixture.reporting.privacy.scrub(event)
        assertEquals("Application Not Responding for at least 5000 ms.", event.exceptions?.get(0)?.value)
        assertEquals("Native exception", event.exceptions?.get(1)?.value)
    }

    @Test
    fun onlyTheSharedSessionMetricsLeaveThePhoneUnderConsent() {
        consent.setOptedIn(true)
        val filter = assertNotNull(makeOptions("https://publickey@o0.ingest.sentry.io/0", Fixture.reporting).metrics.beforeSend)
        fun metric(name: String) = SentryMetricsEvent(SentryId(), 0.0, name, "distribution", 1.0)
        assertNotNull(filter.execute(metric("feed.session.incidents"), Hint()))
        assertNotNull(filter.execute(metric("feed.session.healthy_exposure"), Hint()))
        assertNull(filter.execute(metric("app.other"), Hint()))
        consent.setOptedIn(false)
        assertNull(filter.execute(metric("feed.session.incidents"), Hint()))
    }
}
