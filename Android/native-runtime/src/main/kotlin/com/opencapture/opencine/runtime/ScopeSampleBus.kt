package com.opencapture.opencine.runtime

import com.opencapture.opencine.media.ScopeAssistBundle
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

data class ScopePublication(val bundle: ScopeAssistBundle = ScopeAssistBundle.EMPTY, val generation: Long = 0)

/** One monitor's live and playback publications, fenced independently by source lease. */
class ScopeSampleBus {
    enum class Role { LIVE, PLAYBACK }
    class Source internal constructor(internal val role: Role)
    private var liveSource: Source? = null
    private var playbackSource: Source? = null
    private var live = ScopePublication()
    private var playback = ScopePublication()
    private val mutable = MutableStateFlow(ScopePublication())
    val publications: StateFlow<ScopePublication> = mutable.asStateFlow()
    val bundle: ScopeAssistBundle get() = mutable.value.bundle
    val generation: Long get() = mutable.value.generation

    @Synchronized fun openSource(role: Role = Role.LIVE): Source = Source(role).also {
        when (role) {
            Role.LIVE -> { liveSource = it; live = ScopePublication() }
            Role.PLAYBACK -> { playbackSource = it; playback = ScopePublication() }
        }
        updateDisplay()
    }
    @Synchronized fun isCurrent(candidate: Source?): Boolean = candidate != null &&
        candidate === when (candidate.role) { Role.LIVE -> liveSource; Role.PLAYBACK -> playbackSource }

    /** Replacement is atomic and allowed only to the current owner. */
    @Synchronized fun replaceSource(candidate: Source?): Source? =
        candidate?.takeIf(::isCurrent)?.let { openSource(it.role) }

    @Synchronized fun publish(candidate: Source?, next: ScopeAssistBundle): Boolean {
        if (!isCurrent(candidate)) return false
        when (checkNotNull(candidate).role) {
            Role.LIVE -> live = ScopePublication(next, live.generation + 1)
            Role.PLAYBACK -> playback = ScopePublication(next, playback.generation + 1)
        }
        updateDisplay()
        return true
    }
    @Synchronized fun closeSource(candidate: Source?) {
        if (!isCurrent(candidate)) return
        when (checkNotNull(candidate).role) {
            Role.LIVE -> { liveSource = null; live = ScopePublication() }
            Role.PLAYBACK -> { playbackSource = null; playback = ScopePublication() }
        }
        updateDisplay()
    }
    private fun updateDisplay() { mutable.value = if (playbackSource != null) playback else live }
}
