package com.opencapture.monitorui

/** Timed movement in logical display points; no camera or rendering ownership. */
internal class TeleprompterPlayback {
    var position: Double = 0.0
        private set
    var isPlaying: Boolean = false
        private set

    fun play() { isPlaying = true }
    fun pause() { isPlaying = false }
    fun reset() { position = 0.0; pause() }
    fun seek(position: Double) { this.position = position.coerceAtLeast(0.0); pause() }

    fun advance(elapsed: Double, speed: Double, end: Double) {
        if (!isPlaying) return
        position = minOf(end.coerceAtLeast(0.0), position + elapsed.coerceAtLeast(0.0) * speed.coerceAtLeast(0.0))
        if (position >= end.coerceAtLeast(0.0)) pause()
    }
}
