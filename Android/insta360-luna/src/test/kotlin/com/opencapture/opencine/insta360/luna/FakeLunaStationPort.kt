package com.opencapture.opencine.insta360.luna

import com.opencapture.opencine.core.ConnectionFailure
import com.opencapture.opencine.core.ConnectionPhase as CorePhase
import com.opencapture.opencine.core.RecoveryAction
import com.opencapture.opencine.insta360.shell.ConnectionPhase
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

/**
 * A scripted Luna connection behind the Multiview pieces (Swift `FakeLunaStationPort`): it records
 * every step a commissioner or member link asks of it, answers from what the test set, and backs its
 * session with a [FakeLuna]. A new authorization or connect, and [disconnect], end the one before.
 */
internal class FakeLunaStationPort(scope: CoroutineScope) : LunaStationPort {
    sealed interface Step {
        data class Authorize(val id: String) : Step
        data class Move(val network: LunaStationNetwork) : Step
        data class Probe(val host: String) : Step
        data class Connect(val id: String, val host: String, val serial: String) : Step
        data class ReturnToAccessPoint(val id: String) : Step
        data object Disconnect : Step
    }

    private val _phase = MutableStateFlow(ConnectionPhase.IDLE)
    override val phase: StateFlow<ConnectionPhase> = _phase
    private val _failure = MutableStateFlow<ConnectionFailure?>(null)
    override val failureDetail: StateFlow<ConnectionFailure?> = _failure
    override var stationHostsInUse: (() -> Set<String>)? = null
    var serial = "LUNA-A"
    var authorizeFailure: Exception? = null
    var reportedAddress: String? = null
    var moveFailure: Exception? = null
    var answering: Set<String> = emptySet()
    val cameras = HashMap<String, String>()
    val returns = ArrayDeque<LunaAccessPointReturn>()
    /** Thrown by the next return to the access point, when set. */
    var returnFailure: Exception? = null
    /** A connect that neither goes live nor fails until the test moves the phase (a slow camera). */
    var connectStaysPending = false
    /** Whether [close] ended this connection for good. */
    var closed = false
        private set
    /** Runs inside each Bluetooth step and return before it answers (a test holds it). */
    var during: suspend (Step) -> Unit = {}
    override var secondsSinceVideo: Double? = null
    val steps = mutableListOf<Step>()
    var bluetoothOpen = false
        private set
    var sessionsOpened = 0
        private set
    val camera = FakeLuna(scope)
    private var session: LunaCameraSession? = null

    override suspend fun authorizeForStation(id: String): String {
        disconnect()
        steps += Step.Authorize(id)
        during(Step.Authorize(id))
        authorizeFailure?.let { throw it }
        bluetoothOpen = true
        return serial
    }

    override suspend fun moveOntoStation(network: LunaStationNetwork): String? {
        if (!bluetoothOpen) throw LunaStationStepFailure(failure(ConnectionFailure.Reason.Other, "station.not-authorized"))
        steps += Step.Move(network)
        during(Step.Move(network))
        bluetoothOpen = false
        moveFailure?.let { throw it }
        return reportedAddress
    }

    override suspend fun probeStation(host: String, network: LunaStationNetwork): Boolean {
        steps += Step.Probe(host)
        return host in answering
    }

    override fun connect(id: String, at: LunaStationHost, on: LunaStationNetwork): ConnectionFailure? {
        if (at.host in stationHostsInUse?.invoke().orEmpty()) return failure(ConnectionFailure.Reason.Other, "station.host-in-use")
        steps += Step.Connect(id, at.host, at.serial)
        val found = cameras[at.host]
        if (connectStaysPending) {
            _phase.value = ConnectionPhase.OPENING_DATALINK
            return null
        }
        when {
            found == null -> fail(failure(ConnectionFailure.Reason.NotFound, "station.known-host-silent"))
            found != at.serial -> fail(failure(ConnectionFailure.Reason.WrongCamera, "wifi.serial-mismatch"))
            else -> {
                secondsSinceVideo = 0.0
                _phase.value = ConnectionPhase.LIVE
                session?.linkChanged(ConnectionPhase.LIVE, found)
            }
        }
        return null
    }

    private fun fail(failure: ConnectionFailure) {
        _failure.value = failure
        _phase.value = ConnectionPhase.FAILED
    }

    override suspend fun returnToAccessPoint(id: String): LunaAccessPointReturn {
        disconnect()
        steps += Step.ReturnToAccessPoint(id)
        during(Step.ReturnToAccessPoint(id))
        returnFailure?.let { throw it }
        return returns.removeFirstOrNull() ?: LunaAccessPointReturn.Returned
    }

    override fun openSession(): LunaCameraSession {
        sessionsOpened += 1
        return camera.makeSession().also { session = it }
    }

    override fun disconnect() {
        if (!bluetoothOpen && _phase.value == ConnectionPhase.IDLE) return
        steps += Step.Disconnect
        bluetoothOpen = false
        secondsSinceVideo = null
        _failure.value = null
        _phase.value = ConnectionPhase.IDLE
        session?.linkChanged(ConnectionPhase.IDLE)
    }

    override fun close() {
        disconnect()
        closed = true
    }

    /** The control link dropped (the camera left the network): nothing was asked of the port. */
    fun dropLink() {
        _phase.value = ConnectionPhase.FAILED
        session?.linkChanged(ConnectionPhase.FAILED)
    }

    companion object {
        fun failure(reason: ConnectionFailure.Reason, code: String): ConnectionFailure =
            LunaFailures.failure(reason, code, code, CorePhase.JOINING_NETWORK, listOf(RecoveryAction.Retry))
    }
}
