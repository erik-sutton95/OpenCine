package com.opencapture.opencine.insta360.luna

import com.opencapture.opencine.core.Availability
import com.opencapture.opencine.core.MulticamQualification
import com.opencapture.opencine.core.MulticamQualificationRefusal
import com.opencapture.opencine.core.MultiviewCameraPolicy
import com.opencapture.opencine.core.NearbyCamera
import com.opencapture.opencine.core.NearbyCameraScanner
import com.opencapture.opencine.core.StationCameraRecord
import com.opencapture.opencine.core.StationCommission
import com.opencapture.opencine.core.StationCommissionOutcome
import com.opencapture.opencine.core.StationCommissioner
import com.opencapture.opencine.core.StationNetwork
import com.opencapture.opencine.core.StationRestoreResult
import com.opencapture.opencine.core.StationVerifyFinal
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.Flow

/**
 * Luna's answers to a Multiview stage (Swift twin: `LunaMultiview`): which nearby Lunas may join,
 * how a sighting is journaled, and the identity a member proves (its serial). A Luna joins a stage
 * over Bluetooth ([LunaStationCommissioner] moves it onto the shared network) and is found there by
 * a greeting probe on its control port, opened only with its serial checked ([LunaMemberLink]).
 */
object LunaMultiview {
    /**
     * Every available Luna sighting may join, with its picture; one another device holds is not
     * offered. Luna has no experimental join path. Members are found by probing the shared network:
     * a probe opens no session, and a camera is opened only with its serial checked.
     */
    val policy: MultiviewCameraPolicy<NearbyCamera> = MultiviewCameraPolicy(
        discoversByProbe = true,
        qualification = { camera, experimental ->
            when {
                experimental -> MulticamQualification.Refused(MulticamQualificationRefusal.UNSUPPORTED_CONFIGURATION)
                camera.availability is Availability.Unavailable -> MulticamQualification.Refused(MulticamQualificationRefusal.OPERATION_UNAVAILABLE)
                else -> MulticamQualification.Qualified
            }
        },
        hasPreview = { true },
    )

    /** The journal record of a sighting: its Bluetooth address and name. A Luna reports no model code. */
    fun record(camera: NearbyCamera): StationCameraRecord = StationCameraRecord(camera.id, camera.name, modelId = null)

    /** The identity a member proves: its serial's bytes. */
    fun identity(serial: String): ByteArray = serial.toByteArray(Charsets.UTF_8)

    /** The serial an identity carries; null for none. */
    fun serial(identity: ByteArray): String? = identity.takeIf { it.isNotEmpty() }?.toString(Charsets.UTF_8)
}

/**
 * Luna's [StationCommissioner] (Swift twin alike): moves a nearby Luna from its own access point
 * onto the stage's shared network over Bluetooth, as a Wi-Fi or hotspot setup's connect does, and
 * back. Each commission and each return runs on a port of its own ([makePort], a fresh backend),
 * so the stage's members keep their connections. Waits use `delay` (virtual time under `runTest`);
 * [now] reads the same clock in milliseconds. Hardware-untested.
 */
class LunaStationCommissioner(
    private val makePort: () -> LunaStationPort,
    private val now: () -> Long = { System.nanoTime() / 1_000_000 },
) : StationCommissioner<NearbyCamera> {
    companion object {
        /** How long a join keeps asking `verifyOnNetwork` after the camera moved (it needs a DHCP lease first). */
        const val VERIFY_BUDGET_MS: Long = 60_000
        /** The pause between two `verifyOnNetwork` tries. */
        const val VERIFY_INTERVAL_MS: Long = 3_000
        /** Tries of a return to the access point, and the pause between deferred ones. */
        const val RETURN_ATTEMPTS: Int = 3
        const val RETURN_INTERVAL_MS: Long = 3_000
    }

    private val commissions = mutableListOf<Commission>()

    /** Luna has no experimental join path. */
    override val joinsExperimentally: Boolean get() = false

    /** The camera may ask the operator to allow this phone (Bluetooth authorization). */
    override val asksApprovalOnCamera: Boolean get() = true

    override fun record(camera: NearbyCamera): StationCameraRecord = LunaMultiview.record(camera)

    /** Bluetooth reaches the camera, which approves this phone, and the serial is read. The link stays open for `join`. */
    override suspend fun connect(camera: NearbyCamera, progress: (String) -> Unit): StationCommission {
        val commission = Commission(makePort(), now) { commissions.remove(it) }
        commissions += commission
        try {
            commission.serial = commission.port.authorizeForStation(camera.id)
        } catch (error: Throwable) {
            commission.close()
            throw error
        }
        return commission
    }

    override fun closeCommissions() {
        commissions.toList().forEach { it.close() }
        commissions.clear()
    }

    /**
     * One camera's return to its own access point over Bluetooth, retried while the camera defers.
     * Only `Returned` is restored; every other answer, the camera's own refusals included, is
     * `Deferred` with its copy, so the cleanup journal keeps it (Plan 3 cleanup ruling). A cancelled
     * caller is cancelled (Kotlin propagates, `docs/core/README.md`); a thrown return is `Failed`.
     */
    override suspend fun restoreAccessPoint(record: StationCameraRecord): StationRestoreResult {
        val port = makePort()
        try {
            val result = LunaAccessPointReturn.retrying(RETURN_ATTEMPTS, { delay(RETURN_INTERVAL_MS) }) {
                port.returnToAccessPoint(record.id)
            }
            return when (result) {
                LunaAccessPointReturn.Returned -> StationRestoreResult.Restored
                is LunaAccessPointReturn.Deferred -> StationRestoreResult.Deferred(result.failure.message)
                is LunaAccessPointReturn.Failed -> StationRestoreResult.Deferred(result.failure.message)
            }
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Exception) {
            return StationRestoreResult.Failed
        } finally {
            port.close()
        }
    }

    /** One camera's Bluetooth link while it moves onto the network. */
    internal class Commission(val port: LunaStationPort, private val now: () -> Long, private val onClose: (Commission) -> Unit) : StationCommission {
        var serial: String = ""
        private var closed = false

        override suspend fun identity(): ByteArray = LunaMultiview.identity(serial)

        /** Moves the camera, then asks [verifyOnNetwork] until it found the camera or the budget passed. */
        override suspend fun join(
            network: StationNetwork,
            identity: ByteArray,
            experimental: Boolean,
            progress: (String) -> Unit,
            verifyOnNetwork: suspend () -> Boolean,
        ): StationCommissionOutcome {
            progress("Moving the camera to “${network.ssid}”…")
            port.moveOntoStation(LunaStationNetwork(network.ssid, network.password, network.hotspot))
            val deadline = now() + VERIFY_BUDGET_MS
            while (true) {
                currentCoroutineContext().ensureActive()
                try {
                    if (verifyOnNetwork()) return StationCommissionOutcome.VERIFIED
                } catch (final: StationVerifyFinal) {
                    throw final
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (_: Exception) {
                    // Not on the network yet: the camera is still taking its address.
                }
                if (now() + VERIFY_INTERVAL_MS >= deadline) return StationCommissionOutcome.JOINED
                delay(VERIFY_INTERVAL_MS)
            }
        }

        override fun close() {
            if (closed) return
            closed = true
            port.close()
            onClose(this)
        }
    }
}

/**
 * Nearby Lunas for a Multiview stage's Add list, from the integration's passive discovery (Swift
 * twin: `LunaNearbyScanner`). [discover] is `LunaIntegration.discover(DiscoveryMode.PASSIVE)`.
 */
class LunaNearbyScanner(private val discover: () -> Flow<List<NearbyCamera>>) : NearbyCameraScanner<NearbyCamera> {
    /** Bluetooth readiness shows in the sightings themselves (none while it is off). */
    override suspend fun waitUntilReady(): Boolean = true

    override suspend fun scan(found: (NearbyCamera) -> Unit) {
        discover().collect { sightings -> sightings.forEach(found) }
    }

    /** The coordinator cancels the scan's job, which ends the discovery subscription. */
    override fun stop() {}
}
