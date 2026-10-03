package com.opencapture.opencine.runtime

import com.opencapture.opencine.media.MonitorAudioMeterLevels
import com.opencapture.opencine.media.MonitorAudioMeterBallistics

data class MonitorAudioPeakSample(val sourceGeneration: Long, val preparationGeneration: Long, val left: Float, val right: Float)

/** One polling consumer owns this history; preparing/replacing a source cannot inherit held peaks. */
class MonitorAudioMeterSampler(private val owner: MonitorAudioPeakAccumulator) {
    private var sourceGeneration: Long? = null
    private var preparationGeneration: Long? = null
    private var levels = MonitorAudioMeterLevels.Silent
    fun reset() { sourceGeneration = null; preparationGeneration = null; levels = MonitorAudioMeterLevels.Silent }
    fun step(dt: Double, outputMuted: Boolean = false): MonitorAudioMeterLevels? {
        val sample = owner.sampleAndReset() ?: run { reset(); return null }
        if (sourceGeneration != sample.sourceGeneration || preparationGeneration != sample.preparationGeneration) {
            levels = MonitorAudioMeterLevels.Silent
            sourceGeneration = sample.sourceGeneration
            preparationGeneration = sample.preparationGeneration
        }
        levels = MonitorAudioMeterLevels(
            MonitorAudioMeterBallistics.step(levels.left, if (outputMuted) 0.0 else sample.left.toDouble(), dt),
            MonitorAudioMeterBallistics.step(levels.right, if (outputMuted) 0.0 else sample.right.toDouble(), dt))
        return levels
    }
}

/** One native audio owner's prepared source; missing data is distinct from measured silence. */
open class MonitorAudioPeakAccumulator {
    private val lock = Any()
    private var closed = false
    private var next = 0L
    private var active: Long? = null
    private var revision = 0L
    private var measured = false
    private var left = 0f
    private var right = 0f

    fun beginSource(): MonitorAudioPeakLease? = synchronized(lock) {
        if (closed) return@synchronized null
        next += 1
        active = next
        revision = 0L
        measured = false
        left = 0f
        right = 0f
        MonitorAudioPeakLease(this, next)
    }
    fun sampleAndReset(): MonitorAudioPeakSample? = synchronized(lock) {
        val generation = active ?: return@synchronized null
        if (closed || !measured) return@synchronized null
        val peaks = MonitorAudioPeakSample(generation, revision, left, right)
        left = 0f
        right = 0f
        peaks
    }
    fun close() = synchronized(lock) {
        closed = true
        active = null
        measured = false
        left = 0f
        right = 0f
    }
    internal fun accepts(generation: Long): Boolean = synchronized(lock) { !closed && active == generation }
    internal fun prepare(generation: Long): Long? = synchronized(lock) {
        if (closed || active != generation) return@synchronized null
        revision += 1
        measured = false
        left = 0f
        right = 0f
        revision
    }
    internal fun accepts(generation: Long, sampleRevision: Long): Boolean = synchronized(lock) {
        !closed && active == generation && revision == sampleRevision
    }
    internal fun ingest(generation: Long, sampleRevision: Long, l: Float, r: Float): Boolean = synchronized(lock) {
        if (closed || active != generation) return@synchronized false
        if (revision != sampleRevision) return@synchronized false
        left = maxOf(left, l)
        right = maxOf(right, r)
        measured = true
        true
    }
    internal fun retire(generation: Long): Boolean = synchronized(lock) {
        if (closed || active != generation) return@synchronized false
        active = null
        measured = false
        left = 0f
        right = 0f
        true
    }
}

class MonitorAudioPeakLease internal constructor(private val owner: MonitorAudioPeakAccumulator, private val generation: Long) {
    val isActive: Boolean get() = owner.accepts(generation)
    fun ingest(left: Float, right: Float): Boolean = owner.ingest(generation, 0L, left, right)
    fun prepare(): MonitorAudioPeakWriter? = owner.prepare(generation)?.let { MonitorAudioPeakWriter(owner, generation, it) }
    fun close(): Boolean = owner.retire(generation)
}

/** Captured sampling format generation, with no authority to prepare or close another source. */
class MonitorAudioPeakWriter internal constructor(private val owner: MonitorAudioPeakAccumulator,
    private val generation: Long, private val revision: Long) {
    val isActive: Boolean get() = owner.accepts(generation, revision)
    fun ingest(left: Float, right: Float): Boolean = owner.ingest(generation, revision, left, right)
}
