@file:androidx.media3.common.util.UnstableApi

package com.opencapture.opencine.media3

import androidx.media3.common.Player
import androidx.media3.exoplayer.ExoPlayer
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference

/** Media3 output receipts for a single playback owner. Readback must also match the visible texture. */
public class Media3ReferenceFrames {
    public data class Frame(public val presentationUs: Long, public val releaseNs: Long) {
        public fun matches(timestampNs: Long): Boolean = timestampNs >= 0 &&
            (releaseNs > 0 && timestampNs == releaseNs ||
                presentationUs in 0L..(Long.MAX_VALUE / 1_000L) && timestampNs == presentationUs * 1_000L)
    }

    private data class Stream(
        val revision: Long = 0,
        val waitingForSeek: Boolean = false,
        val frames: List<Frame> = emptyList(),
    )

    public class Snapshot internal constructor(
        public val revision: Long,
        private val frames: List<Frame>,
        internal val playRevision: Long = 0,
    ) {
        public fun frame(timestampNs: Long): Frame? = frames.lastOrNull { it.matches(timestampNs) }
    }

    private val stream = AtomicReference(Stream())
    private val playRevision = AtomicLong(0)

    /** Install before preparing the first item or attaching its output surface. */
    public fun attach(player: ExoPlayer): Unit {
        player.addListener(object : Player.Listener {
            override fun onPlayWhenReadyChanged(playWhenReady: Boolean, reason: Int) {
                if (playWhenReady) playRevision.incrementAndGet()
            }
        })
        player.setVideoFrameMetadataListener { presentationUs, releaseNs, _, _ ->
            val current = stream.get()
            if (!current.waitingForSeek) {
                val receipt = Frame(presentationUs, releaseNs)
                stream.compareAndSet(current, current.copy(frames = (current.frames + receipt).takeLast(4)))
            }
        }
    }

    /** Retire old receipts before the seek and reopen admission on Media3's command thread. */
    public fun seek(player: ExoPlayer, targetMs: Long): Unit {
        if (player.currentPosition == targetMs) {
            player.seekTo(targetMs)
            return
        }
        val revision = stream.updateAndGet { Stream(it.revision + 1, waitingForSeek = true) }.revision
        player.seekTo(targetMs)
        player.createMessage { _, _ ->
            stream.updateAndGet { if (it.revision == revision) it.copy(waitingForSeek = false) else it }
        }.send()
    }

    public fun retire(): Unit { stream.updateAndGet { Stream(it.revision + 1) } }

    /** Ready and paused describes transport only; callers still prove the output receipt. */
    public fun paused(player: ExoPlayer): Snapshot? {
        if ((player.playWhenReady && player.playbackState != Player.STATE_ENDED) || player.isPlaying ||
            (player.playbackState != Player.STATE_READY && player.playbackState != Player.STATE_ENDED)) return null
        val current = stream.get()
        if (current.frames.isEmpty()) return null
        return Snapshot(current.revision, current.frames, playRevision.get())
    }

    public fun isCurrent(player: ExoPlayer, snapshot: Snapshot): Boolean =
        paused(player)?.let { it.revision == snapshot.revision && it.playRevision == snapshot.playRevision } == true
}
