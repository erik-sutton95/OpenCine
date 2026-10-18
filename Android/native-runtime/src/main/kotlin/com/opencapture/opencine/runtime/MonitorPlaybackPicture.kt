package com.opencapture.opencine.runtime

import android.view.Surface
import java.util.UUID

/**
 * The player side of a playback picture: one claimed owner at a time receives the decoder
 * surface the native feed hands back. A new claim retires the previous owner's session.
 */
interface MonitorPlaybackPictureOwner {
    /** Claims the picture for a new presenting session; closes the previous one. */
    fun claimPicture(): UUID

    /** Points the player at [surface] while [owner] still holds the picture. */
    fun attachPicture(surface: Surface, owner: UUID)

    /** Registers how the player retires and closes [owner]'s presenting session. */
    fun bindPicture(owner: UUID, retire: () -> Unit, close: () -> Unit)

    /** Gives the picture up when [owner]'s view leaves. */
    fun releasePicture(owner: UUID)
}
