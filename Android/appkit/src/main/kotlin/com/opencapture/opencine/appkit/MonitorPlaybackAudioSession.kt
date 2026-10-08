package com.opencapture.opencine.appkit

import com.opencapture.opencine.core.MonotonicInstant
import com.opencapture.opencine.media.MonitorAudioMeterLevels
import com.opencapture.opencine.media.MonitorPlaybackItemToken
import java.util.UUID
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/** Per-item polling of an existing native PCM input. It creates no audio tap or native owner. */
public class MonitorPlaybackAudioSession(
    private val scope: CoroutineScope,
    private val read: (Double, Boolean) -> MonitorAudioMeterLevels?,
    private val reset: () -> Unit,
    private val now: () -> Long = { MonotonicInstant.now().sinceReference.inWholeNanoseconds },
    private val sleep: suspend (Long) -> Unit = { delay(it) },
) {
    private val mutable = MutableStateFlow<MonitorAudioMeterLevels?>(null)
    public val levels: StateFlow<MonitorAudioMeterLevels?> = mutable.asStateFlow()
    private var token: MonitorPlaybackItemToken? = null
    private var visible = false
    private var outputMuted = false
    private var admission: (() -> Boolean)? = null
    private var revision = UUID.randomUUID()
    private var work: Job? = null
    private var closed = false

    public fun synchronize(item: MonitorPlaybackItemToken, visible: Boolean, outputMuted: Boolean,
        ifCurrent: () -> Boolean): Unit {
        if (closed) return
        val before = revision
        val accepted = ifCurrent()
        if (!accepted || closed || revision != before) return
        admission = ifCurrent
        if (token == item && this.visible == visible && this.outputMuted == outputMuted) return
        revision = UUID.randomUUID(); val captured = revision
        token = item; this.visible = visible; this.outputMuted = outputMuted
        val previous = work; work = null; previous?.cancel()
        if (!current(item, captured)) return
        reset()
        if (!current(item, captured)) return
        mutable.value = null
        if (!visible || !current(item, captured)) return
        val job = scope.launch(start = CoroutineStart.LAZY) {
            var last = now()
            while (isActive && current(item, captured)) {
                sleep(42)
                if (!isActive || !current(item, captured)) return@launch
                val instant = now()
                val elapsed = (instant - last) / 1_000_000_000.0
                last = instant
                val value = read(elapsed, outputMuted)
                if (!isActive || !current(item, captured)) return@launch
                mutable.value = value
            }
        }
        if (!current(item, captured)) { job.cancel(); return }
        work = job; job.start()
    }
    private fun current(item: MonitorPlaybackItemToken, captured: UUID): Boolean {
        if (closed || revision != captured || token != item) return false
        val accepted = admission?.invoke() == true
        return accepted && !closed && revision == captured && token == item
    }
    public fun close(): Unit {
        if (closed) return
        closed = true; revision = UUID.randomUUID(); token = null; admission = null
        val previous = work; work = null; previous?.cancel()
        reset(); mutable.value = null
    }
}
