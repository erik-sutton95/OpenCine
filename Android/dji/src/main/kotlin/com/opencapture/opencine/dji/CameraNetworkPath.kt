package com.opencapture.opencine.dji

import android.content.Context
import com.opencapture.opencine.platform.CameraApJoinPolicy
import com.opencapture.opencine.platform.CameraApJoiner
import java.net.DatagramSocket
import java.net.Socket

/**
 * The network one datalink runs on: the camera SoftAP (the shared [CameraApJoiner]) or the
 * Multiview shared Wi-Fi. iOS `DatalinkDriver.pathReady` / `cameraParameters`.
 */
interface CameraNetworkPath {
    fun bindSocket(socket: DatagramSocket)
    fun bindSocket(socket: Socket)
    fun isProcessBound(): Boolean
    fun cameraLocalIPv4(): String?
}

/** The Pocket SoftAP address rules (iOS `CameraSoftAP`). */
object DjiCameraAp {
    /**
     * Phone address on the camera AP. `.1` is the camera; `.0` / `.255` are not hosts. Matches
     * `CameraSoftAP.isAssociatedIPv4` exactly.
     */
    fun isAssociatedIPv4(ip: String): Boolean {
        val parts = ip.split('.')
        if (parts.size != 4) return false
        if (parts[0] != "192" || parts[1] != "168" || parts[2] != "2") return false
        val host = parts[3].toIntOrNull() ?: return false
        return host in 2..254
    }

    fun cameraLocalIPv4(ipv4s: Iterable<String>): String? = ipv4s.firstOrNull(::isAssociatedIPv4)

    /** The shared camera-AP join with the Pocket address rule and session diagnostics. */
    fun joiner(context: Context): CameraApJoiner =
        CameraApJoiner(
            context,
            CameraApJoinPolicy(
                isCameraClientAddress = ::isAssociatedIPv4,
                log = { level, code, message -> DjiLog.log(level, "session", code, message) },
            ),
        )
}

/** The camera SoftAP as a datalink path. */
fun CameraApJoiner.asNetworkPath(): CameraNetworkPath {
    val joiner = this
    return object : CameraNetworkPath {
        override fun bindSocket(socket: DatagramSocket) = joiner.bindSocket(socket)
        override fun bindSocket(socket: Socket) = joiner.bindSocket(socket)
        override fun isProcessBound(): Boolean = joiner.isProcessBound()
        override fun cameraLocalIPv4(): String? = joiner.cameraLocalIPv4()
    }
}
