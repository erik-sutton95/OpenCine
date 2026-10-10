package com.opencapture.opencine.relayruntime

import java.util.UUID
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.filter
import kotlinx.coroutines.flow.map

public data class RelayPictureDecode(public val jpeg: ByteArray?, public val exhausted: Boolean = false)

/** Native ports consume a captured producer identity. Wire metadata stays a typed host value. */
public interface RelayPictureDecoder<Metadata> {
    public fun beginSource(source: UUID): Unit
    public fun decode(source: UUID, metadata: Metadata, bytes: ByteArray): RelayPictureDecode
    public fun retireSource(source: UUID): Unit
    public fun close(): Unit
}

public data class RelayPicturePolicy(
    public val extraFrameCapacity: Int = 2,
    public val previousCadenceWeight: Double = 0.8,
    public val latestCadenceWeight: Double = 0.2,
    public val minimumCadenceDeltaSeconds: Double = 0.0001,
) {
    init {
        require(extraFrameCapacity >= 0 && previousCadenceWeight in 0.0..1.0)
        require(latestCadenceWeight in 0.0..1.0)
        require(minimumCadenceDeltaSeconds >= 0 && minimumCadenceDeltaSeconds.isFinite())
    }
}

/** Measured output facts, never a queued target or a fabricated camera report. */
public data class RelayPictureReading(
    public val source: UUID,
    public val timestampNanos: Long,
    public val framesPerSecond: Double?,
)

public data class RelayPicturePublication<Frame>(public val source: UUID, public val frame: Frame)

/**
 * Source-owned native admission, actual decoded evidence, replay, measured cadence and bounded
 * exhaustion reporting. Frame projection supplies source-specific observations only.
 */
public class RelayDecodedPictureOwner<Metadata, Frame>(
    private val decoder: RelayPictureDecoder<Metadata>,
    private val project: (Metadata, ByteArray, RelayPictureReading) -> Frame,
    private val policy: RelayPicturePolicy = RelayPicturePolicy(),
    private val nowNanos: () -> Long = System::nanoTime,
) {
    private class Window(val source: UUID) {
        var timestamp: Long = 0L
        var cadence: Double? = null
        var hasDecoded: Boolean = false
        var reportedExhaustion: Boolean = false
    }
    private val lock: Any = Any()
    private var current: Window? = null
    private var closed: Boolean = false
    private val published: MutableSharedFlow<RelayPicturePublication<Frame>> = MutableSharedFlow(replay = 1, extraBufferCapacity = policy.extraFrameCapacity)
    private val decoded: MutableSharedFlow<UUID> = MutableSharedFlow(replay = 1, extraBufferCapacity = 2)
    public val publications: SharedFlow<RelayPicturePublication<Frame>> = published.asSharedFlow()
    public val frames: Flow<Frame> = published.filter { synchronized(lock) { !closed && current?.source == it.source } }.map { it.frame }
    public val decodedSources: Flow<UUID> = decoded.asSharedFlow()
    public var onExhausted: ((UUID) -> Unit)? = null
    public val currentSource: UUID? get() = synchronized(lock) { current?.source }
    public fun hasDecoded(source: UUID): Boolean = synchronized(lock) { current?.let { it.source == source && it.hasDecoded } == true }

    @OptIn(ExperimentalCoroutinesApi::class)
    public fun beginSource(source: UUID): Boolean {
        val window = synchronized(lock) {
            if (closed) return false
            Window(source).also { current = it; published.resetReplayCache() }
        }
        decoder.beginSource(source)
        return synchronized(lock) { !closed && current === window }
    }

    public fun submit(source: UUID, metadata: Metadata, bytes: ByteArray): Boolean {
        val window = synchronized(lock) { current?.takeIf { !closed && it.source == source } } ?: return false
        val result = decoder.decode(source, metadata, bytes)
        if (result.jpeg == null) {
            val report = synchronized(lock) {
                if (closed || current !== window || !result.exhausted || window.reportedExhaustion) false
                else { window.reportedExhaustion = true; true }
            }
            if (report) onExhausted?.invoke(source)
            return false
        }
        val at = nowNanos()
        val reading = synchronized(lock) {
            if (closed || current !== window) null else {
                val delta = (at - window.timestamp) / 1_000_000_000.0
                val cadence = if (window.timestamp > 0 && delta > policy.minimumCadenceDeltaSeconds) {
                    val instantaneous = 1.0 / delta
                    window.cadence?.let { it * policy.previousCadenceWeight + instantaneous * policy.latestCadenceWeight }
                        ?: instantaneous
                } else window.cadence
                RelayPictureReading(source, at, cadence)
            }
        } ?: return false
        val frame = project(metadata, result.jpeg, reading)
        return synchronized(lock) {
            if (closed || current !== window) false else {
                window.timestamp = at
                window.cadence = reading.framesPerSecond
                window.hasDecoded = true
                published.tryEmit(RelayPicturePublication(source, frame))
                decoded.tryEmit(source)
                true
            }
        }
    }

    public fun retireSource(source: UUID): Boolean {
        val retired = synchronized(lock) {
            if (closed || current?.source != source) false else { current = null; true }
        }
        if (retired) decoder.retireSource(source)
        return retired
    }
    public fun close(): Unit {
        val retire = synchronized(lock) {
            if (closed) false else { closed = true; current = null; true }
        }
        if (retire) decoder.close()
    }
}
