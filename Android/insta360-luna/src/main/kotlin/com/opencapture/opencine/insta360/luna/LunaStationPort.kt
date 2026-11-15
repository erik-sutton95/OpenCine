package com.opencapture.opencine.insta360.luna

import com.opencapture.opencine.core.ConnectionFailure
import com.opencapture.opencine.insta360.shell.ConnectionPhase
import kotlinx.coroutines.flow.StateFlow

/**
 * What Luna's Multiview pieces ([LunaStationCommissioner], [LunaMemberLink]) need from one camera
 * connection: the two Bluetooth steps of a station move, the LAN probe and LAN-only open, the
 * return to the access point and the live picture's clock. [LunaBackend] is the one implementation;
 * tests script a fake. Swift twin: `LunaStationPort`.
 */
interface LunaStationPort {
    /** The connection's phase: a LAN-only [connect] ends at [ConnectionPhase.LIVE] or [ConnectionPhase.FAILED]. */
    val phase: StateFlow<ConnectionPhase>
    /** Why the last connect failed; null while none has. */
    val failureDetail: StateFlow<ConnectionFailure?>
    /** Hosts other connections of this app hold on the shared network; no search or open reaches them. */
    var stationHostsInUse: (() -> Set<String>)?
    /** Bluetooth, approval on the camera and the credential read; returns the serial. Fails with [LunaStationStepFailure]. */
    suspend fun authorizeForStation(id: String): String
    /** The authorized camera joins [network]; Bluetooth closes. Returns any address it reported. */
    suspend fun moveOntoStation(network: LunaStationNetwork): String?
    /** Whether a Luna answers its control port at [host], without a session. */
    suspend fun probeStation(host: String, network: LunaStationNetwork): Boolean
    /** Starts opening the camera at [at], LAN only, checking its serial; a refusal is returned at once. */
    fun connect(id: String, at: LunaStationHost, on: LunaStationNetwork): ConnectionFailure?
    /** One try at asking the camera back onto its own access point over Bluetooth. */
    suspend fun returnToAccessPoint(id: String): LunaAccessPointReturn
    /** The connection's common session; it follows every later connect of this port. */
    fun openSession(): LunaCameraSession
    /** Seconds since the last video unit while live; null otherwise. */
    val secondsSinceVideo: Double?
    /** Ends the connection (Bluetooth and control link). Never a camera command but stop-live. */
    fun disconnect()
    /** Ends the connection for good and frees what it holds (a commission's or a return's own connection). */
    fun close()
}

/** A station step that failed, with the operator copy the backend shows ([failure]). */
class LunaStationStepFailure(val failure: ConnectionFailure) : Exception(failure.message)
