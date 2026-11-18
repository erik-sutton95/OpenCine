package com.opencapture.opencine.nikon

import com.opencapture.opencine.core.CameraDeviceID
import com.opencapture.opencine.core.CameraSnapshot
import com.opencapture.opencine.core.MonotonicInstant
import com.opencapture.opencine.core.MultiviewAutoLUT
import com.opencapture.opencine.core.MultiviewLinkRefusal
import com.opencapture.opencine.core.MultiviewLinkStatus
import com.opencapture.opencine.core.MultiviewMemberLink
import com.opencapture.opencine.core.MultiviewRecordReport
import com.opencapture.opencine.core.MultiviewRepairContext
import com.opencapture.opencine.core.MultiviewRepairResult
import com.opencapture.opencine.core.MultiviewRepairStep
import com.opencapture.opencine.core.PictureHealth
import com.opencapture.opencine.core.SessionCloseReason
import com.opencapture.opencine.core.StationNetwork
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import kotlin.coroutines.cancellation.CancellationException
import kotlin.time.Duration
import kotlin.time.Duration.Companion.milliseconds
import kotlin.time.Duration.Companion.seconds
import com.opencapture.opencine.core.CameraSession as OpenCineCameraSession

// Shared Multiview (Plan 6): one Nikon member's link as the shared coordinator drives it, over the
// prep operations (`NikonMemberOpener`, `NikonMemberRepair`, `CameraPropertySnapshot.recordingTone`)
// and the nikon `CameraSession` adapted as a common session (`NikonOpenCineSession`). Swift twin:
// `NikonMultiviewLink.swift`, same names.

/**
 * What a Nikon Multiview member's link runs on: one PTP session to one body. The app wraps the
 * nikon `SwiftCoreCameraSession` (its `liveFrames`); tests script it. Swift twin:
 * `NikonMultiviewTransport` (there the link pulls each frame; here frames are pushed and the link
 * watches the frame deadline).
 */
public interface NikonMultiviewTransport {
    /** The serial GetDeviceInfo reported after OpenSession; empty when the body gave none. */
    public val serialNumber: String

    /**
     * The body's control session: its serialized writes, record and reported properties. The Swift
     * core sends its commands between two live-view transactions on the same PTP session.
     */
    public val session: CameraSession

    /**
     * Live-view frames: collecting starts live view on the body, ending the collection stops it. A
     * frame the flow replays to a new collector (the same instance it already delivered) is not a new
     * picture; the link ignores it. Prefer a flow of the current stream only
     * (`SwiftCoreLiveFrameSource.currentStreamFrames`).
     */
    public val frames: Flow<LiveFrame>

    /** A graceful CloseSession, then the sockets. Never a record command. */
    public suspend fun shutdown()
}

/**
 * Why a Nikon member link did not open, with its operator copy (the shared coordinator shows it on
 * the tile: [MultiviewLinkRefusal]). Swift twin: `NikonMultiviewLinkError`.
 */
public sealed class NikonMultiviewLinkError(message: String) : Exception(message), MultiviewLinkRefusal {
    override val operatorMessage: String get() = message.orEmpty()

    /** [NikonMemberOpener] refused the body ([heldBy] for `HELD_BY_ANOTHER_DEVICE`). */
    public data class Refused(public val refusal: NikonMemberOpenRefusal, public val heldBy: String? = null) :
        NikonMultiviewLinkError(copy(refusal, heldBy))

    /** `startPreview` found no open link. */
    public data object NotOpen : NikonMultiviewLinkError("Could not connect preview.")

    /** The body does not know this phone: it is paired in the app's camera list first. */
    public data object NotPaired : NikonMultiviewLinkError(
        "This camera is not paired with this phone. Pair it in Your cameras, then tap Reconnect.",
    )

    public companion object {
        /**
         * The refusal a failed connect means for the operator, null for a dial that simply failed (the
         * coordinator then says it could not find the camera): a body that does not know this phone,
         * or one another device took between the holder check and the Init. The app's connect throws
         * it (Swift's link maps the session error itself).
         */
        public fun connectFailure(failure: CameraConnectionFailure?): NikonMultiviewLinkError? = when (failure) {
            CameraConnectionFailure.SAVED_PROFILE_REQUIRED,
            CameraConnectionFailure.REJECTED_INITIATOR,
            CameraConnectionFailure.PAIRING_CHALLENGE_UNAVAILABLE,
            -> NotPaired
            CameraConnectionFailure.BUSY -> Refused(NikonMemberOpenRefusal.HELD_BY_ANOTHER_DEVICE)
            else -> null
        }

        private fun copy(refusal: NikonMemberOpenRefusal, heldBy: String?): String = when (refusal) {
            NikonMemberOpenRefusal.HOST_IN_USE -> "This camera is still connecting. Wait a moment, then tap Reconnect."
            NikonMemberOpenRefusal.HELD_BY_ANOTHER_DEVICE -> NikonMultiviewCopy.heldBy(heldBy)
            NikonMemberOpenRefusal.ALREADY_MEMBER -> "This camera is already in Multiview."
            NikonMemberOpenRefusal.DIFFERENT_BODY ->
                "Another camera answered at this address. Remove this tile and add the camera again."
            NikonMemberOpenRefusal.NO_IDENTITY ->
                "This camera did not report its serial number, so Multiview cannot tell it from others."
        }
    }
}

/** The member link's operator copy. Swift twin: `NikonMultiviewCopy`. */
public object NikonMultiviewCopy {
    /** The automatic repairs are spent (the same words as every app's Multiview). */
    public const val COULD_NOT_RESTORE: String = "Could not restore preview. Tap Reconnect to try again."

    /** Another device holds the body: nothing here takes it back. */
    public fun heldBy(holder: String?): String =
        if (holder.isNullOrEmpty()) {
            "Another device is using this camera. Release it there, then tap Reconnect."
        } else {
            "In use on $holder. Release it there, then tap Reconnect."
        }
}

/**
 * One Nikon Multiview member's link (Swift twin: `NikonMultiviewLink`). The coordinator owns the
 * tile; this link opens the picked body at its address with the identity check and the reconnect
 * settle ([NikonMemberOpener], shared by every link of a stage), runs the member pump (collects the
 * body's live-view frames and watches the frame deadline), and repairs within the coordinator's
 * budget ([NikonMemberRepair]: three missed frames restart live view in place once, then reopen the
 * same body; each attempt asks `beginAttempt`; spent or taken over waits for the operator). It never
 * returns [MultiviewRepairResult.Rejoin], so the coordinator never spends a second attempt per
 * repair.
 *
 * The common session is the open link's ([NikonOpenCineSession] over the transport's session): an
 * open or a reopen makes a new one, so earlier plans and editor leases go stale. Before the first
 * open, and after a close, it is a closed session. Tone, battery and card values come from the
 * session's reported properties (the Swift core's live-monitor poll); this link sends no property
 * read of its own.
 *
 * Every method runs on [scope]'s dispatcher (the coordinator's main thread).
 *
 * @param opener the stage's one opener (every link of a stage shares it).
 * @param conversion the app's look title for a recording tone, null when none is needed.
 * @param framePace the pause after each frame (the app sheds non-program cadence under load).
 * @param wallClock the coordinator's clock in milliseconds, for [recordReport].
 */
public class NikonMultiviewLink<T : NikonMultiviewTransport>(
    private val opener: NikonMemberOpener<T>,
    private val scope: CoroutineScope,
    private val conversion: (NikonMovieTone) -> String?,
    private val now: () -> MonotonicInstant = { MonotonicInstant.now() },
    private val wallClock: () -> Long = System::currentTimeMillis,
    private val frameDeadline: Duration = 10.seconds,
    private val framePace: () -> Duration = { Duration.ZERO },
    private val closeLimit: Duration = 10.seconds,
    repair: NikonMemberRepair = NikonMemberRepair(),
) : MultiviewMemberLink<NikonMultiviewCamera> {
    private val ladder = repair
    private val idle: NikonOpenCineSession =
        NikonOpenCineSession(IdleNikonSession, scope, clock = now).also { it.closeNow(SessionCloseReason.REQUESTED) }
    private var pump: Job? = null
    private var closing: Job? = null

    /** Bumps on every open, reopen and close: late work of an older link changes nothing. */
    private var generation = 0
    private var missedFrames = 0

    /** The last frame this link counted: a flow replaying it to a new collector is not a new picture. */
    private var lastFrame: LiveFrame? = null
    private var device: CameraDeviceID? = null
    private var holder: String? = null
    private var tone: NikonMovieTone? = null

    override var onStatus: ((MultiviewLinkStatus) -> Unit)? = null

    /** Each picture of the current link as it arrives; the app's tile decodes and grades it. */
    public var onFrame: ((LiveFrame) -> Unit)? = null

    /** The open link, null while none is open or while it is lent to Live View. */
    public var transport: T? = null
        private set

    /** The open link's common session, null while none is open. */
    public var control: NikonOpenCineSession? = null
        private set

    /** Where the open link reached its body; empty before the first open. */
    public var host: String = ""
        private set

    /** The link is lent to the app's Live View ([lend]). */
    public var lent: Boolean = false
        private set

    override var recordReport: MultiviewRecordReport? = null
        private set

    override var pictureHealth: PictureHealth = PictureHealth.STARTING
        private set

    /** The last frame's header timecode. */
    public var timecode: LiveFrameTimecode? = null
        private set

    /** Above the ladder's 30 s attempt deadline, the settle and the spacing between reopens. */
    override val repairDeadline: Duration = 45.seconds

    override val session: OpenCineCameraSession get() = control ?: idle

    /** The common snapshot of the open link, re-read now. */
    public val snapshot: CameraSnapshot get() = (control ?: idle).refresh()

    /** Values exactly as the body reported them; empty while no link is open. */
    public val reported: CameraPropertySnapshot
        get() = transport?.session?.reportedCameraProperties?.value ?: CameraPropertySnapshot()

    /** The tone the body records in now (the last one read while the link is lent); null until read. */
    public val recordingTone: NikonMovieTone?
        get() = transport?.session?.reportedCameraProperties?.value?.recordingTone ?: tone

    override val autoLUT: MultiviewAutoLUT
        get() {
            val current = recordingTone
            return MultiviewAutoLUT(colorMode = current?.label, conversion = current?.let(conversion))
        }

    /** Never asked: the policy does not discover by probe (an unasked Init drops a held session). */
    override suspend fun probe(address: String, network: StationNetwork): Boolean = false

    override suspend fun open(
        camera: NikonMultiviewCamera,
        address: String,
        expecting: ByteArray?,
        network: StationNetwork,
    ): ByteArray {
        close()
        closing?.let { withTimeoutOrNull(closeLimit) { it.join() } }
        generation += 1
        val mine = generation
        onStatus?.invoke(MultiviewLinkStatus.OPENING)
        val expected = expecting?.toString(Charsets.UTF_8)
        val result = opener.open(address, expectedSerial = expected, members = emptySet(), hostsInUse = emptySet())
        val opened = result.link
        val body = result.device
        if (opened == null || body == null) {
            holder = result.heldBy
            throw NikonMultiviewLinkError.Refused(result.refusal ?: NikonMemberOpenRefusal.HOST_IN_USE, result.heldBy)
        }
        if (mine != generation || !currentCoroutineContext().isActive) {
            opener.close(opened, address)
            throw CancellationException("The open was superseded.")
        }
        attach(opened, address, body)
        ladder.reset()
        return identity(opened)
    }

    override suspend fun startPreview(camera: NikonMultiviewCamera) {
        if (transport == null || control == null) throw NikonMultiviewLinkError.NotOpen
        val mine = generation
        onStatus?.invoke(MultiviewLinkStatus.CONTROLLING)
        currentCoroutineContext().ensureActive()
        if (mine != generation) throw CancellationException("The link closed.")
        onStatus?.invoke(MultiviewLinkStatus.AWAITING_PICTURE)
        startPump()
    }

    /** The pump keeps the session busy; nothing to send here, so it returns at once. */
    override suspend fun keepalive() {}

    /**
     * Ends the session (CloseSession, never a record command) after live view stops, in the
     * background and within [closeLimit]; the next [open] waits for it, and the opener starts the
     * host's settle.
     */
    override fun close() {
        generation += 1
        val stopping = pump
        pump = null
        stopping?.cancel()
        lent = false
        missedFrames = 0
        recordReport = null
        pictureHealth = PictureHealth.STARTING
        control?.closeNow(SessionCloseReason.REQUESTED)
        control = null
        val closed = transport ?: return
        transport = null
        val host = host
        val previous = closing
        // Undispatched into NonCancellable: a stage scope cancelled right after this call cannot
        // skip the goodbye (a half-closed session holds the body's PTP slot).
        closing = scope.launch(start = CoroutineStart.UNDISPATCHED) {
            withContext(NonCancellable) {
                withTimeoutOrNull(closeLimit) {
                    previous?.join()
                    stopping?.join()
                }
                opener.close(closed, host)
            }
        }
    }

    /**
     * Returns once every close this link started has reached the opener (CloseSession sent or given
     * up): the app's own single-camera connect waits for it, then the settle, before it dials a body
     * a member held.
     */
    public suspend fun awaitClosed() {
        closing?.join()
    }

    override fun repair(context: MultiviewRepairContext): MultiviewRepairStep {
        if (device == null || lent) return MultiviewRepairStep.Healthy
        context.observeHealth(pictureHealth == PictureHealth.LIVE && missedFrames == 0)
        // Without the shared network the coordinator's path-loss rule decides, not the ladder.
        if (!context.pathReady) return MultiviewRepairStep.Healthy
        return when (val step = ladder.next(now(), context.beginAttempt)) {
            NikonMemberRepair.Step.None -> MultiviewRepairStep.Healthy
            is NikonMemberRepair.Step.Wait -> {
                onStatus?.invoke(MultiviewLinkStatus.RECONNECTING)
                MultiviewRepairStep.Handled
            }
            NikonMemberRepair.Step.RestartLiveView -> {
                onStatus?.invoke(MultiviewLinkStatus.RECONNECTING)
                MultiviewRepairStep.Repair {
                    restartLiveView()
                    MultiviewRepairResult.Done
                }
            }
            NikonMemberRepair.Step.Reopen -> {
                onStatus?.invoke(MultiviewLinkStatus.RECONNECTING)
                MultiviewRepairStep.Repair {
                    reopen()
                    MultiviewRepairResult.Done
                }
            }
            is NikonMemberRepair.Step.WaitForOperator -> MultiviewRepairStep.WaitForOperator(
                when (step.reason) {
                    NikonMemberRepair.WaitReason.TAKEN_OVER -> NikonMultiviewCopy.heldBy(holder)
                    NikonMemberRepair.WaitReason.BUDGET_SPENT -> NikonMultiviewCopy.COULD_NOT_RESTORE
                },
            )
        }
    }

    // Live View loan

    /**
     * Lends the open link to the app's Live View: this pump stops (live view ends until the Live
     * View collects the frames itself), the common session refuses new commands until [reclaim];
     * the PTP session stays open. Null when nothing is open or it is already lent.
     */
    public fun lend(): T? {
        val lending = transport ?: return null
        val control = control ?: return null
        if (lent) return null
        lent = true
        pump?.cancel()
        pump = null
        control.setHoldsControl(false)
        return lending
    }

    /**
     * The Live View stood down without closing the session. [returned] is what it holds now: the
     * lent link (this pump starts live view on it again), a replacement a recovery opened for the
     * same body (a new common session), or null (the link is lost: the repair ladder takes over). A
     * replacement of another body is closed and counts as lost.
     */
    public fun reclaim(returned: T?) {
        if (!lent) return
        lent = false
        val control = control
        if (returned != null && returned === transport && control != null) {
            control.setHoldsControl(true)
            startPump()
            return
        }
        generation += 1
        pump?.cancel()
        pump = null
        control?.closeNow(SessionCloseReason.LINK_LOST)
        this.control = null
        val lost = transport
        transport = null
        val at = now()
        // The Live View lost it: close it through the opener, so the reopen waits out the settle
        // after this close, not one the opener never saw.
        if (returned == null && lost != null) drop(lost)
        if (returned != null) {
            val body = device
            if (body != null && NikonMulticamPolicy.device(returned.serialNumber) == body) {
                attach(returned, host, body)
                startPump()
                return
            }
            val host = host
            scope.launch(start = CoroutineStart.UNDISPATCHED) { opener.close(returned, host) }
        }
        pictureHealth = PictureHealth.STALLED
        ladder.linkLost(at)
        onStatus?.invoke(MultiviewLinkStatus.RECONNECTING)
    }

    // Pump

    private fun identity(transport: T): ByteArray = transport.serialNumber.trim().toByteArray(Charsets.UTF_8)

    private fun attach(opened: T, host: String, device: CameraDeviceID) {
        transport = opened
        this.host = host
        this.device = device
        holder = null
        missedFrames = 0
        lastFrame = null
        recordReport = null
        timecode = null
        pictureHealth = PictureHealth.STARTING
        tone = opened.session.reportedCameraProperties.value.recordingTone
        control = NikonOpenCineSession(opened.session, scope, clock = now)
    }

    private fun startPump() {
        pump?.cancel()
        val transport = transport ?: return
        if (control == null || lent) return
        val mine = generation
        pump = scope.launch { runPump(transport, mine) }
    }

    private suspend fun current(mine: Int): Boolean =
        currentCoroutineContext().isActive && mine == generation && !lent

    /**
     * Collects the body's frames and judges each frame deadline: a frame resets the misses; a
     * deadline without one, or a stream that ended, is a miss; [NikonMemberRepair.MISSED_FRAMES_FOR_STALL]
     * misses stop the pump on a stall (and end live view: the collection ends with it). A session
     * that reports itself disconnected is a lost link: no restart on it, the ladder reopens.
     */
    private suspend fun runPump(transport: T, mine: Int): Unit = coroutineScope {
        val watch = launch {
            transport.session.state.first { it is CameraSessionState.Disconnected }
            if (current(mine)) lost(transport)
        }
        val arrivals = Channel<LiveFrame>(Channel.CONFLATED)
        val stream = launch {
            try {
                transport.frames.collect { arrivals.send(it) }
            } catch (error: CancellationException) {
                throw error
            } catch (_: Exception) {
                // The stream failed: every later look finds it closed and counts a miss.
            } finally {
                arrivals.close()
            }
        }
        try {
            while (current(mine)) {
                val result = withTimeoutOrNull(frameDeadline) { arrivals.receiveCatching() }
                if (!current(mine)) return@coroutineScope
                val frame = result?.getOrNull()
                // A replay of the frame already counted is not a picture: keep waiting for one.
                if (frame != null && frame === lastFrame) continue
                if (frame == null) {
                    missedFrames += 1
                    ladder.frameMissed(now())
                    if (missedFrames >= NikonMemberRepair.MISSED_FRAMES_FOR_STALL) {
                        stalled()
                        return@coroutineScope
                    }
                    // A stream that ended answers at once: pace the next look as a refused frame is.
                    if (result != null) delay(STREAM_ENDED_PAUSE)
                    continue
                }
                arrived(frame, transport)
                val pace = framePace()
                if (pace.isPositive()) delay(pace)
            }
        } finally {
            stream.cancel()
            watch.cancel()
        }
    }

    /**
     * The session reported the link dead: it is closed through the opener now (its settle runs beside
     * the ladder's) and the coordinator's next repair tick reopens after the settle.
     */
    private fun lost(dead: T) {
        generation += 1
        pump?.cancel()
        pump = null
        if (transport === dead) {
            transport = null
            drop(dead)
        }
        pictureHealth = PictureHealth.STALLED
        ladder.linkLost(now())
        onStatus?.invoke(MultiviewLinkStatus.RECONNECTING)
    }

    /** Closes a link that is no longer this member's through the opener, after any close before it. */
    private fun drop(link: T) {
        val host = host
        val previous = closing
        closing = scope.launch(start = CoroutineStart.UNDISPATCHED) {
            withContext(NonCancellable) {
                withTimeoutOrNull(closeLimit) { previous?.join() }
                opener.close(link, host)
            }
        }
    }

    /** The pump stopped on a stall: the coordinator's next repair tick runs the ladder. */
    private fun stalled() {
        pictureHealth = PictureHealth.STALLED
        ladder.streamStalled(now())
        onStatus?.invoke(MultiviewLinkStatus.RECONNECTING)
    }

    private fun arrived(frame: LiveFrame, transport: T) {
        lastFrame = frame
        missedFrames = 0
        ladder.frameArrived()
        timecode = frame.timecode
        recordReport = MultiviewRecordReport(recording = frame.isRecording, receivedAtMillis = wallClock())
        transport.session.reportedCameraProperties.value.recordingTone?.let { tone = it }
        if (pictureHealth != PictureHealth.LIVE) {
            pictureHealth = PictureHealth.LIVE
            onStatus?.invoke(MultiviewLinkStatus.LIVE)
        }
        onFrame?.invoke(frame)
    }

    // Repair steps

    /** Ends live view and starts it again on the same session: no new Init. */
    private suspend fun restartLiveView() {
        if (transport == null || control == null) {
            ladder.attemptFailed(now())
            return
        }
        val mine = generation
        pump?.let {
            pump = null
            it.cancel()
            it.join()
        }
        if (mine != generation || !currentCoroutineContext().isActive) return
        // The restart counts only when a new picture arrives (`frameArrived` ends the episode); a
        // replayed frame is not one, and without one the restarted pump stalls again and the ladder
        // reopens.
        missedFrames = 0
        onStatus?.invoke(MultiviewLinkStatus.AWAITING_PICTURE)
        startPump()
    }

    /**
     * Closes the member's link and opens its host again, refusing any other body. A link handed back
     * after the repair was given up (cancelled at the coordinator's deadline, or replaced) is closed
     * here: nobody else owns it.
     */
    private suspend fun reopen() {
        val member = device ?: return
        generation += 1
        val mine = generation
        val host = host
        pump?.cancel()
        pump = null
        control?.closeNow(SessionCloseReason.LINK_LOST)
        control = null
        pictureHealth = PictureHealth.STARTING
        transport?.let { old ->
            transport = null
            opener.close(old, host)
        }
        // A link dropped earlier (lost, or lost in Live View) finishes closing first: the opener's
        // settle starts at its close.
        closing?.let { withTimeoutOrNull(closeLimit) { it.join() } }
        val result = try {
            opener.reopen(member, host, members = emptySet(), hostsInUse = emptySet())
        } catch (error: CancellationException) {
            throw error
        } catch (_: Exception) {
            if (mine == generation) ladder.attemptFailed(now())
            return
        }
        val opened = result.link
        if (opened != null) {
            if (mine != generation || !currentCoroutineContext().isActive) {
                opener.close(opened, host)
                return
            }
            attach(opened, host, member)
            ladder.attemptSucceeded()
            onStatus?.invoke(MultiviewLinkStatus.AWAITING_PICTURE)
            startPump()
            return
        }
        if (mine != generation) return
        if (result.refusal == NikonMemberOpenRefusal.HELD_BY_ANOTHER_DEVICE) {
            holder = result.heldBy
            ladder.takenOver()
        } else {
            // HOST_IN_USE here means an earlier dial of this host is still running: the ladder
            // spaces the next attempt.
            ladder.attemptFailed(now())
        }
    }

    private companion object {
        val STREAM_ENDED_PAUSE: Duration = 250.milliseconds
    }
}

/** The closed session a link shows before its first open and after a close. */
private object IdleNikonSession : CameraSession {
    override val state: StateFlow<CameraSessionState> = MutableStateFlow(CameraSessionState.Disconnected)
    override val recordingState: StateFlow<CameraRecordingState> = MutableStateFlow(CameraRecordingState.STANDBY)

    override suspend fun connect() {}

    override suspend fun setRecording(recording: Boolean): Unit = throw CameraRecordingException.NotConnected

    override suspend fun disconnect() {}
}
