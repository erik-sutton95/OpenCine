package com.opencapture.opencine.appkit

import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlin.coroutines.coroutineContext

/** The cold-start wait consumed by the actual Compose splash, with manual time in tests. */
public suspend fun awaitMonitorLaunch(sleep: suspend (Long) -> Unit = { delay(it) }): Unit {
    sleep(MonitorLaunchTiming.VISIBLE_MILLIS)
    // A retired native source cannot publish even if its callback ignores cancellation.
    coroutineContext.ensureActive()
}

/** Swift twin: MonitorAppStartup launch admission over the host's existing consent store. */
public object MonitorStartupConsentAdmission {
    public fun allows(available: Boolean, hasDecision: Boolean): Boolean = available && !hasDecision
}
