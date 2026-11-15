package com.opencapture.opencine.nikon

import com.opencapture.opencine.core.MulticamQualification
import com.opencapture.opencine.core.MulticamQualificationRefusal
import com.opencapture.opencine.core.MultiviewCameraPolicy
import com.opencapture.opencine.core.NearbyCameraScanner
import com.opencapture.opencine.core.StationCameraRecord
import com.opencapture.opencine.core.StationSubnet
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import java.util.concurrent.atomic.AtomicLong
import kotlin.time.Duration
import kotlin.time.Duration.Companion.seconds

// Shared Multiview (Plan 6): what Multiview's Add camera lists for Nikon and the policy the shared
// coordinator follows. Z bodies join a network only from their own menus, so the list is passive
// sightings plus the app's saved router and hotspot setups; only the body the operator picks is
// opened (`NikonMultiviewLink`). Swift twins: `NikonMultiviewSightings.swift`, same names.

/**
 * A Z body Multiview's Add camera lists: a passive sighting or a saved router or hotspot setup on
 * this phone's network. It carries no serial: the body is identified only when it is picked and
 * opened. Swift twin: `NikonMultiviewCamera`.
 *
 * @property host the dotted IPv4 address the body was seen or saved at, normalized
 *   ([NikonMultiview.address]).
 * @property heldByAnotherDevice another device holds the body now: listing it would invite an Init
 *   that drops that device.
 * @property holder the holding device's name, when its presence answer gave one.
 */
public class NikonMultiviewCamera(
    host: String,
    public val name: String,
    public val heldByAnotherDevice: Boolean = false,
    public val holder: String? = null,
) {
    public val host: String = NikonMultiview.address(host) ?: host

    /** The stage's id for this camera: its normalized host, the same for every sighting of it. */
    public val id: String get() = host

    /** The coordinator's record of it (`MultiviewCoordinator`'s `describe`). */
    public val record: StationCameraRecord get() = StationCameraRecord(id = id, name = name, modelId = null)

    override fun equals(other: Any?): Boolean =
        other is NikonMultiviewCamera && other.host == host && other.name == name &&
            other.heldByAnotherDevice == heldByAnotherDevice && other.holder == holder

    override fun hashCode(): Int = listOf(host, name, heldByAnotherDevice, holder).hashCode()

    override fun toString(): String = "NikonMultiviewCamera(host=$host, name=$name, held=$heldByAnotherDevice)"
}

/**
 * A saved router or hotspot setup the Add list offers even when the passive pass did not see it (a
 * body answers liveness only while it is on). Swift twin: `NikonMultiviewSavedSetup`.
 */
public data class NikonMultiviewSavedSetup(public val host: String, public val name: String)

/** Nikon's answers to the shared Multiview. Swift twin: `NikonMultiview`. */
public object NikonMultiview {
    /**
     * Bodies are never found by probing (an Init from an idle device drops another device's
     * session): members come from sightings. A body another device holds is refused, so the Add
     * list does not offer it. Every body shows its picture.
     */
    public val policy: MultiviewCameraPolicy<NikonMultiviewCamera> =
        MultiviewCameraPolicy(
            discoversByProbe = false,
            hostKey = { hostKey(it) },
            qualification = { camera, _ ->
                if (camera.heldByAnotherDevice) {
                    MulticamQualification.Refused(MulticamQualificationRefusal.NOT_REACHABLE)
                } else {
                    MulticamQualification.Qualified
                }
            },
            hasPreview = { true },
        )

    /**
     * [host] as the normalized dotted IPv4 address the coordinator opens, or null for a USB key, an
     * access-point key or anything else that is not a network address.
     */
    public fun address(host: String): String? =
        NikonHosts.normalizedHost(host)?.takeIf(StationSubnet::validAddress)

    /**
     * The Add list: passive [sightings] (`NikonDiscovery.multiviewSightings`) and the [saved]
     * setups, one row per host, without [excludedHosts] (members and this app's own Live View). A
     * saved setup names the row of its host. USB and access-point keys are never listed.
     */
    public fun addList(
        sightings: List<NikonSighting>,
        saved: List<NikonMultiviewSavedSetup>,
        excludedHosts: Set<String> = emptySet(),
    ): List<NikonMultiviewCamera> {
        val excluded = excludedHosts.map(::hostKey).toSet()
        val names = LinkedHashMap<String, String>()
        for (setup in saved) address(setup.host)?.let { names.putIfAbsent(it, setup.name) }
        val seen = mutableSetOf<String>()
        val list = mutableListOf<NikonMultiviewCamera>()
        for (sighting in sightings) {
            val host = address(sighting.host) ?: continue
            if (host in excluded || !seen.add(host)) continue
            list +=
                NikonMultiviewCamera(
                    host = host,
                    name = names[host] ?: sighting.displayName,
                    heldByAnotherDevice = sighting.source == NikonSighting.Source.HELD_BY_ANOTHER_DEVICE,
                    holder = sighting.heldBy,
                )
        }
        for (setup in saved) {
            val host = address(setup.host) ?: continue
            if (host in excluded || !seen.add(host)) continue
            list += NikonMultiviewCamera(host = host, name = setup.name)
        }
        return list
    }

    internal fun hostKey(host: String): String = NikonHosts.normalizedHost(host) ?: host
}

/**
 * Multiview's nearby discovery for Nikon (Swift twin: `NikonMultiviewScanner`): repeated passive
 * passes (`NikonDiscovery.multiviewSightings`: no control-port dial, no PTP byte) merged with the
 * saved setups, reported as the shared [NearbyCameraScanner] reports cameras, until [stop] or
 * cancellation. Hosts in [excludedHosts] (members and this app's own Live View) are neither dialled
 * nor listed.
 *
 * @param sightings one passive pass given the saved hosts to dial for liveness and the excluded
 *   hosts, normally `NikonDiscovery.multiviewSightings` with the app's listened rows.
 * @param saved the app's saved router and hotspot setups.
 * @param excludedHosts hosts a member or this app's own Live View holds, asked before each pass.
 * @param interval the pause between passes (the presence sweep inside a pass keeps its own limit).
 */
public class NikonMultiviewScanner(
    private val sightings: suspend (savedHosts: List<String>, excludedHosts: Set<String>) -> List<NikonSighting>,
    private val saved: () -> List<NikonMultiviewSavedSetup>,
    private val excludedHosts: () -> Set<String>,
    private val interval: Duration = 3.seconds,
    private val sleep: suspend (Duration) -> Unit = { delay(it) },
) : NearbyCameraScanner<NikonMultiviewCamera> {
    private val generation = AtomicLong(0)

    /** Passive discovery needs no radio permission. */
    override suspend fun waitUntilReady(): Boolean = true

    override suspend fun scan(found: (NikonMultiviewCamera) -> Unit) {
        val pass = generation.get()
        suspend fun current() = currentCoroutineContext().isActive && generation.get() == pass
        while (current()) {
            val setups = saved()
            val excluded = excludedHosts()
            val keys = excluded.map(NikonMultiview::hostKey).toSet()
            val rows = sightings(setups.map { it.host }.filter { NikonMultiview.hostKey(it) !in keys }, excluded)
            if (!current()) return
            for (camera in NikonMultiview.addList(rows, setups, excluded)) found(camera)
            sleep(interval)
        }
    }

    override fun stop() {
        generation.incrementAndGet()
    }
}
