package com.opencapture.opencine.appkit

import com.opencapture.opencine.core.MonotonicInstant
import com.opencapture.opencine.media.MediaTransferRate
import com.opencapture.opencine.media.MediaTransferRateEstimator
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

/**
 * The one download-speed source every app's progress UI reads: one estimator per running download,
 * read again on a steady tick so a stall shows without a new byte (the tick rests once every
 * download reads Stalled). The media library feeds it for the transfers it owns; an app that
 * streams clips itself feeds its own. Safe to feed from a transfer callback thread. Swift twin: `MonitorTransferRates`.
 *
 * @param scope runs the tick while a download is running.
 * @param now the injected clock's instant; [sleep] waits on the same clock, in milliseconds.
 */
public class MonitorTransferRates<K : Any>(
    private val scope: CoroutineScope,
    private val now: () -> MonotonicInstant = { MonotonicInstant.now() },
    private val sleep: suspend (Long) -> Unit = { delay(it) },
) {
    private val lock = Any()
    private val estimators = mutableMapOf<K, MediaTransferRateEstimator>()
    private var ticker: Job? = null
    private val mutable = MutableStateFlow<Map<K, MediaTransferRate>>(emptyMap())

    /** The current reading per running download. A key is absent once its download ended. */
    public val rates: StateFlow<Map<K, MediaTransferRate>> = mutable.asStateFlow()

    /** The reading for [key], null when no download for it is running. */
    public fun rate(key: K): MediaTransferRate? = mutable.value[key]

    /** A download for [key] starts (again). [bytes] already present, such as a resumed offset, do
     * not count as speed. */
    public fun begin(key: K, bytes: Long = 0L) {
        synchronized(lock) {
            estimators[key] = MediaTransferRateEstimator(now(), bytes)
            publish(key, MediaTransferRate.Measuring)
            startTicking()
        }
    }

    /** The download's running byte total. Starts the download when [begin] was not called. */
    public fun record(key: K, totalBytes: Long) {
        synchronized(lock) {
            val estimator = estimators[key]
            if (estimator == null) begin(key, totalBytes) else { estimator.record(totalBytes, now()); startTicking() }
        }
    }

    /** The download for [key] ended: its reading disappears now. */
    public fun end(key: K) {
        synchronized(lock) {
            estimators.remove(key)
            if (mutable.value.containsKey(key)) mutable.value = mutable.value - key
            if (estimators.isEmpty()) { ticker?.cancel(); ticker = null }
        }
    }

    /** Ends every download not in [keys], for an owner that retired several at once. */
    public fun retain(keys: Set<K>) {
        synchronized(lock) { estimators.keys.filter { it !in keys }.forEach(::end) }
    }

    private fun publish(key: K, rate: MediaTransferRate) {
        if (mutable.value[key] != rate) mutable.value = mutable.value + (key to rate)
    }

    private fun refresh() {
        synchronized(lock) {
            val instant = now()
            estimators.forEach { (key, estimator) -> publish(key, estimator.rate(instant)) }
            // A stalled reading changes only with a new byte, which starts the tick again: no
            // timer runs for a download that went quiet.
            if (mutable.value.values.all { it == MediaTransferRate.Stalled }) { ticker?.cancel(); ticker = null }
        }
    }

    private fun startTicking() {
        if (ticker != null) return
        ticker = scope.launch {
            while (isActive) {
                sleep(TICK_MILLISECONDS)
                refresh()
            }
        }
    }

    public companion object {
        /** How often a running download's reading is refreshed. */
        public const val TICK_MILLISECONDS: Long = 500L
    }
}
