package com.opencapture.opencine.runtime

import java.nio.ByteBuffer

/** Native producer lifetime: retired sources cannot prepare, publish or clear a successor. */
class MonitorPcmAudioInput(owner: MonitorAudioPeakAccumulator) {
    private data class Prepared(val format: MonitorPcmFormat, val writer: MonitorAudioPeakWriter)
    private val lock = Any()
    private val source = owner.beginSource()
    private var prepared: Prepared? = null
    private var closed = false

    fun prepare(format: MonitorPcmFormat): Boolean = synchronized(lock) {
        if (closed) return@synchronized false
        val writer = source?.prepare() ?: return@synchronized false
        prepared = Prepared(format, writer)
        true
    }
    fun ingest(buffer: ByteBuffer): Boolean {
        val context = synchronized(lock) { if (closed) null else prepared } ?: return false
        if (!context.writer.isActive) return false
        val peaks = MonitorPcmPeaks.ingest(buffer, context.format) ?: return false
        return context.writer.ingest(peaks.first, peaks.second)
    }
    fun close() = synchronized(lock) {
        closed = true
        prepared = null
        source?.close()
        Unit
    }
}
