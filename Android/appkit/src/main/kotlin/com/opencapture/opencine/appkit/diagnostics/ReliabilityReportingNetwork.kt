package com.opencapture.opencine.appkit.diagnostics

import com.opencapture.opencine.media.DiagnosticWire
import java.util.concurrent.CopyOnWriteArrayList

public interface ReliabilityReportingCancellable {
    public fun cancel()

    /** Manual operator reports keep transmitting after automatic-SDK opt-out. */
    public val independentOfAutomaticConsent: Boolean
        get() = false
}

/**
 * One connection owner's hold on the camera path, from its connect attempt (recovery included)
 * until it retires. Closing it again does nothing.
 */
public class ReliabilityCameraPathLease internal constructor(release: () -> Unit) : AutoCloseable {
    private val release = java.util.concurrent.atomic.AtomicReference<(() -> Unit)?>(release)

    public val isEnded: Boolean
        get() = release.get() == null

    public fun end() {
        release.getAndSet(null)?.invoke()
    }

    override fun close(): Unit = end()
}

/**
 * Upload gate: no report leaves while a camera path is held or the camera's IPv4 path is up.
 * [cameraIPv4Prefix] is the camera network's address prefix; [extraCameraPathProbe] lets the
 * host report a process bound to the camera network.
 */
public class ReliabilityReportingGate(
    private val consent: ReliabilityReportingConsent,
    public val hostPolicy: ReliabilityReportingHostPolicy,
    public val cameraIPv4Prefix: String,
) {
    private val lock = Any()
    private val cameraPathHolders = HashSet<Any>()
    @Volatile private var ipv4Override: Boolean? = null
    @Volatile private var validInternet = true
    @Volatile public var extraCameraPathProbe: (() -> Boolean)? = null
    private val pending = CopyOnWriteArrayList<ReliabilityReportingCancellable>()

    /** A connection owner holds the camera path ([beginCameraPath]). */
    public val isCameraSessionActive: Boolean
        get() = synchronized(lock) { cameraPathHolders.isNotEmpty() }

    /** Blocks SDK upload while a camera path is held or the camera IPv4 path is up. */
    public val shouldBlockUpload: Boolean
        get() {
            val session = synchronized(lock) { cameraPathHolders.isNotEmpty() }
            val ipv4 = ipv4Override ?: cameraIPv4PathReady()
            return session || ipv4
        }

    public val hasValidInternet: Boolean
        get() = synchronized(lock) { validInternet }

    /** The SDK transport gate: consent, no camera path, and internet. */
    public val isConnected: Boolean
        get() = consent.isOptedIn && !shouldBlockUpload && hasValidInternet

    /**
     * Holds the camera path until the lease ends and cancels uploads in flight. Every connection
     * owner takes its own lease at its connect attempt and ends it when it retires, so a stale
     * owner ending late never reopens a successor's hold. [onClear] runs when the last lease ends.
     */
    public fun beginCameraPath(onClear: () -> Unit = {}): ReliabilityCameraPathLease {
        val holder = Any()
        val toCancel = synchronized(lock) {
            cameraPathHolders.add(holder)
            val copy = pending.toList()
            pending.clear()
            copy
        }
        for (task in toCancel) task.cancel()
        return ReliabilityCameraPathLease {
            val cleared = synchronized(lock) { cameraPathHolders.remove(holder) && cameraPathHolders.isEmpty() }
            if (cleared) onClear()
        }
    }

    public fun setCameraIPv4PathReadyForTests(ready: Boolean?) {
        synchronized(lock) { ipv4Override = ready }
        if (ready == true) cancelPending()
    }

    public fun setValidInternetForTests(ready: Boolean) {
        synchronized(lock) { validInternet = ready }
    }

    public fun register(task: ReliabilityReportingCancellable) {
        val blockNow = synchronized(lock) {
            pending.add(task)
            val cameraBlock = cameraPathHolders.isNotEmpty() || cameraIPv4PathReady()
            val consentBlock =
                !task.independentOfAutomaticConsent && !consent.isOptedIn
            cameraBlock || consentBlock
        }
        if (blockNow) task.cancel()
    }

    public fun unregister(task: ReliabilityReportingCancellable) {
        pending.remove(task)
    }

    public fun cancelPending(includeIndependent: Boolean = true) {
        val toCancel = synchronized(lock) {
            val copy = pending.filter { includeIndependent || !it.independentOfAutomaticConsent }
            pending.removeAll(copy.toSet())
            copy
        }
        for (task in toCancel) task.cancel()
    }

    public fun resetForTests() {
        hostPolicy.requireHttps = true
        val toCancel = synchronized(lock) {
            cameraPathHolders.clear()
            ipv4Override = false
            validInternet = true
            extraCameraPathProbe = null
            val copy = pending.toList()
            pending.clear()
            copy
        }
        for (task in toCancel) task.cancel()
    }

    public fun cameraIPv4PathReady(): Boolean {
        ipv4Override?.let { return it }
        if (extraCameraPathProbe?.invoke() == true) return true
        return hasAssociatedCameraIPv4()
    }

    public fun hasAssociatedCameraIPv4(): Boolean {
        return DiagnosticWire.localIPv4Addresses().any { it.startsWith(cameraIPv4Prefix) }
    }
}

/** Uploads go only to the DSN host, over https unless a test relaxes it. */
public class ReliabilityReportingHostPolicy {
    @Volatile public var requireHttps: Boolean = true

    public fun allows(url: String?, dsnHost: String?): Boolean {
        val address = url?.let { DiagnosticWire.url(it) } ?: return false
        val host = address.host
        if (host.isNullOrEmpty()) return false
        val scheme = address.scheme.orEmpty().lowercase()
        if (requireHttps && scheme != "https") return false
        if (!requireHttps && scheme != "https" && scheme != "http") return false
        if (dsnHost != null && host.equals(dsnHost, ignoreCase = true)) return true
        return false
    }

    public companion object {
        public fun host(fromDSN: String): String? = DiagnosticWire.uri(fromDSN)?.host
    }
}

public enum class ReliabilityReportingLoadDecision {
    FORWARD,
    BLOCK_CAMERA_PATH,
    REJECT_HOST,
    NO_INTERNET,
}

public object ReliabilityReportingNetwork {
    public fun decision(
        url: String?,
        dsnHost: String?,
        gate: ReliabilityReportingGate,
    ): ReliabilityReportingLoadDecision {
        if (url?.let { DiagnosticWire.url(it) } == null) return ReliabilityReportingLoadDecision.REJECT_HOST
        if (gate.shouldBlockUpload) return ReliabilityReportingLoadDecision.BLOCK_CAMERA_PATH
        if (!gate.hostPolicy.allows(url, dsnHost)) {
            return ReliabilityReportingLoadDecision.REJECT_HOST
        }
        if (!gate.hasValidInternet) return ReliabilityReportingLoadDecision.NO_INTERNET
        return ReliabilityReportingLoadDecision.FORWARD
    }
}

public object ReliabilityReportingBackoff {
    public fun delaySeconds(attempt: Int, jitter: Double): Double {
        val exponent = minOf(6, maxOf(0, attempt)).toDouble()
        val base = minOf(30.0, Math.pow(2.0, exponent) * 0.5)
        val spread = minOf(1.0, maxOf(0.0, jitter))
        return minOf(30.0, maxOf(0.25, base * (0.7 + 0.6 * spread)))
    }
}
