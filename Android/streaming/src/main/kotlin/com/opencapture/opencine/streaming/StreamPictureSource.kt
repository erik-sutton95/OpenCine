package com.opencapture.opencine.streaming

import android.view.Surface

/**
 * Where a stream's pictures come from: something that renders the clean camera picture into the
 * encoder's input surface. App composition adapts the native runtime's clean-picture tap to it;
 * no runtime or UI type enters this module.
 */
interface StreamPictureSource {
    /**
     * Starts rendering into [surface] at [width] by [height]: fitted with black bars, or center
     * cropped to fill when [crop]. [onPicture] runs, on any thread, each time a new picture arrives.
     */
    fun attach(surface: Surface, width: Int, height: Int, crop: Boolean, onPicture: () -> Unit)

    /**
     * Renders one output frame with [presentationTimeNs] (the publisher's clock): the newest
     * picture, or black when [slate]. Returns at once; rendering runs on the source's thread.
     */
    fun draw(presentationTimeNs: Long, slate: Boolean)

    fun detach()
}

/**
 * Chooses each output frame's picture so the encoder runs at one fixed rate whatever the source
 * does: the newest picture is used (a slower source repeats, a faster one skips), and once no
 * picture has arrived for [slateAfterNs] the output is a neutral slate until pictures return.
 * The Kotlin twin of Swift `StreamFramePacer`; the pictures themselves stay in the source.
 */
class StreamFramePacer(private val slateAfterNs: Long = 2_000_000_000) {
    enum class Frame { PICTURE, SLATE }

    private var newestAtNs: Long? = null

    fun submit(atNs: Long) {
        newestAtNs = atNs
    }

    fun frame(atNs: Long): Frame {
        val newest = newestAtNs ?: return Frame.SLATE
        return if (atNs - newest < slateAfterNs) Frame.PICTURE else Frame.SLATE
    }
}
