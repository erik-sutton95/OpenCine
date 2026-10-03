package com.opencapture.opencine.runtime

import android.util.Log
import java.util.Locale

/** 2 s delivered-Hz breadcrumb vs [com.opencapture.opencine.media.ScopeSampler.minIntervalNs]. */
class ScopeTapHzLog {
    private val windowNs = 2_000_000_000L
    private var windowStartNs = 0L
    private var taps = 0

    fun note(tag: String, scopes: Int, intervalNs: Long) {
        val now = System.nanoTime()
        if (windowStartNs == 0L) windowStartNs = now
        taps += 1
        val elapsed = now - windowStartNs
        if (elapsed < windowNs) return
        val hz = taps * 1_000_000_000.0 / elapsed
        val budget = 1_000_000_000.0 / intervalNs.coerceAtLeast(1)
        Log.i(
            tag,
            "scope tap: ${"%.1f".format(Locale.US, hz)}Hz budget=${"%.0f".format(Locale.US, budget)}Hz scopes=$scopes",
        )
        taps = 0
        windowStartNs = now
    }

    fun reset() {
        windowStartNs = 0L
        taps = 0
    }
}
