package com.opencapture.opencine.appkit

import com.opencapture.opencine.media.MonitorPlaybackDeletionConfirmation

/** The app captures related targets/native cleanup; the existing authority owns source IO
 * and its completion grants only the planned presentation return. */
public class MonitorOperatorPlaybackDeletionRequest(
    public val confirmation: MonitorPlaybackDeletionConfirmation,
    public val authority: MonitorMediaLibraryDeletionAuthority,
    public val perform: suspend () -> Unit,
)
