package com.opencapture.opencine.appkit

import com.opencapture.opencine.media.MediaAssetID

/** Actual alternate images of one shot; file/wire format policy belongs to the source. */
public data class MonitorMediaPictureVariant<P>(public val label: String, public val record: MonitorMediaRecord<P>) {
    public val id: MediaAssetID get() = record.asset.id
}

public sealed interface MonitorMediaPictureRatingResult {
    public data class Confirmed(public val value: Int) : MonitorMediaPictureRatingResult
    public data class Refused(public val message: String?) : MonitorMediaPictureRatingResult
    public data object Unavailable : MonitorMediaPictureRatingResult
}
public class MonitorMediaPictureRatingService<P>(public val levels: List<Int>,
    public val read: suspend (MonitorMediaPictureRequest<P>) -> Int?,
    public val commit: suspend (Int, MonitorMediaPictureRequest<P>) -> MonitorMediaPictureRatingResult)

public enum class MonitorMediaPictureShareReadiness { READY, WAITING, UNAVAILABLE }

/** The existing transfer/cache reports readiness; the picture owner schedules waiting/cancel. */
public class MonitorMediaPictureSharing<P>(public val readiness: (MonitorMediaPictureRequest<P>) -> MonitorMediaPictureShareReadiness,
    public val perform: (suspend (MonitorMediaPictureRequest<P>) -> Unit)? = null)

public data class MonitorMediaPictureStatus(public val message: String? = null, public val progress: Double? = null,
    public val showsRating: Boolean = true)

/** Progressive native decode results can reach only their captured load. */
public class MonitorMediaPicturePublication<P, I> internal constructor(public val request: MonitorMediaPictureRequest<P>,
    private val picture: (I) -> Unit, private val status: (MonitorMediaPictureStatus) -> Unit) {
    public val isCurrent: Boolean get() = request.isCurrent()
    public fun publish(value: I): Unit { if (isCurrent) picture(value) }
    public fun publish(status: MonitorMediaPictureStatus): Unit { if (isCurrent) this.status(status) }
}
