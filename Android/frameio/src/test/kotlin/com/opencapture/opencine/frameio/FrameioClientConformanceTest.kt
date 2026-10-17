package com.opencapture.opencine.frameio

import com.opencapture.opencine.appkit.MonitorDeliveryAdmission
import java.util.Base64
import kotlin.test.Test
import kotlin.test.assertContains
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertTrue
import kotlinx.coroutines.test.runTest

/**
 * The Android owner against the Swift FrameioClient contract (Tests/OpenCineFrameIOTests/
 * FrameioClientTests.swift): the same plans, polls and token windows over SIMULATED ports.
 * Response decoding itself is the shared Swift core's (OpenCineFrameIOAndroidTests).
 */
class FrameioClientConformanceTest {
    @Test
    fun `platform digest matches the RFC 7636 PKCE vector`() {
        val digest = FrameioNative.sha256("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk".toByteArray(Charsets.US_ASCII))

        assertEquals("E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM", Base64.getUrlEncoder().withoutPadding().encodeToString(digest))
    }

    @Test
    fun `upload puts each part then polls until confirmed`() = runTest {
        withReadyRoot { root ->
            // Swift createdTwoParts: 3 + 2 bytes, video/quicktime; the first status poll is false.
            val core = FakeCore(partSizes = listOf(3, 2), mediaType = "video/quicktime", uploadComplete = { poll -> poll > 0 })
            val http = FakeHttp()
            var pauses = 0
            val controller = connectedController(root, core = core, http = http, uploadStatusPoll = { pauses += 1 })
            val progress = mutableListOf<Double>()

            controller.upload(root.clip("C0001.MOV", size = 5), "C0001.MOV", SAVED_DESTINATION,
                MonitorDeliveryAdmission { true }, null) { progress += it }

            assertEquals(listOf(FrameioCoreOperation.CREATE_FILE, FrameioCoreOperation.UPLOAD_STATUS,
                FrameioCoreOperation.UPLOAD_STATUS), core.apiOperations)
            assertEquals(listOf(5L), core.createdSizes)
            assertEquals(listOf(
                SentPart("https://uploads.example.invalid/part1", 0, 3, "video/quicktime"),
                SentPart("https://uploads.example.invalid/part2", 3, 2, "video/quicktime"),
            ), http.parts)
            // API calls carry the bearer token; parts are pre-signed and never do.
            assertEquals(listOf<String?>("unit-access", "unit-access", "unit-access"), http.bearerTokens)
            assertEquals(1, pauses)
            assertFractions(listOf(0.05, 0.1 + 0.75 * 3 / 5, 0.85, 0.85, 1.0), progress)
            assertEquals(progress.sorted(), progress, "progress never goes backwards")
        }
    }

    @Test
    fun `upload rejects a plan that does not match the file before sending bytes`() = runTest {
        withReadyRoot { root ->
            val core = FakeCore(partSizes = listOf(3, 2))
            val http = FakeHttp()
            val controller = connectedController(root, core = core, http = http)

            val failure = assertFailsWith<FrameioDeliveryException> {
                controller.upload(root.clip("C0001.MOV", size = 6), "C0001.MOV", SAVED_DESTINATION,
                    MonitorDeliveryAdmission { true }, null) {}
            }

            assertContains(failure.message.orEmpty(), "did not match the approved media size")
            assertEquals(listOf(FrameioCoreOperation.CREATE_FILE), core.apiOperations)
            assertEquals(0, http.uploadCalls)
        }
    }

    @Test
    fun `upload gives up when Frameio never confirms`() = runTest {
        withReadyRoot { root ->
            val core = FakeCore(partSizes = listOf(3, 2), uploadComplete = { false })
            var pauses = 0
            val controller = connectedController(root, core = core, uploadStatusPoll = { pauses += 1 })
            val progress = mutableListOf<Double>()

            val failure = assertFailsWith<FrameioDeliveryException> {
                controller.upload(root.clip("C0001.MOV", size = 5), "C0001.MOV", SAVED_DESTINATION,
                    MonitorDeliveryAdmission { true }, null) { progress += it }
            }

            assertContains(failure.message.orEmpty(), "did not confirm")
            assertEquals(45, pauses)
            assertEquals(45, core.statusPolls)
            assertEquals(0.85 + 0.1 * 44 / 45, progress.last(), 1e-9)
            assertFalse(1.0 in progress)
        }
    }

    @Test
    fun `http failure surfaces the status but never the body`() = runTest {
        withReadyRoot { root ->
            val http = FakeHttp(respond = { FrameioHttpResponse(403, "nope private-body") })
            val controller = connectedController(root, http = http)

            val failure = assertFailsWith<FrameioDeliveryException> { controller.loadProjectsCaptured { true } }

            assertContains(failure.message.orEmpty(), "HTTP 403")
            assertFalse(failure.message.orEmpty().contains("private-body"))
        }
    }

    @Test
    fun `missing token fails without any request`() = runTest {
        withReadyRoot { root ->
            val http = FakeHttp()
            val controller = connectedController(root, http = http, secrets = MemorySecretStore())

            assertFailsWith<FrameioDeliveryException> { controller.loadProjectsCaptured { true } }

            assertEquals(0, http.executeCalls)
        }
    }

    @Test
    fun `near expiry refreshes first and keeps the refresh token IMS omitted`() = runTest {
        withReadyRoot { root ->
            // 30 s before expiry: inside the 60 s early-refresh window.
            val now = 1_000_000L
            val secrets = MemorySecretStore(FrameioSecretState(
                FrameioStoredToken("AT", "RT", now + 30_000L, "Bearer"), null))
            val core = FakeCore(refreshedToken = FrameioAccessToken("AT2", null, 3_600, "bearer"))
            val http = FakeHttp()
            val controller = connectedController(root, core = core, http = http, secrets = secrets, clock = { now })

            val listing = controller.loadProjectsCaptured { true }

            assertEquals("account", listing.listing.accountID)
            assertEquals(listOf("refresh"), core.tokenKinds)
            assertEquals(listOf<String?>("RT"), core.tokenRefreshTokens)
            assertEquals(listOf(null, "AT2", "AT2", "AT2"), http.bearerTokens)
            assertEquals("AT2", secrets.state.token?.accessToken)
            assertEquals("RT", secrets.state.token?.refreshToken)
            assertEquals(now + 3_600_000L, secrets.state.token?.expiresAtEpochMillis)
        }
    }

    @Test
    fun `fresh token is used without refresh`() = runTest {
        withReadyRoot { root ->
            val now = 1_000_000L
            val secrets = MemorySecretStore(FrameioSecretState(
                FrameioStoredToken("AT", "RT", now + 600_000L, "Bearer"), null))
            val core = FakeCore()
            val http = FakeHttp()
            val controller = connectedController(root, core = core, http = http, secrets = secrets, clock = { now })

            controller.loadProjectsCaptured { true }

            assertTrue(core.tokenKinds.isEmpty())
            assertEquals(listOf<String?>("AT", "AT", "AT"), http.bearerTokens)
        }
    }

    @Test
    fun `rejected refresh signs out instead of retrying with stale credentials`() = runTest {
        withReadyRoot { root ->
            val secrets = MemorySecretStore(FrameioSecretState(FrameioStoredToken("AT", "RT", 0L, "Bearer"), null))
            val http = FakeHttp(respond = { request ->
                FrameioHttpResponse(if (request.url.startsWith("https://ims.")) 400 else 200, "{}")
            })
            val controller = connectedController(root, http = http, secrets = secrets)

            assertFailsWith<FrameioDeliveryException> { controller.loadProjectsCaptured { true } }

            assertEquals(null, secrets.state.token)
            assertEquals(FrameioConnectionState.SIGNED_OUT, controller.connectionState)
            assertEquals(1, http.executeCalls)
        }
    }

    private fun assertFractions(expected: List<Double>, actual: List<Double>) {
        assertEquals(expected.size, actual.size, "fractions: $actual")
        expected.zip(actual).forEach { (value, reported) -> assertEquals(value, reported, 1e-9, "fractions: $actual") }
    }
}
