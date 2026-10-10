package com.opencapture.opencine.media

/** Ordered real source attempts. Integration supplies routing/refusal facts; the consuming
 * library owns lifetime, fresh writers, progress and canonical commit. */
public class MediaTransferPlan(
    expectedByteCount: Long? = null,
    public val attempts: List<suspend (MediaByteSink) -> MediaTransferReceipt>,
    public val retry: (Throwable) -> Boolean,
    public val accepted: ((Int, MediaTransferReceipt) -> Unit)? = null,
) {
    public val expectedByteCount: Long? = expectedByteCount?.takeIf { it > 0 }
}
