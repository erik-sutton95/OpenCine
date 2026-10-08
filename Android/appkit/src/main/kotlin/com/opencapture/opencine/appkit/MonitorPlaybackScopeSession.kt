package com.opencapture.opencine.appkit

import com.opencapture.opencine.media.MonitorPlaybackItemToken
import com.opencapture.opencine.media.ScopeAssistBundle
import com.opencapture.opencine.media.ScopeSamples
import java.util.UUID
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Job
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/** Actual immutable native publication; acquisition is outside this owner. */
public data class MonitorPlaybackScopeFrame(public val revision: Long, public val samples: ScopeSamples)

/** Polling/derivation admission for one captured player item, with a caller-supplied clock. */
public class MonitorPlaybackScopeSession<C>(
    private val scope: CoroutineScope,
    private val cadenceMilliseconds: Long,
    private val sleep: suspend (Long) -> Unit = { kotlinx.coroutines.delay(it) },
    private val derive: suspend (ScopeSamples, C, ScopeAssistBundle) -> ScopeAssistBundle,
) {
    private val mutable = MutableStateFlow(ScopeAssistBundle.EMPTY)
    public val bundle: StateFlow<ScopeAssistBundle> = mutable.asStateFlow()
    private var item: MonitorPlaybackItemToken? = null
    private var configuration: C? = null
    private var revision = UUID.randomUUID()
    private var task: Job? = null
    private var enabled = false
    private var closed = false
    public fun synchronize(item: MonitorPlaybackItemToken, enabled: Boolean, configuration: C,
        read: suspend () -> MonitorPlaybackScopeFrame?, ifCurrent: () -> Boolean): Unit {
        if (closed) return
        val before = revision
        if (!ifCurrent() || closed || revision != before) return
        if (this.item == item && this.configuration == configuration && this.enabled == enabled) return
        val changesItem = this.item != item
        revision = UUID.randomUUID(); val captured = revision
        val previous = task; task = null; previous?.cancel()
        if (revision != captured || closed) return
        this.item = item; this.configuration = configuration; this.enabled = enabled
        if (changesItem || !enabled) mutable.value = ScopeAssistBundle.EMPTY
        if (!enabled || !current(item, captured, ifCurrent)) return
        val job = scope.launch(start = CoroutineStart.LAZY) {
            var lastPublication: Long? = null
            while (isActive && current(item, captured, ifCurrent)) {
                val frame = read()
                if (!isActive || !current(item, captured, ifCurrent)) return@launch
                if (frame != null && frame.revision != lastPublication) {
                    val derived = derive(frame.samples, configuration, mutable.value)
                    if (!isActive || !current(item, captured, ifCurrent)) return@launch
                    lastPublication = frame.revision; mutable.value = derived
                    if (!current(item, captured, ifCurrent)) return@launch
                }
                sleep(cadenceMilliseconds)
            }
        }
        task = job; job.start()
    }
    private fun current(token: MonitorPlaybackItemToken, captured: UUID, ifCurrent: () -> Boolean): Boolean {
        if (closed || !enabled || revision != captured || item != token) return false
        val admitted = ifCurrent()
        return admitted && !closed && enabled && revision == captured && item == token
    }
    public fun retire(item: MonitorPlaybackItemToken): Unit {
        if (this.item != item) return
        revision = UUID.randomUUID(); val captured = revision
        this.item = null; configuration = null; enabled = false
        val previous = task; task = null; previous?.cancel()
        if (revision != captured || this.item != null || closed) return
        mutable.value = ScopeAssistBundle.EMPTY
    }
    public fun close(): Unit {
        if (closed) return
        closed = true; revision = UUID.randomUUID(); item = null; configuration = null; enabled = false
        val previous = task; task = null; previous?.cancel(); mutable.value = ScopeAssistBundle.EMPTY
    }
}
