package com.opencapture.opencine.appkit

import com.opencapture.opencine.core.CameraSession
import com.opencapture.opencine.core.ConnectedCamera
import com.opencapture.opencine.core.SessionCloseReason
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import java.util.UUID

/**
 * The app's root state over [CamerasModel] (Swift `ShellModel`, SHELL-03): which page shows
 * (cameras, pair or the monitor), an optional cover over it, and the lifetime of the monitor's
 * camera. Confine it to the main thread.
 *
 * - A successful connect from [cameras] presents its session on the monitor; this shell then owns
 *   it. A newer camera replaces the monitor: the old owned session closes as REPLACED, and
 *   everything still in flight for it is retired ([MonitorControlModel.unbind]).
 * - [close] leaves the monitor: it retires presentation and editors, closes the session only when
 *   this shell owns it, and returns a borrowed one with its release (never CloseSession, never
 *   stop-record). Closing twice does nothing.
 * - A cover (settings, media) never implies disconnect: the monitor and its session stay.
 * - The session ending on its own (Disconnected) leaves the monitor; transport recovery is the
 *   integration's, so Recovering keeps it (with the last reported values).
 * - The scene's active state arrives here once per change, however many OS signals report it.
 */
public class ShellModel(public val cameras: CamerasModel, public val control: MonitorControlModel) {
    public enum class Route { CAMERAS, PAIR, MONITOR }

    /** A page over the current route. Covering is not leaving. */
    public enum class Cover { SETTINGS, MEDIA }

    /**
     * What leaving the monitor does to its cover (A2-07). DISMISS (the default): the cover leaves
     * with the monitor. RETAIN: the cover stays, with its view state, over the cameras page, as
     * when an internet hop leaves the camera with the gallery still open.
     */
    public enum class CoverRetention { DISMISS, RETAIN }

    /** Who owns the monitor's session. */
    public sealed interface Ownership {
        /** This shell closes it. */
        public data object Owned : Ownership

        /** Lent by another owner (a multicam member); [release] hands it back. */
        public class Borrowed(public val release: () -> Unit) : Ownership
    }

    /** The camera on the monitor and who owns its session. */
    public class Monitor(public val camera: ConnectedCamera, public val ownership: Ownership) {
        /** One monitor lifetime: a host keyed by it is created once and survives covers. */
        public val id: String = UUID.randomUUID().toString()
        public val session: CameraSession get() = camera.session
        public val isBorrowed: Boolean get() = ownership is Ownership.Borrowed
    }

    public data class State(
        public val monitor: Monitor? = null,
        public val cover: Cover? = null,
        /** The operator opened the pair page (it also shows while nothing is saved). */
        public val pairing: Boolean = false,
        /**
         * The operator chose the cameras page with nothing saved (to watch a feed, say): an empty
         * list shows it instead of the pair page.
         */
        public val camerasChosen: Boolean = false,
        /** The app's scene is active. Starts active. */
        public val sceneActive: Boolean = true,
    )

    private val mutable = MutableStateFlow(State())
    public val state: StateFlow<State> = mutable.asStateFlow()

    /** Called once per change of [State.sceneActive]. */
    public var onSceneActivity: (Boolean) -> Unit = {}

    /** Monitor hosts mounted and unmounted by [AppShell] (one per monitor lifetime). */
    public var hostsMounted: Int = 0
        private set
    public var hostsUnmounted: Int = 0
        private set

    init {
        cameras.onConnected = { present(it) }
        control.onEnded = { sessionEnded() }
    }

    public val route: Route
        get() = when {
            state.value.monitor != null -> Route.MONITOR
            state.value.pairing || (cameras.state.value.saved.isEmpty() && !state.value.camerasChosen) -> Route.PAIR
            else -> Route.CAMERAS
        }

    // Monitor lifetime

    /** Shows [camera] on the monitor; this shell owns and later closes its session. */
    public fun present(camera: ConnectedCamera) {
        // A delayed callback for the already-presented session is not a replacement.
        // Keep its picture host, ownership, cover and open editors intact.
        if (state.value.monitor?.session?.id == camera.session.id) return
        show(Monitor(camera, Ownership.Owned))
    }

    /** Shows a session another owner lends; [close] calls [release] instead of closing it. */
    public fun borrow(camera: ConnectedCamera, release: () -> Unit) {
        show(Monitor(camera, Ownership.Borrowed(release)))
    }

    /** Leaves the monitor for the cameras page. Closes the session only when owned. */
    public fun close(): Unit = close(CoverRetention.DISMISS)

    /** [close], keeping the cover over the cameras page when [cover] is RETAIN. */
    public fun close(cover: CoverRetention) {
        val monitor = leave(cover) ?: return
        end(monitor, SessionCloseReason.REQUESTED)
    }

    private fun show(next: Monitor) {
        leave()?.let { end(it, SessionCloseReason.REPLACED) }
        // A connect shows the monitor, never a leftover page.
        mutable.update { it.copy(monitor = next, cover = null, pairing = false) }
        control.bind(next.session)
    }

    /** The session ended by itself (closed, link given up): nothing to close. */
    private fun sessionEnded() {
        val monitor = leave() ?: return
        end(monitor, null)
    }

    private fun leave(retention: CoverRetention = CoverRetention.DISMISS): Monitor? {
        val monitor = state.value.monitor ?: return null
        control.unbind()
        mutable.update { it.copy(monitor = null, cover = if (retention == CoverRetention.RETAIN) it.cover else null) }
        return monitor
    }

    private fun end(monitor: Monitor, reason: SessionCloseReason?) {
        when (val ownership = monitor.ownership) {
            Ownership.Owned -> {
                reason?.let(monitor.session::closeNow)
                // A replacement keeps the connection model's camera; anything else resumes discovery.
                if (reason != SessionCloseReason.REPLACED) cameras.sessionEnded()
            }
            is Ownership.Borrowed -> ownership.release()
        }
    }

    // Navigation

    public fun beginPairing() {
        mutable.update { it.copy(pairing = true) }
    }

    public fun endPairing() {
        mutable.update { it.copy(pairing = false) }
    }

    /** Leaves pairing for the cameras page, which stays even with nothing saved. */
    public fun showCameras() {
        mutable.update { it.copy(pairing = false, camerasChosen = true) }
    }

    /** Opens [cover] over the current page; the monitor and its session stay. */
    public fun open(cover: Cover) {
        mutable.update { it.copy(cover = cover) }
    }

    public fun dismissCover() {
        mutable.update { it.copy(cover = null) }
    }

    /**
     * The camera body's own gallery, as a camera maker's app shows it: the body entering it
     * opens Media, and the body leaving it closes Media (which returns the camera to live).
     * Another cover the operator opened stays. Swift `followCameraGallery(open:)`.
     */
    public fun followCameraGallery(open: Boolean) {
        val shown = state.value.cover
        if (open && shown == null) {
            open(Cover.MEDIA)
        } else if (!open && shown == Cover.MEDIA) {
            dismissCover()
        }
    }

    // Scene

    /** The OS reports the scene active or not (lifecycle, window focus). */
    public fun setSceneActive(active: Boolean) {
        if (active == state.value.sceneActive) return
        mutable.update { it.copy(sceneActive = active) }
        // The Local Network prompt and a Settings visit both end here: re-check that permission.
        if (active) cameras.retryLocalNetworkFailures()
        onSceneActivity(active)
    }

    // Host accounting (diagnostics)

    internal fun noteHost(mounted: Boolean) {
        if (mounted) hostsMounted += 1 else hostsUnmounted += 1
    }
}
