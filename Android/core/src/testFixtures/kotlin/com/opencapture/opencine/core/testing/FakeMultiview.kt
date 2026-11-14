package com.opencapture.opencine.core.testing

import com.opencapture.opencine.core.CameraSession
import com.opencapture.opencine.core.MultiviewAutoLUT
import com.opencapture.opencine.core.MultiviewLinkStatus
import com.opencapture.opencine.core.MultiviewMemberLink
import com.opencapture.opencine.core.MultiviewRecordReport
import com.opencapture.opencine.core.MultiviewRepairContext
import com.opencapture.opencine.core.MultiviewRepairStep
import com.opencapture.opencine.core.NearbyCameraScanner
import com.opencapture.opencine.core.PictureHealth
import com.opencapture.opencine.core.StationCameraRecord
import com.opencapture.opencine.core.StationCommission
import com.opencapture.opencine.core.StationCommissionOutcome
import com.opencapture.opencine.core.StationCommissioner
import com.opencapture.opencine.core.StationHostPath
import com.opencapture.opencine.core.StationNetwork
import com.opencapture.opencine.core.StationRestoreResult
import com.opencapture.opencine.core.StationVerifyFinal
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import java.util.UUID
import kotlin.time.Duration
import kotlin.time.Duration.Companion.seconds

/**
 * A nearby camera as a fake integration's discovery reports it: its Bluetooth id, its name and, for
 * an integration that finds members from its own sightings, the address it was seen at. Swift twin:
 * `FakeStationCamera`.
 */
public data class FakeStationCamera(
    public val name: String,
    public val id: String = UUID.randomUUID().toString(),
    public val modelId: Int? = null,
    public val sightedAt: String? = null,
) {
    /** What a commissioner journals for it. */
    public val record: StationCameraRecord get() = StationCameraRecord(id, name, modelId)

    /** The identity bytes this camera proves over its setup link and on the network. */
    public val identity: ByteArray get() = name.toByteArray()
}

/** A one-shot signal a fake waits on until the test opens it. */
public class FakeGate {
    private val opened = CompletableDeferred<Unit>()
    public var waiting: Int = 0
        private set
    public val isOpen: Boolean get() = opened.isCompleted

    public suspend fun await() {
        waiting += 1
        try {
            opened.await()
        } finally {
            waiting -= 1
        }
    }

    public fun open() {
        opened.complete(Unit)
    }
}

/** The phone's side of a fake shared network. Swift twin: `FakeStationHostPath`. */
public class FakeStationHostPath(
    address: String? = "192.168.1.10",
    netmask: String? = "255.255.255.248",
    hotspotAddress: String? = null,
    hotspotNetmask: String? = null,
) : StationHostPath {
    /** This phone's address per network kind (`false` Wi-Fi, `true` its hotspot). */
    public val addresses: MutableMap<Boolean, String?> = mutableMapOf(false to address, true to hotspotAddress)
    public val netmasks: MutableMap<Boolean, String?> = mutableMapOf(false to netmask, true to hotspotNetmask)

    /** Thrown by [join] when set. */
    public var joinError: Exception? = null

    /** Every network [join] was asked for. */
    public val joins: MutableList<StationNetwork> = mutableListOf()

    override fun address(hotspot: Boolean): String? = addresses[hotspot]

    override fun netmask(hotspot: Boolean): String? = netmasks[hotspot]

    override suspend fun join(network: StationNetwork): String? {
        joins += network
        joinError?.let { throw it }
        return addresses[network.hotspot]
    }
}

/** Why a fake commission or link failed. */
public class FakeMultiviewFailure(message: String) : Exception(message)

/** A fake integration's camera setup over Bluetooth. Swift twin: `FakeStationCommissioner`. */
public class FakeStationCommissioner : StationCommissioner<FakeStationCamera> {
    /** Thrown by [connect] when set. */
    public var connectError: Exception? = null

    /** [connect] waits here before it answers, when set. */
    public var connectGate: FakeGate? = null

    /** Lines the join reports through `progress`, in order. */
    public var joinProgress: List<String> = listOf("Joining shared Wi-Fi")

    /** Thrown by the join when set. */
    public var joinError: Exception? = null

    /** The join finds the camera through `verifyOnNetwork` and reports VERIFIED. */
    public var verifiesOnJoin: Boolean = false

    /**
     * The verified join waits here before it reports, when set (the camera's preview already
     * started while its join still runs).
     */
    public var afterVerifyGate: FakeGate? = null

    /**
     * The camera's join reply is lost, as a real commissioner sees it: the join looks for the
     * camera on the network, treats what that throws as "not there yet" unless it is a
     * [StationVerifyFinal], and then fails as a silent join.
     */
    public var lostJoinReply: Boolean = false

    /** Thrown by [restoreAccessPoint] when set (Kotlin only: a Swift return cannot throw). */
    public var restoreError: Exception? = null

    /** Each camera's return results, in order; RESTORED once they run out. */
    public val restoreResults: MutableMap<String, MutableList<StationRestoreResult>> = mutableMapOf()

    /** Every return waits here when set. */
    public var restoreGate: FakeGate? = null
    override var scansNetworks: Boolean = false

    /** Networks a scan reports. */
    public var scanFound: List<String> = emptyList()

    public val connects: MutableList<String> = mutableListOf()
    public val joins: MutableList<Triple<String, StationNetwork, Boolean>> = mutableListOf()
    public val restores: MutableList<String> = mutableListOf()
    public var commissionsClosed: Int = 0
        private set

    /** Commission links closed by the caller. */
    public var linksClosed: Int = 0
        private set
    public val scans: MutableList<String> = mutableListOf()

    override fun record(camera: FakeStationCamera): StationCameraRecord = camera.record

    public companion object {
        /** How a join whose reply was lost fails. */
        public const val SILENT_JOIN: String = "The camera did not answer the Wi-Fi join."
    }

    override suspend fun connect(camera: FakeStationCamera, progress: (String) -> Unit): StationCommission {
        connects += camera.id
        progress("Bluetooth pairing")
        connectGate?.await()
        currentCoroutineContext().ensureActive()
        connectError?.let { throw it }
        return Commission(camera)
    }

    override fun closeCommissions() {
        commissionsClosed += 1
    }

    override suspend fun restoreAccessPoint(record: StationCameraRecord): StationRestoreResult {
        restores += record.id
        restoreGate?.await()
        restoreError?.let { throw it }
        val queue = restoreResults[record.id]
        return if (queue.isNullOrEmpty()) StationRestoreResult.Restored else queue.removeAt(0)
    }

    override suspend fun scanNetworks(
        camera: FakeStationCamera,
        beforeStationChange: () -> Unit,
        onRestored: (Boolean) -> Unit,
        onFound: (String) -> Unit,
    ) {
        scans += camera.id
        beforeStationChange()
        for (network in scanFound) onFound(network)
        onRestored(restoreAccessPoint(camera.record) == StationRestoreResult.Restored)
    }

    private inner class Commission(private val camera: FakeStationCamera) : StationCommission {
        override suspend fun identity(): ByteArray = camera.identity

        override suspend fun join(
            network: StationNetwork,
            identity: ByteArray,
            experimental: Boolean,
            progress: (String) -> Unit,
            verifyOnNetwork: suspend () -> Boolean,
        ): StationCommissionOutcome {
            joins += Triple(camera.id, network, experimental)
            for (line in joinProgress) progress(line)
            joinError?.let { throw it }
            if (lostJoinReply) {
                try {
                    if (verifyOnNetwork()) return StationCommissionOutcome.VERIFIED
                } catch (e: CancellationException) {
                    throw e
                } catch (e: StationVerifyFinal) {
                    throw e
                } catch (_: Exception) {
                    // Not there yet: the join goes on and fails silent.
                }
                throw FakeMultiviewFailure(SILENT_JOIN)
            }
            if (verifiesOnJoin && verifyOnNetwork()) {
                afterVerifyGate?.await()
                return StationCommissionOutcome.VERIFIED
            }
            return StationCommissionOutcome.JOINED
        }

        override fun close() {
            linksClosed += 1
        }
    }
}

/** A fake member link: cameras answer at the addresses the test places them. Swift twin: `FakeMemberLink`. */
public class FakeMemberLink(public val fakeSession: FakeCameraSession = FakeCameraSession.djiLike()) :
    MultiviewMemberLink<FakeStationCamera> {
    override val session: CameraSession get() = fakeSession
    override var pictureHealth: PictureHealth = PictureHealth.LIVE
    override var onStatus: ((MultiviewLinkStatus) -> Unit)? = null
    override var repairDeadline: Duration = 60.seconds
    override var recordReport: MultiviewRecordReport? = null
    override var autoLUT: MultiviewAutoLUT = MultiviewAutoLUT(null, null)

    /** The identity of the camera answering at each address. */
    public val answering: MutableMap<String, ByteArray> = mutableMapOf()

    /** Thrown by [startPreview] when set. */
    public var startError: Exception? = null

    /** [open] waits here when set. */
    public var openGate: FakeGate? = null

    /** Thrown by [keepalive] when set (Kotlin only: Swift's cannot throw). */
    public var keepaliveError: Exception? = null

    /** Thrown by [probe] at these addresses (Kotlin only: Swift's cannot throw). */
    public val probeErrors: MutableMap<String, Exception> = mutableMapOf()

    /** The next repair tick's verdict. */
    public var repairStep: (MultiviewRepairContext) -> MultiviewRepairStep = { MultiviewRepairStep.Healthy }

    public val probes: MutableList<String> = mutableListOf()
    public val opens: MutableList<Pair<String, ByteArray?>> = mutableListOf()
    public var starts: Int = 0
        private set
    public var closes: Int = 0
        private set
    public var keepalives: Int = 0
        private set
    public var repairTicks: Int = 0
        private set
    public var openAddress: String? = null
        private set

    /** Places [camera] at [address] on the network. */
    public fun place(camera: FakeStationCamera, address: String) {
        answering[address] = camera.identity
    }

    override suspend fun probe(address: String, network: StationNetwork): Boolean {
        probes += address
        probeErrors[address]?.let { throw it }
        return answering[address] != null
    }

    override suspend fun open(camera: FakeStationCamera, address: String, expecting: ByteArray?, network: StationNetwork): ByteArray {
        opens += address to expecting
        openAddress = null
        onStatus?.invoke(MultiviewLinkStatus.OPENING)
        openGate?.await()
        currentCoroutineContext().ensureActive()
        val answer = answering[address] ?: throw FakeMultiviewFailure("Nothing answered at $address")
        if (expecting != null && !expecting.contentEquals(answer)) {
            throw FakeMultiviewFailure("This network connection did not identify the selected camera.")
        }
        openAddress = address
        return answer
    }

    override suspend fun startPreview(camera: FakeStationCamera) {
        startError?.let { throw it }
        starts += 1
        onStatus?.invoke(MultiviewLinkStatus.CONTROLLING)
        onStatus?.invoke(MultiviewLinkStatus.AWAITING_PICTURE)
    }

    override suspend fun keepalive() {
        keepalives += 1
        keepaliveError?.let { throw it }
    }

    override fun close() {
        closes += 1
        openAddress = null
    }

    override fun repair(context: MultiviewRepairContext): MultiviewRepairStep {
        repairTicks += 1
        return repairStep(context)
    }
}

/** Fake Bluetooth discovery of nearby cameras. Swift twin: `FakeNearbyScanner`. */
public class FakeNearbyScanner : NearbyCameraScanner<FakeStationCamera> {
    public var ready: Boolean = true
    public var scanning: Boolean = false
        private set
    public var starts: Int = 0
        private set
    public var stops: Int = 0
        private set
    private var report: ((FakeStationCamera) -> Unit)? = null
    private var ending: CompletableDeferred<Unit>? = null

    override suspend fun waitUntilReady(): Boolean = ready

    override suspend fun scan(found: (FakeStationCamera) -> Unit) {
        starts += 1
        scanning = true
        report = found
        val end = CompletableDeferred<Unit>()
        ending = end
        try {
            end.await()
        } finally {
            scanning = false
            report = null
            if (ending === end) ending = null
        }
    }

    override fun stop() {
        stops += 1
        ending?.complete(Unit)
    }

    /** A camera seen while scanning. */
    public fun see(camera: FakeStationCamera) {
        report?.invoke(camera)
    }
}
