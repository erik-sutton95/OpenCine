package com.opencapture.opencine.nikon

import android.content.Context
import com.opencapture.opencine.platform.CameraApJoinPolicy
import com.opencapture.opencine.platform.CameraApJoiner
import kotlinx.coroutines.delay

/**
 * Joining a Nikon Z body's own access point over the shared [CameraApJoiner]. Android's
 * "Searching for devices" panel lists only networks already in scan results, so the join retries
 * with fresh scans while the panel is empty, then falls back once to the Nikon model prefix (a
 * misread name whose key is right still joins). The UI calls [join] once: the retries live here,
 * so the system panel never stacks.
 */
object NikonCameraAp {
    /** The shared joiner, matching a Nikon scan result by name or by its model prefix. */
    fun joiner(context: Context): CameraApJoiner =
        CameraApJoiner(context, CameraApJoinPolicy(scanMatches = NikonAccessPointSsid::scanMatches))

    /** Joins [ssid] by [attempts]; `false` once Wi-Fi is off or every attempt failed. */
    suspend fun join(joiner: CameraApJoiner, ssid: String, passphrase: String?, timeoutMillis: Int = 45_000): Boolean {
        if (ssid.isBlank()) return false
        return runAttempts(attempts(ssid.trim(), timeoutMillis), { joiner.isWifiEnabled }) { attempt ->
            joiner.join(
                attempt.ssid, passphrase, attempt.timeoutMillis,
                matchPrefix = attempt.matchPrefix, preScanMillis = attempt.preScanMillis, requireVisible = attempt.requireVisible,
            )
        }
    }

    /**
     * [join] unless the process is still on the camera network: after a first pairing's Confirm,
     * the body restarts its access point and a reassociation already rebound it, and a fresh join
     * would tear that down and scan again.
     */
    suspend fun ensureJoined(joiner: CameraApJoiner, ssid: String, passphrase: String?, timeoutMillis: Int = 45_000): Boolean =
        joiner.isProcessBound() || join(joiner, ssid, passphrase, timeoutMillis)

    /** One request to Android: the SSID or prefix, its panel budget and the scan wait before it. */
    internal data class Attempt(
        val ssid: String,
        val timeoutMillis: Int,
        val preScanMillis: Long,
        val requireVisible: Boolean = false,
        val matchPrefix: Boolean = false,
    )

    /**
     * Three exact attempts that fail fast while the panel is empty, so a fresh scan can run (the
     * first waits longest, for Samsung scan cycles, and the last gets the full budget), then the
     * model prefix when [ssid] is a Nikon Z access point.
     */
    internal fun attempts(ssid: String, timeoutMillis: Int): List<Attempt> {
        val exact = listOf(minOf(18_000, timeoutMillis), minOf(28_000, timeoutMillis), maxOf(timeoutMillis, 30_000))
            .mapIndexed { index, budget ->
                Attempt(ssid, budget, if (index == 0) FIRST_SCAN_MILLIS else RETRY_SCAN_MILLIS, requireVisible = index == 0)
            }
        val prefix = NikonAccessPointSsid.joinFallbackPrefix(ssid) ?: return exact
        return exact + Attempt(prefix, maxOf(timeoutMillis, 25_000), RETRY_SCAN_MILLIS, matchPrefix = true)
    }

    /** Runs [attempts] in order until one joins, pausing between exact attempts. */
    internal suspend fun runAttempts(
        attempts: List<Attempt>,
        isWifiEnabled: () -> Boolean,
        attempt: suspend (Attempt) -> Boolean,
    ): Boolean {
        for ((index, next) in attempts.withIndex()) {
            if (index > 0 && !next.matchPrefix) delay(ATTEMPT_GAP_MILLIS)
            if (!isWifiEnabled()) return false
            if (attempt(next)) return true
        }
        return false
    }

    private const val FIRST_SCAN_MILLIS = 12_000L
    private const val RETRY_SCAN_MILLIS = 5_000L
    private const val ATTEMPT_GAP_MILLIS = 1_200L
}
