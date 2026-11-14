package com.opencapture.opencine.dji

import android.content.Context
import com.opencapture.opencine.core.StationCameraRecord
import com.opencapture.opencine.core.StationCommission
import com.opencapture.opencine.core.StationCommissionOutcome
import com.opencapture.opencine.core.StationCommissioner
import com.opencapture.opencine.core.StationHostPath
import com.opencapture.opencine.core.StationNetwork
import com.opencapture.opencine.vocabulary.CameraModel
import com.opencapture.opencine.vocabulary.FoundCamera
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.delay

/**
 * DJI's [StationCommissioner]: Multiview's Bluetooth pairing, the Nano Wi-Fi wake, the `07/07`
 * identity (with one Wi-Fi wake when its reply is missing), the captured station join and the
 * return to the camera's own access point, over [MultiviewProvisioner]. [hostPath] answers
 * whether this phone's hotspot is up; [log] receives diagnostics, never a password. Which bodies
 * may join and show a picture is [MultiviewCameraPolicy.dji]. Call it from one thread (the
 * coordinator's main thread): its record of open commission links is not synchronized. Swift twin:
 * `DJIStationCommissioner` in `OpenCineDJIApple`.
 */
class DjiStationCommissioner(
    context: Context,
    private val hostPath: StationHostPath,
    private val log: (String) -> Unit = {},
) : StationCommissioner<FoundCamera> {
    private val app = context.applicationContext
    private val open = LinkedHashSet<MultiviewProvisioner>()
    private val joinPolicy: StationJoin.Policy by lazy { StationJoin.Policy.fromCore() }

    override fun record(camera: FoundCamera): StationCameraRecord =
        StationCameraRecord(camera.id, camera.name, camera.modelId, camera.address)

    override suspend fun connect(camera: FoundCamera, progress: (String) -> Unit): StationCommission {
        val client = MultiviewProvisioner(app)
        open += client
        try {
            client.connect(camera)
            if (camera.model.family == "nano") {
                progress("Waking camera Wi-Fi")
                val wake = client.exchange(DjiNative.CMD_SESSION_5310).payload.map { it.toInt() and 0xFF }
                if (wake != listOf(1, 0, 0, 0)) {
                    throw MultiviewFailure.Message(
                        "The Nano did not confirm its Wi-Fi wake. Keep it powered on and try again.")
                }
                delay(1_000)
            }
        } catch (error: Throwable) {
            client.close()
            open -= client
            throw error
        }
        return Commission(camera, client)
    }

    override fun closeCommissions() {
        open.toList().forEach { it.close() }
        open.clear()
    }

    override suspend fun restoreAccessPoint(record: StationCameraRecord): Boolean =
        restoreCameraWiFiWithRetry { restoreOnce(record) }

    override val scansNetworks: Boolean get() = true

    override suspend fun scanNetworks(
        camera: FoundCamera,
        beforeStationChange: () -> Unit,
        onRestored: (Boolean) -> Unit,
        onFound: (String) -> Unit,
    ) = MultiviewProvisioner(app).scanNetworks(camera, beforeStationChange, onRestored, onFound)

    /** One `07/48 00` over a fresh link; false without the camera's Bluetooth address. */
    private suspend fun restoreOnce(record: StationCameraRecord): Boolean {
        val address = record.deviceAddress
        if (address.isNullOrEmpty()) return false
        val client = MultiviewProvisioner(app)
        return try {
            val model = CameraModel.fromJson(DjiNative.resolveCameraModel(record.modelId ?: -1, record.name, address, true))
            client.connect(FoundCamera(record.id, address, record.name, model, record.modelId), pairingTimeoutMs = 12_000)
            val reply = hex(client.exchange(DjiNative.CMD_MULTICAM_STATION_MODE, "0").payload)
            val accepted = reply == "00" || reply == "0000"
            log("multiview: return camera Wi-Fi accepted=$accepted")
            accepted
        } catch (error: CancellationException) {
            throw error
        } catch (error: Exception) {
            log("multiview: return camera Wi-Fi failed ${error.javaClass.simpleName}")
            throw error
        } finally {
            client.close()
        }
    }

    /** One camera's Bluetooth setup link while it moves onto the station network. */
    private inner class Commission(
        private val camera: FoundCamera,
        private val client: MultiviewProvisioner,
    ) : StationCommission {
        /**
         * A Pocket just returned to its own AP ignored this query until the `53/10` Wi-Fi wake that
         * single-camera pairing always sends (Pocket 4 Pro, Android, 2026-09-23). One wake and one
         * retry; any other failure still stops setup.
         */
        override suspend fun identity(): ByteArray {
            val identity = try {
                client.exchange(DjiNative.CMD_GET_WIFI_SSID).payload
            } catch (_: MultiviewFailure.Timeout) {
                log("multiview: identity reply missing; sending Wi-Fi wake once")
                try {
                    client.exchange(DjiNative.CMD_SESSION_5310, timeoutMs = 2_000)
                } catch (_: MultiviewFailure) {
                }
                delay(600)
                client.exchange(DjiNative.CMD_GET_WIFI_SSID).payload
            }
            if (identity.size <= 2 || identity[0].toInt() != 0) throw MultiviewFailure.Rejected()
            return identity
        }

        override suspend fun join(
            network: StationNetwork,
            identity: ByteArray,
            experimental: Boolean,
            progress: (String) -> Unit,
            verifyOnNetwork: suspend () -> Boolean,
        ): StationCommissionOutcome {
            val outcome = StationJoin(
                ssid = network.ssid, password = network.password, hotspot = network.hotspot,
                hasPreview = camera.hasMultiviewPreview,
                missingRoleQueryE0 = camera.multicamSupport().missingRoleQueryE0,
                experimental = experimental,
                policy = joinPolicy,
            ).run(
                identity,
                exchange = { kind, extra, timeoutMs -> client.exchange(kind, extra, timeoutMs).payload },
                send = { client.send(it) },
                status = progress,
                hotspotReady = { hostPath.address(true) != null },
                verifyOnNetwork = verifyOnNetwork,
                log = { log("multiview: $it") },
            )
            return if (outcome == StationJoin.Outcome.VERIFIED) StationCommissionOutcome.VERIFIED else StationCommissionOutcome.JOINED
        }

        override fun close() {
            client.close()
            open -= client
        }
    }
}
