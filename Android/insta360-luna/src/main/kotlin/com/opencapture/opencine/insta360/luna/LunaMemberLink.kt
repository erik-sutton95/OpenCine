package com.opencapture.opencine.insta360.luna

import com.opencapture.opencine.core.CameraSession
import com.opencapture.opencine.core.ConnectionFailure
import com.opencapture.opencine.core.ConnectionPhase as CorePhase
import com.opencapture.opencine.core.MonotonicInstant
import com.opencapture.opencine.core.MultiviewAutoLUT
import com.opencapture.opencine.core.MultiviewLinkStatus
import com.opencapture.opencine.core.MultiviewMemberLink
import com.opencapture.opencine.core.MultiviewRecordReport
import com.opencapture.opencine.core.MultiviewRepairContext
import com.opencapture.opencine.core.MultiviewRepairResult
import com.opencapture.opencine.core.MultiviewRepairStep
import com.opencapture.opencine.core.NearbyCamera
import com.opencapture.opencine.core.PictureHealth
import com.opencapture.opencine.core.RecordingState
import com.opencapture.opencine.core.RecoveryAction
import com.opencapture.opencine.core.StationNetwork
import com.opencapture.opencine.insta360.shell.ConnectionPhase
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.first
import kotlin.time.Duration
import kotlin.time.Duration.Companion.seconds

/**
 * One Multiview member's link to its Luna on the shared network (Swift twin: `LunaMemberLink`), over
 * its own connection ([LunaStationPort], a [LunaBackend] the app keeps for the member): a greeting
 * probe that opens no session, a LAN-only open that proves the camera by its serial, the member's
 * one common session, the camera's record reports, Luna's repair and the Auto LUT source. It never
 * sends a record command; closing only disconnects. Bluetooth is used only by a repair, inside the
 * coordinator's Bluetooth turn. Unlike iOS, [LunaBackend] runs Luna's stall ladder (`LunaFeedStall`)
 * on its own live link, so a stall reaches this link only as a lost link. Main thread.
 * Hardware-untested.
 *
 * @param clock the coordinator's clock in milliseconds: record reports are stamped on it.
 * @param conversion the app's monitoring conversion for the color profile the picture carries (a
 *   LUT title), null when that profile needs none.
 * @param preview the color profile the picture carries for a recorded one: Luna's Color Recovery
 *   may grade an I-Log recording's feed before it reaches the phone, so the Auto LUT follows the
 *   app's preview rule (the one its Live View uses), never the recording profile alone. By default
 *   the recorded profile itself.
 */
class LunaMemberLink(
    val port: LunaStationPort,
    private val clock: () -> Long,
    private val conversion: (colorProfile: String) -> String? = { null },
    private val preview: (recordedProfile: String) -> String = { it },
) : MultiviewMemberLink<NearbyCamera> {
    private class Opened(val camera: NearbyCamera, val address: String, val network: StationNetwork, val serial: String)

    /** The member's one common session, for the member's lifetime: it follows every reconnect. */
    val lunaSession: LunaCameraSession = port.openSession()
    override val session: CameraSession get() = lunaSession
    override var pictureHealth: PictureHealth = PictureHealth.STARTING
        private set
    override var onStatus: ((MultiviewLinkStatus) -> Unit)? = null
    override var recordReport: MultiviewRecordReport? = null
        private set

    /** A repair may reach the camera over Bluetooth, wait for its approval and move it again. */
    override val repairDeadline: Duration get() = 120.seconds

    private var opened: Opened? = null
    private var previewing = false
    private var reportedLive = false
    /** The backend's own ladder is restarting live in place (silence past its restart point). */
    private var restarting = false
    private var recordObservedAt: MonotonicInstant? = null

    override suspend fun probe(address: String, network: StationNetwork): Boolean =
        port.probeStation(address, luna(network))

    /**
     * Opens the camera at [address], LAN only, with the serial [expecting] carries checked before
     * anything else is sent. A Luna is always opened with its serial: without one the open is
     * refused. Control and live start are one step on Luna, so the picture starts here.
     */
    override suspend fun open(camera: NearbyCamera, address: String, expecting: ByteArray?, network: StationNetwork): ByteArray {
        val serial = expecting?.let(LunaMultiview::serial) ?: throw LunaStationStepFailure(failure(
            ConnectionFailure.Reason.Unsupported, "multiview.no-serial", "This camera's serial is not known yet. Add it again.",
        ))
        close()
        onStatus?.invoke(MultiviewLinkStatus.OPENING)
        port.connect(camera.id, LunaStationHost(network.ssid, network.hotspot, address, serial), luna(network))?.let {
            throw LunaStationStepFailure(it)
        }
        val ended = try {
            // A connect that ends without either (the backend closed, a stray disconnect) ends the
            // open too: back to IDLE after it left IDLE.
            var started = false
            port.phase.first { phase ->
                if (phase != ConnectionPhase.IDLE) started = true
                phase == ConnectionPhase.LIVE || phase == ConnectionPhase.FAILED || (started && phase == ConnectionPhase.IDLE)
            }
        } catch (cancelled: CancellationException) {
            port.disconnect()
            throw cancelled
        }
        if (ended != ConnectionPhase.LIVE) {
            throw LunaStationStepFailure(port.failureDetail.value ?: failure(
                ConnectionFailure.Reason.NotFound, "station.known-host-silent", "The camera did not answer at its last address.",
            ))
        }
        opened = Opened(camera, address, network, serial)
        return LunaMultiview.identity(serial)
    }

    override suspend fun startPreview(camera: NearbyCamera) {
        if (opened == null || port.phase.value != ConnectionPhase.LIVE) {
            throw LunaStationStepFailure(failure(ConnectionFailure.Reason.LinkLost, "link.closed", "The camera connection closed."))
        }
        onStatus?.invoke(MultiviewLinkStatus.CONTROLLING)
        previewing = true
        reportedLive = false
        restarting = false
        pictureHealth = PictureHealth.STARTING
        onStatus?.invoke(MultiviewLinkStatus.AWAITING_PICTURE)
        observePicture()
    }

    /** Follows the picture and the camera's record report, once a second. */
    override suspend fun keepalive() {
        observeRecording()
        observePicture()
    }

    override fun close() {
        port.disconnect()
        opened = null
        previewing = false
        reportedLive = false
        restarting = false
        recordReport = null
        recordObservedAt = null
        pictureHealth = PictureHealth.FAILED
    }

    /**
     * Luna's repair, once a second while the member publishes. The live link repairs a stall in
     * place itself (the tile reads Reconnecting while it restarts live, as on iOS); a lost link is repaired by finding the camera again: a camera that does not
     * answer at its address is moved onto the network over Bluetooth (in the coordinator's turn),
     * then the coordinator rejoins it, LAN only.
     */
    override fun repair(context: MultiviewRepairContext): MultiviewRepairStep {
        val opened = opened
        if (!previewing || opened == null) return MultiviewRepairStep.Healthy
        if (port.phase.value == ConnectionPhase.LIVE) {
            val silence = port.secondsSinceVideo ?: 0.0
            val healthy = silence <= LunaFeedStall.KEYFRAME_AFTER
            context.observeHealth(healthy)
            if (silence > LunaFeedStall.RESTART_AFTER && !restarting) {
                restarting = true
                // The picture reports Live again once it returns.
                reportedLive = false
                onStatus?.invoke(MultiviewLinkStatus.RECONNECTING)
            }
            return if (healthy) MultiviewRepairStep.Healthy else MultiviewRepairStep.Handled
        }
        // This phone left the shared network: the coordinator's path rule decides.
        if (!context.pathReady) return MultiviewRepairStep.Healthy
        context.observeHealth(false)
        pictureHealth = PictureHealth.FAILED
        onStatus?.invoke(MultiviewLinkStatus.RECONNECTING)
        return MultiviewRepairStep.Repair { findAgain(opened, context) }
    }

    /**
     * The camera at its address answers: the coordinator rejoins it there. Otherwise it is moved onto
     * the network again over Bluetooth, in the coordinator's turn, and then rejoined. A camera that
     * refuses this phone waits for the operator.
     */
    private suspend fun findAgain(opened: Opened, context: MultiviewRepairContext): MultiviewRepairResult {
        port.disconnect()
        if (port.probeStation(opened.address, luna(opened.network))) return MultiviewRepairResult.Rejoin
        if (!context.running()) return MultiviewRepairResult.Done
        val release = context.bluetoothTurn() ?: return MultiviewRepairResult.Done
        try {
            port.authorizeForStation(opened.camera.id)
            port.moveOntoStation(luna(opened.network))
            return MultiviewRepairResult.Rejoin
        } catch (cancelled: CancellationException) {
            port.disconnect()
            throw cancelled
        } catch (error: Exception) {
            port.disconnect()
            val failure = (error as? LunaStationStepFailure)?.failure
            if (failure != null && (failure.reason == ConnectionFailure.Reason.NotApproved || failure.reason == ConnectionFailure.Reason.HeldElsewhere)) {
                return MultiviewRepairResult.WaitForOperator(failure.message)
            }
            return MultiviewRepairResult.Rejoin
        } finally {
            release()
        }
    }

    /**
     * The Auto LUT follows what the picture carries: the camera's reported color profile through the
     * app's [preview] rule, and the app's conversion for that.
     */
    override val autoLUT: MultiviewAutoLUT
        get() {
            val profile = lunaSession.snapshots.value.recordingFormat.profile.value?.let(preview)
            return MultiviewAutoLUT(profile, profile?.let(conversion))
        }

    private fun observePicture() {
        if (!previewing) return
        if (port.phase.value != ConnectionPhase.LIVE) {
            pictureHealth = PictureHealth.FAILED
            return
        }
        val silence = port.secondsSinceVideo ?: return
        if (silence <= LunaFeedStall.KEYFRAME_AFTER) {
            restarting = false
            pictureHealth = PictureHealth.LIVE
            if (!reportedLive) {
                reportedLive = true
                onStatus?.invoke(MultiviewLinkStatus.LIVE)
            }
        } else {
            pictureHealth = PictureHealth.STALLED
        }
    }

    /** The camera's own record state, stamped on the coordinator's clock when a new report arrived. */
    private fun observeRecording() {
        if (opened == null || port.phase.value != ConnectionPhase.LIVE) {
            recordReport = null
            return
        }
        val reported = lunaSession.snapshots.value.recording
        val at = reported.observedAt ?: return
        val value = reported.value ?: return
        if (at == recordObservedAt) return
        recordObservedAt = at
        recordReport = MultiviewRecordReport(value == RecordingState.RECORDING, clock())
    }

    private fun failure(reason: ConnectionFailure.Reason, code: String, message: String) =
        LunaFailures.failure(reason, code, message, CorePhase.JOINING_NETWORK, listOf(RecoveryAction.Retry))

    private fun luna(network: StationNetwork) = LunaStationNetwork(network.ssid, network.password, network.hotspot)
}
