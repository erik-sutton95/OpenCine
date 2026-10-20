package com.opencapture.opencine.media

import java.net.URI
import java.util.UUID
import kotlin.time.Duration

/** One native item lifetime. Clip changes and close retire its callbacks. */
public data class MonitorPlaybackItemToken(public val owner: UUID, public val revision: Long)
/** One pointer edit within an item; cancellation/new begin retires its old input. */
public data class MonitorPlaybackScrubToken(public val item: MonitorPlaybackItemToken, public val edit: UUID = UUID.randomUUID())
public data class MonitorPlaybackItem(
    public val url: URI, public val mimeType: String, public val sourceKey: String,
    public val role: MediaRepresentationRole = MediaRepresentationRole.ORIGINAL,
    public val isRemote: Boolean = false,
)
public data class MonitorPlaybackMetadata(
    public val duration: Double? = null, public val width: Double? = null, public val height: Double? = null,
    public val conform: MonitorConformPreview.Source = MonitorConformPreview.Source(),
)
/** Observed native transport, separate from the operator's requested play state. */
public enum class MonitorPlaybackTransportState { PAUSED, WAITING, PLAYING }
public sealed interface MonitorPlaybackEvent {
    /** Native item attached and preparation requested; not a decoded/ready frame. */
    public data object ItemInstalled : MonitorPlaybackEvent
    public data class Position(public val seconds: Double?) : MonitorPlaybackEvent
    public data class Playing(public val value: Boolean?) : MonitorPlaybackEvent
    /** Waiting retains play intent while the native clock is stalled. Null is unobserved. */
    public data class Transport(public val value: MonitorPlaybackTransportState?) : MonitorPlaybackEvent
    public data class Metadata(public val value: MonitorPlaybackMetadata) : MonitorPlaybackEvent
    public data object Ended : MonitorPlaybackEvent
    public data class Failed(public val message: String) : MonitorPlaybackEvent
}
public enum class MonitorPlaybackFailure { RETIRED, UNAVAILABLE, NATIVE_FAILURE }
public enum class MonitorPlaybackLookTiming { BEFORE_NATIVE_PREPARATION, AFTER_NATIVE_READINESS }
public enum class MonitorPlaybackStartTiming { AFTER_NATIVE_ITEM_INSTALLATION, AFTER_NATIVE_READINESS }
/**
 * Whether returning from an inactive scene retains the operator's earlier play request.
 * The shared playback owner defaults to [CLEAR_REQUEST]: losing the scene pauses and forgets
 * the request, so returning never restarts sound by itself.
 */
public enum class MonitorPlaybackSceneLossPolicy { PRESERVE_REQUEST, CLEAR_REQUEST }
public class MonitorPlaybackException(public val failure: MonitorPlaybackFailure) : IllegalStateException(failure.name)
/** Confined to the caller's native owner dispatcher. Actual OS/SDK APIs remain in its adapter. */
public interface MonitorPlaybackPort {
    public var onEvent: ((MonitorPlaybackItemToken, MonitorPlaybackEvent) -> Unit)?
    public fun retireItem(token: MonitorPlaybackItemToken)
    public suspend fun prepare(item: MonitorPlaybackItem, token: MonitorPlaybackItemToken, readyTimeout: Duration?): MonitorPlaybackMetadata
    public fun play(rate: Double, token: MonitorPlaybackItemToken)
    public fun pause(token: MonitorPlaybackItemToken)
    public suspend fun seek(seconds: Double, tolerance: Double, token: MonitorPlaybackItemToken): Boolean
    public fun setMuted(muted: Boolean, token: MonitorPlaybackItemToken)
    public fun close(token: MonitorPlaybackItemToken)
}
