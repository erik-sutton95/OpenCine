package com.opencapture.opencine.multicam

import com.opencapture.opencine.core.CameraCommand
import com.opencapture.opencine.core.CameraCommandIntent
import com.opencapture.opencine.core.CameraDeviceID
import com.opencapture.opencine.core.CommandPreconditions
import com.opencapture.opencine.core.CommandRejection
import com.opencapture.opencine.core.CommandStage
import com.opencapture.opencine.core.ConnectionRouteID
import com.opencapture.opencine.core.ConnectionState
import com.opencapture.opencine.core.ControlAuthority
import com.opencapture.opencine.core.Freshness
import com.opencapture.opencine.core.ISOValue
import com.opencapture.opencine.core.IntegrationID
import com.opencapture.opencine.core.MonitorEntryDescriptor
import com.opencapture.opencine.core.MonitorEntryError
import com.opencapture.opencine.core.MonitorEntryID
import com.opencapture.opencine.core.MulticamQualification
import com.opencapture.opencine.core.MulticamQualificationRefusal
import com.opencapture.opencine.core.MonotonicInstant
import com.opencapture.opencine.core.PictureHealth
import com.opencapture.opencine.core.RecordingState
import com.opencapture.opencine.core.RouteKind
import com.opencapture.opencine.core.SavedRoute
import com.opencapture.opencine.core.SettingValue
import com.opencapture.opencine.core.testing.FakeCameraSession
import com.opencapture.opencine.core.testing.FakeEntries
import com.opencapture.opencine.core.testing.FakePictureSource
import com.opencapture.opencine.core.testing.djiLike
import com.opencapture.opencine.core.testing.nikonLike
import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNotEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlin.time.Duration.Companion.seconds

private inline fun groupError(block: () -> Unit): MulticamGroupError =
    assertFailsWith<MulticamGroupException>(block = block).error

private inline fun leaseRefusal(block: () -> Unit): EditorLeaseRefusal =
    assertFailsWith<EditorLeaseException>(block = block).refusal

/** Swift suite `GroupTests`. */
class GroupTests {
    @Test
    fun slotsSurviveReorderStagingAndSessionReplacement() = scenario {
        val dji = reported(FakeCameraSession.djiLike())
        val nikon = reported(FakeCameraSession.nikonLike())
        val a = entry("A", dji)
        val b = entry("B", nikon)
        val hdmi = FakeEntries.captureOnly(FakePictureSource("HDMI").descriptor)
        val g = group(listOf(a, b, hdmi))
        g.setStage(b.id)
        g.move(b.id, 0)
        assertEquals(listOf(b.id, a.id, hdmi.id), g.entries.map { it.id })
        assertEquals(b.id, g.stage)
        g.replaceSession(b.id, reported(FakeCameraSession.nikonLike()))
        assertEquals(b.id, g.stage)
        assertEquals(MulticamGroupError.DuplicateEntry(a.id), groupError { g.add(a) })
        assertEquals(
            MulticamGroupError.InvalidEntry(MonitorEntryError.NO_ROLE),
            groupError { g.add(MonitorEntryDescriptor(name = "empty", controlAuthority = ControlAuthority.ReadOnly)) },
        )

        // Swift round-trips the layout through JSON; Kotlin has no serializer (as in Core), so the
        // value itself is checked.
        val route = ConnectionRouteID()
        val layout = MulticamLayout(g, mapOf(a.id to route))
        assertEquals(listOf(b.id, a.id, hdmi.id), layout.slots.map { it.entry })
        assertEquals(listOf("B", "A", hdmi.name), layout.slots.map { it.name })
        assertEquals(route, layout.slots[1].route)
        assertEquals(b.id, layout.stage)
        assertEquals(1, layout.version)

        g.remove(b.id)
        assertNull(g.stage)
        assertTrue(nikon.wire.isEmpty())
    }

    @Test
    fun pictureFailureAndStaleTelemetryNeverFakeAStoppedRecording() = scenario {
        val dji = reported(FakeCameraSession.djiLike())
        val a = entry("A", dji)
        val g = group(listOf(a))
        dji.submit(CameraCommand(CameraCommandIntent.StartRecording, CommandPreconditions(dji.current)))
        dji.advance(1.seconds)

        val failed = g.summary(state(listOf(dji), pictures = mapOf(a.picture!!.stream to PictureHealth.FAILED)), 3.seconds)
        assertEquals(RoleStatus.Reported(PictureHealth.FAILED), failed.entries[0].picture)
        assertEquals(RoleStatus.Reported(ConnectionState.Ready), failed.entries[0].control)
        assertEquals(RecordingState.RECORDING, failed.entries[0].recording.value)
        assertEquals(1, failed.camerasRecording)
        assertEquals(0, failed.livePictures)

        dji.advance(5.seconds)
        val stale = g.summary(state(listOf(dji)), 3.seconds)
        assertEquals(Freshness.STALE, stale.entries[0].telemetry)
        assertEquals(1, stale.staleTelemetry)
        assertEquals(RecordingState.RECORDING, stale.entries[0].recording.value)
    }
}

/** Swift suite `EditorLeaseTests`. */
class EditorLeaseTests {
    @Test
    fun leaseRetiresWhenEpochOrSessionChanges() = scenario {
        val nikon = reported(FakeCameraSession.nikonLike())
        val a = entry("A", nikon)
        val g = group(listOf(a))
        val leases = EditorLeases()
        var live = state(listOf(nikon))
        val lease = leases.open(a.id, g, live)
        assertNull(leases.refusal(lease, g, live))
        val iso = CameraCommandIntent.Set(SettingValue.Iso(ISOValue.Manual(800)))
        val edit = leases.command(iso, lease, g, live)
        assertEquals(CommandStage.AwaitingObservation, nikon.submit(edit).stage)

        // Built before the link was replaced, flushed after.
        val queued = leases.command(CameraCommandIntent.Set(SettingValue.Iso(ISOValue.Manual(1600))), lease, g, live)
        nikon.completeAttempt(nikon.loseLink())
        live = state(listOf(nikon))
        assertEquals(EditorLeaseRefusal.RETIRED, leases.refusal(lease, g, live))
        assertEquals(EditorLeaseRefusal.RETIRED, leaseRefusal { leases.command(iso, lease, g, live) })
        assertEquals(listOf(lease), leases.retireStale(g, live))
        assertEquals(CommandStage.Rejected(CommandRejection.StaleEpoch), nikon.submit(queued).stage)

        val second = leases.open(a.id, g, live)
        val queuedForOld = leases.command(iso, second, g, live)
        val replacement = reported(FakeCameraSession.nikonLike())
        g.replaceSession(a.id, replacement)
        val now = state(listOf(nikon, replacement))
        assertEquals(EditorLeaseRefusal.RETIRED, leaseRefusal { leases.command(iso, second, g, now) })
        assertEquals(CommandStage.Rejected(CommandRejection.WrongSession), replacement.submit(queuedForOld).stage)
        assertTrue(replacement.wire.isEmpty())
    }

    @Test
    fun closingReopeningOrLosingAuthorityRetires() = scenario {
        val dji = reported(FakeCameraSession.djiLike())
        val a = entry("A", dji)
        val relay = entry("relay", dji, authority = ControlAuthority.ReadOnly)
        val g = group(listOf(a, relay))
        val live = state(listOf(dji))
        val leases = EditorLeases()
        assertEquals(EditorLeaseRefusal.NO_COMMAND_AUTHORITY, leaseRefusal { leases.open(relay.id, g, live) })
        val zoom = CameraCommandIntent.Set(SettingValue.Zoom(2.0))
        val first = leases.open(a.id, g, live)
        val second = leases.open(a.id, g, live)
        assertEquals(EditorLeaseRefusal.RETIRED, leaseRefusal { leases.command(zoom, first, g, live) })
        leases.close(a.id)
        assertEquals(EditorLeaseRefusal.RETIRED, leaseRefusal { leases.command(zoom, second, g, live) })
        val third = leases.open(a.id, g, live)
        dji.setAuthority(ControlAuthority.ReadOnly)
        val afterLapse = state(listOf(dji))
        assertEquals(listOf(third), leases.retireStale(g, afterLapse))
        assertTrue(leases.leases.isEmpty())
        assertTrue(dji.wire.isEmpty())
    }
}

/** Swift suite `ResourceAdmissionTests`. */
class ResourceAdmissionTests {
    private val budget = ResourceBudget(qualifiedEntries = 4)
    private val integration = IntegrationID("test.cameras")

    private fun device(serial: String) = CameraDeviceID.durable(serial, integration)

    private fun request(device: CameraDeviceID?, claims: List<ResourceClaim>, bits: Long = 0) =
        ResourceRequest(MonitorEntryID(), device, claims, bitsPerSecond = bits)

    private fun reasons(candidate: ResourceRequest, members: List<ResourceRequest>) =
        ResourceAdmission.reasons(candidate, members, budget)

    @Test
    fun qualificationIsRequiredAndResourceLimitsStillApply() {
        val members = (0 until 4).map { request(device("$it"), emptyList()) }
        val candidate = request(device("candidate"), emptyList())
        fun qualifiedReasons(verdict: MulticamQualification, alongside: List<ResourceRequest>) =
            ResourceAdmission.reasons(candidate, verdict, alongside, budget)
        val qualified = MulticamQualification.Qualified
        val unknown = MulticamQualification.Unknown
        val refused = MulticamQualification.Refused(MulticamQualificationRefusal.UNSUPPORTED_CONFIGURATION)
        assertEquals(emptyList(), qualifiedReasons(qualified, emptyList()))
        assertEquals(listOf(AdmissionReason.QualificationUnknown), qualifiedReasons(unknown, emptyList()))
        assertEquals(listOf(AdmissionReason.IntegrationRefused(refused.reason)), qualifiedReasons(refused, emptyList()))
        assertEquals(listOf(AdmissionReason.OverQualifiedLimit(4)), qualifiedReasons(qualified, members))
        assertEquals(
            listOf(AdmissionReason.QualificationUnknown, AdmissionReason.OverQualifiedLimit(4)),
            qualifiedReasons(unknown, members))
        assertEquals(emptyList(), qualifiedReasons(qualified, members.take(3) + candidate))
        assertEquals(
            listOf(AdmissionReason.QualificationUnknown),
            ResourceAdmission.reasons(candidate, unknown, members, ResourceBudget(qualifiedEntries = null)))
    }

    @Test
    fun conflictingClaimsAreRejectedWithReasons() {
        val apOne = request(device("1"), listOf(ResourceClaim.CameraAccessPoint("CAM-1")))
        val apTwo = request(device("2"), listOf(ResourceClaim.CameraAccessPoint("CAM-2")))
        assertEquals(listOf(AdmissionReason.WifiNetworkConflict(apOne.entry)), reasons(apTwo, listOf(apOne)))
        val sharing = request(device("2"), listOf(ResourceClaim.CameraAccessPoint("CAM-1")))
        assertEquals(listOf(AdmissionReason.AccessPointTaken(apOne.entry)), reasons(sharing, listOf(apOne)))
        // The same camera's control entry rides along on its access point.
        assertTrue(reasons(request(device("1"), listOf(ResourceClaim.CameraAccessPoint("CAM-1"))), listOf(apOne)).isEmpty())
        val lan = request(device("2"), listOf(ResourceClaim.InfrastructureNetwork("studio")))
        assertEquals(listOf(AdmissionReason.WifiNetworkConflict(apOne.entry)), reasons(lan, listOf(apOne)))

        val usb = request(device("1"), listOf(ResourceClaim.UsbInterface("usb-0")))
        assertEquals(
            listOf(AdmissionReason.UsbInterfaceTaken(usb.entry)),
            reasons(request(device("2"), listOf(ResourceClaim.UsbInterface("usb-0"))), listOf(usb)),
        )
        // USB control plus a capture-device picture use distinct resources.
        assertTrue(reasons(request(null, listOf(ResourceClaim.UsbInterface("capture-0")), bits = 50), listOf(usb)).isEmpty())

        val pairing = request(device("2"), listOf(ResourceClaim.BluetoothCommissioning))
        assertEquals(
            listOf(AdmissionReason.CommissioningInProgress(pairing.entry)),
            reasons(request(device("3"), listOf(ResourceClaim.BluetoothCommissioning)), listOf(pairing)),
        )
    }

    @Test
    fun sharedNetworkCoexistsUpToTheInjectedLimit() {
        val members = (1..4).map { request(device("$it"), listOf(ResourceClaim.InfrastructureNetwork("studio")), bits = 10) }
        for (index in members.indices) {
            assertTrue(reasons(members[index], members.subList(0, index)).isEmpty())
        }
        val fifth = request(device("5"), listOf(ResourceClaim.InfrastructureNetwork("studio")), bits = 10)
        assertEquals(listOf(AdmissionReason.OverQualifiedLimit(4)), reasons(fifth, members))
        assertEquals(
            listOf(AdmissionReason.BandwidthExceeded(needed = 50, limit = 45)),
            ResourceAdmission.reasons(fifth, members, ResourceBudget(qualifiedEntries = 6, bitsPerSecond = 45)),
        )
    }

    @Test
    fun savedRoutesClaimByTheTable() {
        fun claims(kind: RouteKind, network: String?, bluetooth: Boolean = false) =
            ResourceClaim.claims(SavedRoute(key = "k", kind = kind, network = network, bluetooth = bluetooth))
        assertEquals(listOf(ResourceClaim.CameraAccessPoint("CAM-1")), claims(RouteKind.CAMERA_ACCESS_POINT, "CAM-1"))
        assertEquals(listOf(ResourceClaim.InfrastructureNetwork("studio")), claims(RouteKind.INFRASTRUCTURE_NETWORK, "studio"))
        assertEquals(listOf(ResourceClaim.InfrastructureNetwork("hotspot:phone")), claims(RouteKind.PHONE_HOTSPOT, "phone"))
        assertEquals(listOf(ResourceClaim.UsbInterface("usb-0")), claims(RouteKind.USB, "usb-0"))
        assertEquals(listOf(ResourceClaim.UsbInterface("capture-0")), claims(RouteKind.CAPTURE_DEVICE, "capture-0"))
        assertEquals(
            listOf(ResourceClaim.CameraAccessPoint("CAM-1"), ResourceClaim.BluetoothCommissioning),
            claims(RouteKind.CAMERA_ACCESS_POINT, "CAM-1", bluetooth = true),
        )
        // Unknown networks never match each other.
        assertNotEquals(claims(RouteKind.INFRASTRUCTURE_NETWORK, null), claims(RouteKind.INFRASTRUCTURE_NETWORK, null))

        // A hotspot conflicts with the router network a member uses.
        val router = ResourceRequest(
            MonitorEntryID(), device("1"),
            SavedRoute(key = "wifi", kind = RouteKind.INFRASTRUCTURE_NETWORK, network = "studio"), picture = true,
        )
        val hotspot = ResourceRequest(
            MonitorEntryID(), device("2"),
            SavedRoute(key = "hotspot", kind = RouteKind.PHONE_HOTSPOT, network = "studio"), picture = true,
            bitsPerSecond = 10,
        )
        assertTrue(router.decoders == 1 && hotspot.bitsPerSecond == 10L)
        assertEquals(listOf(AdmissionReason.WifiNetworkConflict(router.entry)), reasons(hotspot, listOf(router)))
    }
}

/** Swift suite `RecoveryTests`. */
class RecoveryTests {
    @Test
    fun failingEntryExhaustsOnlyItsOwnBudget() = scenario {
        val healthyCamera = reported(FakeCameraSession.djiLike())
        val failing = MonitorEntryID()
        val healthy = MonitorEntryID()
        val ledger = RecoveryLedger(limit = 2, resetAfterHealthy = 30.seconds)
        val attempts = (1..3).map { ledger[failing].beginAttempt() }
        assertEquals(listOf(true, true, false), attempts)
        assertEquals(RecoveryBudget.Status.Exhausted, ledger[failing].status)
        assertEquals(listOf(failing), ledger.exhausted)
        assertEquals(RecoveryBudget.Status.Healthy, ledger[healthy].status)
        assertTrue(ledger[healthy].beginAttempt())
        // The engine never touches a peer's session.
        assertEquals(ConnectionState.Ready, healthyCamera.current.connection)
        assertTrue(healthyCamera.wire.isEmpty())
        ledger[failing].reset()
        assertEquals(RecoveryBudget.Status.Healthy, ledger[failing].status)

        val g = MulticamGroup()
        g.add(entry("H", healthyCamera))
        ledger.prune(g)
        assertTrue(ledger.budgets.isEmpty())
    }

    @Test
    fun sustainedHealthRestoresTheBudget() {
        val budget = RecoveryBudget(limit = 2, resetAfterHealthy = 30.seconds)
        budget.beginAttempt()
        budget.beginAttempt()
        assertEquals(RecoveryBudget.Status.Recovering(attempt = 2, of = 2), budget.status)
        budget.observe(healthy = true, now = MonotonicInstant(10.seconds))
        budget.observe(healthy = false, now = MonotonicInstant(20.seconds))
        budget.observe(healthy = true, now = MonotonicInstant(21.seconds))
        budget.observe(healthy = true, now = MonotonicInstant(50.seconds))
        assertEquals(2, budget.used)
        budget.observe(healthy = true, now = MonotonicInstant(51.seconds))
        assertEquals(0, budget.used)
        assertEquals(RecoveryBudget.Status.Healthy, budget.status)
    }
}

/** Swift suite `ImportRuleTests`. */
class ImportRuleTests {
    @Test
    fun engineImportsOnlyStdlibCoroutinesAndCoreAndNamesNoVendorOrUI() {
        val files = File("src/main/kotlin").walk().filter { it.extension == "kt" }.toList()
        assertTrue(files.isNotEmpty())
        val forbidden = Regex(
            """\b(swiftui|uikit|appkit|compose|androidx|dji|osmo|nikon|zcine|insta360|insta|luna|pocket|sony|canon|blackmagic|gopro|datalink|ptp|udp)\b""",
            RegexOption.IGNORE_CASE,
        )
        assertNotNull(forbidden.find("import androidx.compose.runtime.State"))
        // As in Core, java.util.UUID is the one JDK type: Core's IDs already wrap it.
        val allowed = listOf("import kotlin.", "import kotlinx.coroutines.", "import com.opencapture.opencine.core.", "import java.util.UUID")
        for (file in files) {
            val text = file.readText()
            for (line in text.lines().filter { it.startsWith("import ") }) {
                assertTrue(allowed.any { line.startsWith(it) }, "${file.name}: $line")
            }
            assertNull(forbidden.find(text), "${file.name} names a vendor, UI framework or transport")
        }
        // OpenCineCore (:core) is the only dependency besides coroutines; the build includes no other build.
        val dependencies = Regex("""^\s*(api|implementation|compileOnly|runtimeOnly)\((.+)\)\s*$""", RegexOption.MULTILINE)
            .findAll(File("build.gradle.kts").readText()).map { it.groupValues[2] }.toList()
        assertEquals(listOf("project(\":core\")", "libs.kotlinx.coroutines.core"), dependencies)
        val settings = File("../settings.gradle.kts").readText()
        assertEquals(0, Regex("""includeBuild\(""").findAll(settings).count())
    }
}
