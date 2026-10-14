package com.opencapture.opencine.appkit.diagnostics

import com.opencapture.opencine.media.FeedIncidentSessionContext
import com.opencapture.opencine.media.FeedIncidentTestSource
import java.util.UUID

/** Shared host/device vocabulary, with observed camera values supplied by the producer. */
public class FeedIncidentProducerContext(
    private val host: DiagnosticsHost,
    private val device: DiagnosticsDevice = DiagnosticsDevice.current(),
) {
    public fun make(sessionId: String = UUID.randomUUID().toString(), cameraFamily: String,
        cameraFirmware: String? = null, decoderGeneration: Int = 0, socketGeneration: Int = 0,
        testSource: FeedIncidentTestSource = FeedIncidentTestSource.UNKNOWN,
        buildIdentity: String = "unknown",
    ): FeedIncidentSessionContext = FeedIncidentSessionContext(token(sessionId, 96), token(host.versionName, 32),
        token(host.versionCode.toString(), 32), token(host.sourceRevision, 64), token(device.osName, 16),
        token(device.osVersion, 64), token(device.hardwareClass, 32), token(cameraFamily, 32),
        cameraFirmware?.let { token(it, 32) }, decoderGeneration.coerceAtLeast(0), socketGeneration.coerceAtLeast(0),
        testSource, token(buildIdentity, 64).ifEmpty { "unknown" })

    // Scrub the raw value before shortening, so a truncated secret cannot become an innocent token.
    private fun token(raw: String, limit: Int): String = host.redact(raw).trim().take(limit)
}
