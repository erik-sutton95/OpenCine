package com.opencapture.opencine.media

import java.util.UUID

/** Frozen operator copy for one captured playback deletion, independent of camera protocol. */
public data class MonitorPlaybackDeletionConfirmation(
    public val id: UUID = UUID.randomUUID(),
    public val title: String,
    public val message: String? = null,
)
