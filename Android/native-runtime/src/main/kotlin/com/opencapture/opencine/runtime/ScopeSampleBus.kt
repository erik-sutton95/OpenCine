package com.opencapture.opencine.runtime

import com.opencapture.opencine.media.ScopeAssistBundle

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

data class ScopePublication(val bundle: ScopeAssistBundle = ScopeAssistBundle.EMPTY, val generation: Long = 0)

/** One monitor owner's publication lifetime. A replaced source cannot clear its successor. */
class ScopeSampleBus {
    class Source internal constructor()
    private var source: Source? = null
    private val mutable = MutableStateFlow(ScopePublication())
    val publications: StateFlow<ScopePublication> = mutable.asStateFlow()
    val bundle: ScopeAssistBundle get() = mutable.value.bundle
    val generation: Long get() = mutable.value.generation

    @Synchronized fun openSource(): Source = Source().also {
        source = it
        mutable.value = ScopePublication()
    }
    @Synchronized fun isCurrent(candidate: Source?): Boolean = candidate != null && candidate === source
    @Synchronized fun publish(candidate: Source?, next: ScopeAssistBundle): Boolean {
        if (!isCurrent(candidate)) return false
        mutable.value = ScopePublication(next, generation + 1)
        return true
    }
    @Synchronized fun closeSource(candidate: Source?) {
        if (!isCurrent(candidate)) return
        source = null
        mutable.value = ScopePublication()
    }
}
