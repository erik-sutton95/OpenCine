package com.opencapture.opencine.media

import java.io.EOFException
import java.io.IOException
import java.io.InterruptedIOException
import java.nio.ByteBuffer
import java.nio.channels.ClosedChannelException
import java.nio.channels.FileChannel
import kotlin.math.min

/** A positional reader whose temporary EOF waits for the shared transfer owner. */
public class ProgressiveMediaCacheReader internal constructor(
    private val entry: ProgressiveMediaCacheEntry,
) : AutoCloseable {
    private val lifecycleLock = Any()
    @Volatile private var opened = false
    @Volatile private var closed = false
    @Volatile private var channel: FileChannel? = null
    private var currentPosition = 0L
    private var bytesRemaining = 0L

    /** A null length reads the remaining object; a finite length bounds a seek/range request. */
    public fun openAt(position: Long, length: Long? = null): Long {
        require(position >= 0) { "position must not be negative." }
        require(length == null || length >= 0) { "length must not be negative." }
        if (position > entry.expectedLength) {
            throw EOFException("Position $position exceeds media length ${entry.expectedLength}.")
        }
        synchronized(lifecycleLock) {
            if (opened) throw IOException("Growing media data source is already open.")
            val openedChannel = entry.openReadableChannel()
            closed = false
            opened = true
            currentPosition = position
            val available = entry.expectedLength - position
            bytesRemaining = length?.let { min(it, available) } ?: available
            channel = openedChannel
            return bytesRemaining
        }
    }

    /** Returns -1 only at a completed object or the requested range boundary. */
    public fun read(buffer: ByteArray, offset: Int, length: Int): Int {
        require(offset >= 0 && length >= 0 && offset <= buffer.size && length <= buffer.size - offset) {
            "Invalid destination range."
        }
        if (closed) throw ClosedChannelException()
        if (!opened) throw IOException("Growing media data source is not open.")
        if (length == 0) return 0
        if (bytesRemaining == 0L) return -1

        val snapshot = entry.awaitReadable(currentPosition) { closed }
        if (closed) throw ClosedChannelException()
        val available = snapshot.availableLength - currentPosition
        if (available <= 0) {
            return when (snapshot.state) {
                ProgressiveMediaCacheState.COMPLETE -> -1
                ProgressiveMediaCacheState.FAILED -> throw IOException("Camera media transfer failed.", snapshot.failure)
                ProgressiveMediaCacheState.CANCELLED -> throw InterruptedIOException("Camera media transfer was cancelled.")
                ProgressiveMediaCacheState.ACTIVE -> throw EOFException("Media cache length changed while reading.")
            }
        }
        val requested = min(length.toLong(), min(available, bytesRemaining)).toInt()
        val activeChannel = channel ?: throw ClosedChannelException()
        val count = activeChannel.read(ByteBuffer.wrap(buffer, offset, requested), currentPosition)
        if (count <= 0) throw EOFException("Media cache advertised bytes that could not be read.")
        currentPosition += count
        bytesRemaining -= count
        return count
    }

    /** Wakes this reader without stopping or discarding a resumable transfer. */
    override fun close() {
        val channelToClose = synchronized(lifecycleLock) {
            closed = true
            opened = false
            channel.also { channel = null }
        }
        entry.signalReaders()
        channelToClose?.close()
    }
}
