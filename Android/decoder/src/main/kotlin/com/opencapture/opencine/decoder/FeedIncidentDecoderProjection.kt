package com.opencapture.opencine.decoder

import com.opencapture.opencine.media.DecoderErrorOrigin
import com.opencapture.opencine.media.FeedDecoderErrorOrigin
import com.opencapture.opencine.media.FeedIncidentDecoder
import com.opencapture.opencine.media.FeedIncidentRateSampler

/** Read-only diagnostic projection, with observation boundaries supplied by the source owner. */
public fun HevcDecoder.incidentDecoder(nowElapsedMs: Long,
    generation: Int = randomAccess.generation,
    codec: String = if (hasFormat) "hevc" else "unknown",
    errorNotBefore: Long? = null,
    outputAge: Double? = FeedIncidentRateSampler.ageMilliseconds(lastDecoderOutputAt, nowElapsedMs),
    receivedIrap: Boolean = hasDecodableReferences,
): FeedIncidentDecoder {
    val error = errorLifetime.lastError?.takeIf { errorNotBefore == null || it.atElapsedMs >= errorNotBefore }
    return FeedIncidentDecoder(generation = generation, formatGeneration = errorLifetime.formatGeneration,
        codec = codec, width = pictureWidth, height = pictureHeight,
        origin = when (error?.origin) {
            DecoderErrorOrigin.CONFIGURE -> FeedDecoderErrorOrigin.CREATE
            DecoderErrorOrigin.QUEUE -> FeedDecoderErrorOrigin.SYNC
            DecoderErrorOrigin.OUTPUT, DecoderErrorOrigin.OUTPUT_RELEASE -> FeedDecoderErrorOrigin.CALLBACK
            null -> FeedDecoderErrorOrigin.NONE
        }, errorClass = error?.code, errorCall = error?.call?.wire, errorCount = errorLifetime.countThisGeneration,
        decoderFailed = error != null && failedThisGeneration,
        errorAge = FeedIncidentRateSampler.ageMilliseconds(error?.atElapsedMs, nowElapsedMs),
        receivedIrap = receivedIrap, awaitingIrap = awaitingIdr,
        hasDecodableReferences = hasDecodableReferences,
        lastIrapAge = FeedIncidentRateSampler.ageMilliseconds(lastIrapAt, nowElapsedMs),
        lastSuccessfulOutputAge = outputAge)
}
