package com.opencapture.opencine.appkit

import com.opencapture.opencine.media.MonitorPlaybackItemToken

/** The immutable rated record and actual player item, with captured source/cache admission. */
public class MonitorMediaPlaybackRatingRequest<P> internal constructor(
    public val record: MonitorMediaRecord<P>,
    public val item: MonitorPlaybackItemToken,
    public val admission: MonitorPlaybackAdmission,
) {
    public val isCurrent: Boolean get() = admission.isCurrent()
}

/** Source readback/refusal facts. Jobs and notices belong to the existing player owner. */
public class MonitorMediaPlaybackRatingService<P>(
    public val levels: List<Int>,
    public val noticeMilliseconds: Long = 4_000L,
    public val unavailableMessage: String? = null,
    public val read: suspend (MonitorMediaPlaybackRatingRequest<P>) -> Int?,
    public val commit: suspend (Int, MonitorMediaPlaybackRatingRequest<P>) -> MonitorMediaPictureRatingResult,
)
