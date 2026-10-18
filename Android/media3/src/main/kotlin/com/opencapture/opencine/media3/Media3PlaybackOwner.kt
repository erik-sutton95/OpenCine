@file:androidx.media3.common.util.UnstableApi

package com.opencapture.opencine.media3

import android.content.Context
import com.opencapture.opencine.appkit.MonitorMediaLibraryModel
import com.opencapture.opencine.appkit.MonitorMediaPlaybackModel
import com.opencapture.opencine.appkit.MonitorMediaRecord
import com.opencapture.opencine.appkit.MonitorPlaybackAdmission
import com.opencapture.opencine.appkit.MonitorPlaybackAudioSession
import com.opencapture.opencine.appkit.MonitorPlaybackCandidate
import com.opencapture.opencine.appkit.MonitorPlaybackLook
import com.opencapture.opencine.media.MonitorPlaybackLookTiming
import com.opencapture.opencine.media.MonitorPlaybackStartTiming
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel

/**
 * Platform resources for one shared logical player over a media library: the ExoPlayer, its audio
 * meter, the native port and the shared playback model. Holds no player state machine; reopening
 * creates a fresh owner. The app supplies its sources, look, admission and listed frame rate.
 */
public class Media3PlaybackOwner<P, L>(
    context: Context,
    library: MonitorMediaLibraryModel<P>,
    candidates: (MonitorMediaRecord<P>) -> List<MonitorPlaybackCandidate>,
    resolveLook: suspend (MonitorMediaRecord<P>) -> MonitorPlaybackLook<L>?,
    admission: (MonitorMediaRecord<P>) -> MonitorPlaybackAdmission,
    listedFrameRate: (P) -> Double?,
) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val meter = Media3AudioMeter()
    public val native: Media3PlaybackPort = Media3PlaybackPort(Media3Playback.player(context, meter), scope)
    public val audio: MonitorPlaybackAudioSession = meter.session(scope)
    public val playback: MonitorMediaPlaybackModel<P, L> = MonitorMediaPlaybackModel<P, L>(library, native, scope,
        readyTimeout = null, retryNativeFailures = false, candidates = candidates,
        lookTiming = MonitorPlaybackLookTiming.BEFORE_NATIVE_PREPARATION,
        startTiming = MonitorPlaybackStartTiming.AFTER_NATIVE_ITEM_INSTALLATION,
        resolveLook = { record, _ -> resolveLook(record) }).also { owner ->
            owner.setItemAdmission(admission)
            native.listedFrameRate = { token ->
                val current = owner.state.value
                if (current.token == token && owner.isActive && owner.state.value.token == token)
                    current.active?.payload?.let(listedFrameRate) else null
            }
            native.sourceAdmission = { token -> owner.state.value.token == token && owner.isActive && owner.state.value.token == token }
        }

    /** The native and render owner retires before its coroutine parent or audio input disappears. */
    public fun close() {
        playback.close()
        audio.close()
        meter.close()
        scope.cancel()
    }
}
