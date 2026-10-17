package com.opencapture.opencine.runtime

import java.util.concurrent.atomic.AtomicLong
import kotlin.math.max
import kotlin.coroutines.CoroutineContext
import kotlin.coroutines.EmptyCoroutineContext
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.conflate
import kotlinx.coroutines.flow.onEach
import kotlinx.coroutines.withContext

/** Counters retain actual accepted source timing; missing/future timestamps stay unknown. */
class MonitorFramePacingStats(
    private val reportIntervalNanos: Long = 5_000_000_000L,
    private val log: (String) -> Unit,
) {
    private val received = AtomicLong(0)
    private var receivedAtWindowStart = 0L
    private var presented = 0L
    private var decodeTotalNanos = 0L
    private var decodeMaxNanos = 0L
    private var presentTotalNanos = 0L
    private var presentMaxNanos = 0L
    private var ageTotalNanos = 0L
    private var ageMaxNanos = 0L
    private var agedFrames = 0L
    private var windowStartNanos = 0L
    private var hasWindow = false

    /** Records one frame arriving from the source, before conflation. */
    fun frameReceived() {
        received.incrementAndGet()
    }

    /**
     * Records one frame decoded and handed to the renderer.
     *
     * @param decodeNanos Time spent turning the frame's bytes into a bitmap, decode ALONE.
     * @param presentNanos Time spent handing that bitmap to the screen. Separate from the decode
     *   on purpose: these two used to share one timer under the label "decode", so a present that
     *   blocks, and on the Vulkan path it blocks on a full GPU queue drain and a vsync-paced
     *   image acquire, was hiding inside a number every reader took for decoder cost. A pipeline
     *   is only diagnosable if each stage is timed as itself.
     * @param nowNanos Monotonic time of presentation ([System.nanoTime]).
     * @param ageNanos How long this frame waited between the transport having it
     *   and the renderer getting it, decode, plus any time it spent held. The
     *   transport stamps on the same `CLOCK_MONOTONIC` Kotlin reads, so the two
     *   are directly comparable. Negative or absent values are ignored rather
     *   than trusted: a source with no usable stamp must not invent a latency.
     */
    fun framePresented(
        decodeNanos: Long,
        nowNanos: Long,
        ageNanos: Long = -1L,
        presentNanos: Long = 0L,
    ) {
        if (!hasWindow) {
            // The first present only establishes the window baseline, counting
            // it would overstate fps by one fencepost frame per window.
            hasWindow = true
            windowStartNanos = nowNanos
            receivedAtWindowStart = received.get()
            return
        }
        presented++
        decodeTotalNanos += decodeNanos
        decodeMaxNanos = max(decodeMaxNanos, decodeNanos)
        presentTotalNanos += presentNanos
        presentMaxNanos = max(presentMaxNanos, presentNanos)
        if (ageNanos >= 0) {
            ageTotalNanos += ageNanos
            ageMaxNanos = max(ageMaxNanos, ageNanos)
            agedFrames++
        }

        val elapsed = nowNanos - windowStartNanos
        if (elapsed < reportIntervalNanos || presented == 0L) return

        val receivedInWindow = received.get() - receivedAtWindowStart
        val fps = presented * 1e9 / elapsed
        val avgMs = decodeTotalNanos / presented / 1e6
        val maxMs = decodeMaxNanos / 1e6
        // Reported only when it was actually measured. A source with no usable stamp printing
        // "age avg 0.0 ms" would be claiming the one thing we cannot see, and this counter exists
        // precisely because the invisible number was the one that mattered.
        val age =
            if (agedFrames > 0) {
                "age avg %.1f ms max %.1f ms | "
                    .format(ageTotalNanos / agedFrames / 1e6, ageMaxNanos / 1e6)
            } else {
                ""
            }
        log(
            ("feed pacing: %.1f fps | decode avg %.1f ms max %.1f ms | " +
                    "present avg %.1f ms max %.1f ms | %sdropped %d/%d")
                .format(
                    fps,
                    avgMs,
                    maxMs,
                    presentTotalNanos / presented / 1e6,
                    presentMaxNanos / 1e6,
                    age,
                    receivedInWindow - presented,
                    receivedInWindow,
                )
        )
        presented = 0
        decodeTotalNanos = 0
        decodeMaxNanos = 0
        presentTotalNanos = 0
        presentMaxNanos = 0
        ageTotalNanos = 0
        ageMaxNanos = 0
        agedFrames = 0
        windowStartNanos = nowNanos
        receivedAtWindowStart = received.get()
    }
}


/** A native newest-wins loop preserves the source event next to its decoded native value.
 * Native decode/present work remains outside publication locks. A retired/canceled worker cannot
 * enter presentation after a blocked synchronous decode returns. [publish] may suspend to hand
 * the decoded frame to its owner thread; [present] then observes it on the decode worker. */
suspend fun <F : Any, T : Any> monitorPumpFramesWithSourceFrame(
    frames: Flow<F>, stats: MonitorFramePacingStats,
    timestampNanos: (F) -> Long?, decode: (F) -> T?, present: (F, T) -> Unit,
    isCurrent: () -> Boolean = { true }, nowNanos: () -> Long = System::nanoTime,
    publish: suspend (F, T) -> Unit = { _, _ -> },
) = pumpFrames(frames, stats, timestampNanos, decode, present,
    EmptyCoroutineContext, isCurrent, nowNanos, publish)

/** Decodes on the caller's worker and delivers the actual source/value pair on its picture owner.
 * Retirement and cancellation are checked again after dispatch, before any publication. */
suspend fun <F : Any, T : Any> monitorPumpFramesWithSourceFrame(
    frames: Flow<F>, stats: MonitorFramePacingStats,
    timestampNanos: (F) -> Long?, decode: (F) -> T?, present: (F, T) -> Unit,
    presentationDispatcher: CoroutineDispatcher,
    isCurrent: () -> Boolean = { true }, nowNanos: () -> Long = System::nanoTime,
) = pumpFrames(frames, stats, timestampNanos, decode, present,
    presentationDispatcher, isCurrent, nowNanos, { _, _ -> })

private suspend fun <F : Any, T : Any> pumpFrames(
    frames: Flow<F>, stats: MonitorFramePacingStats,
    timestampNanos: (F) -> Long?, decode: (F) -> T?, present: (F, T) -> Unit,
    presentationContext: CoroutineContext, isCurrent: () -> Boolean, nowNanos: () -> Long,
    publish: suspend (F, T) -> Unit,
) {
    frames.onEach { stats.frameReceived() }.conflate().collect { frame ->
        currentCoroutineContext().ensureActive()
        if (!isCurrent()) return@collect
        val start = nowNanos()
        val decoded = decode(frame) ?: return@collect
        val decodedAt = nowNanos()
        currentCoroutineContext().ensureActive()
        if (!isCurrent()) return@collect
        publish(frame, decoded)
        currentCoroutineContext().ensureActive()
        if (!isCurrent()) return@collect
        val presented = withContext(presentationContext) {
            currentCoroutineContext().ensureActive()
            if (!isCurrent()) false else {
                present(frame, decoded)
                true
            }
        }
        if (!presented) return@collect
        val done = nowNanos()
        currentCoroutineContext().ensureActive()
        if (!isCurrent()) return@collect
        val stamp = timestampNanos(frame)
        stats.framePresented(decodeNanos = decodedAt - start,
            presentNanos = done - decodedAt, nowNanos = done,
            ageNanos = if (stamp != null && stamp > 0) done - stamp else -1L)
    }
}
