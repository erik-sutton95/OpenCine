package com.opencapture.opencine.appkit

import com.opencapture.opencine.core.CameraSession
import com.opencapture.opencine.core.CommandRejection
import com.opencapture.opencine.core.ConnectionState
import com.opencapture.opencine.core.ConnectTarget
import com.opencapture.opencine.core.ConnectedCamera
import com.opencapture.opencine.core.ConnectionEvent
import com.opencapture.opencine.core.ControlAuthority
import com.opencapture.opencine.core.MonitorEntryDescriptor
import com.opencapture.opencine.core.MonitorEntryID
import com.opencapture.opencine.core.MulticamQualification
import com.opencapture.opencine.core.NearbyCamera
import com.opencapture.opencine.core.ObservationOrigin
import com.opencapture.opencine.core.ObservationPrecision
import com.opencapture.opencine.core.ObservedValue
import com.opencapture.opencine.core.PictureHealth
import com.opencapture.opencine.core.PictureSourceDescriptor
import com.opencapture.opencine.core.RouteKind
import com.opencapture.opencine.core.SavedRoute
import com.opencapture.opencine.core.SessionCloseReason
import com.opencapture.opencine.core.TelemetrySource
import com.opencapture.opencine.core.testing.FakeCameraSession
import com.opencapture.opencine.core.testing.FakeIntegration
import com.opencapture.opencine.core.testing.djiLike
import com.opencapture.opencine.multicam.AdmissionReason
import com.opencapture.opencine.multicam.ExclusionReason
import com.opencapture.opencine.multicam.MulticamGroup
import com.opencapture.opencine.multicam.MulticamSnapshot
import com.opencapture.opencine.multicam.RecordDirection
import com.opencapture.opencine.multicam.RecordPlan
import com.opencapture.opencine.multicam.RoleStatus
import com.opencapture.opencine.multicam.ResourceAdmission
import com.opencapture.opencine.multicam.ResourceBudget
import com.opencapture.opencine.multicam.ResourceRequest
import com.opencapture.opencine.multicam.TargetPolicy
import kotlinx.coroutines.flow.filterIsInstance
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlin.time.Duration.Companion.seconds

/**
 * SIMULATED. The shared Multiview stage on the shared engine: two and four cameras connect through
 * Core's [FakeIntegration], are admitted against the app's qualification budget, fill the stage's
 * four slots and record together through one confirmed plan. Every camera is a
 * [FakeCameraSession] on a manual clock. Swift twin: `MultiviewStageTests` (OpenCineAppKitTests), same names.
 */
class MultiviewStageTest {
    private val slots = 4

    @Test fun twoMemberStage() = stage(members = 2)

    @Test fun fourMemberStage() = stage(members = 4)

    private fun stage(members: Int) = runBlocking {
        // The app's qualification limit is a budget value, never an engine constant.
        val budget = ResourceBudget(qualifiedEntries = members)
        val integration = FakeIntegration()
        val cameras = mutableListOf<FakeCameraSession>()
        integration.onAttempt = { attempt ->
            val camera = FakeCameraSession.djiLike()
            cameras += camera
            attempt.connect(camera)
        }
        val studio = SavedRoute(key = "studio", kind = RouteKind.INFRASTRUCTURE_NETWORK, network = "Studio")

        val group = MulticamGroup()
        val requests = mutableListOf<ResourceRequest>()
        for (index in 0 until members) {
            val name = "Camera ${MultiviewTile.letter(index)}"
            val entry = MonitorEntryID()
            val request = ResourceRequest(entry, null, studio, picture = true)
            assertEquals(emptyList(), ResourceAdmission.reasons(request, MulticamQualification.Qualified, requests, budget))
            val connected = connect(integration, name)
            requests += request
            group.add(
                MonitorEntryDescriptor(
                    id = entry, name = name, picture = PictureSourceDescriptor(label = name),
                    cameraSession = connected.session.id, telemetry = TelemetrySource.CAMERA_SESSION,
                    controlAuthority = ControlAuthority.Owner,
                ),
            )
        }
        assertTrue(integration.attempts.size == members && cameras.size == members)
        // One more than the app qualified, or an unknown configuration, never joins.
        val extra = ResourceRequest(MonitorEntryID(), null, studio, picture = true)
        assertEquals(
            listOf(AdmissionReason.OverQualifiedLimit(members)),
            ResourceAdmission.reasons(extra, MulticamQualification.Qualified, requests, budget),
        )
        assertEquals(
            listOf(AdmissionReason.QualificationUnknown),
            ResourceAdmission.reasons(extra, MulticamQualification.Unknown, requests.dropLast(1), budget),
        )

        fun state() = MulticamSnapshot(
            cameras.map { it.current },
            group.entries.associate { it.picture!!.stream to PictureHealth.LIVE },
            now = cameras[0].now,
        )
        fun tiles(state: MulticamSnapshot): List<MultiviewTile?> {
            val summary = group.summary(state, 30.seconds)
            return (0 until slots).map { slot ->
                val entry = group.entries.getOrNull(slot) ?: return@map null
                MultiviewTile(entry, summary.entries[slot], entry.cameraSession?.let { state.cameras[it] })
            }
        }
        fun context(): MultiviewRecordContext {
            val now = state()
            val direction = if (group.summary(now, 30.seconds).camerasRecording > 0) RecordDirection.STOP else RecordDirection.START
            return MultiviewRecordContext(RecordPlan.make(direction, TargetPolicy.STRICT, group.entries.map { it.id }, group, now))
        }
        val sessions: Map<com.opencapture.opencine.core.CameraSessionID, CameraSession> = cameras.associateBy { it.id }

        // Connected, nothing reported: every value stays unavailable and nothing records.
        var stage = tiles(state())
        assertTrue(stage.size == slots && stage.filterNotNull().size == members)
        assertEquals(List(members) { "\u2014" }, stage.filterNotNull().map { it.tally })
        assertTrue(stage.filterNotNull().all { it.battery == null && it.timecode == null })
        val waiting = context()
        assertTrue(!waiting.canConfirm && waiting.plan.isRefused)
        assertEquals(
            ExclusionReason.Rejected(CommandRejection.SupportUnknown), waiting.plan.exclusions.first().reason,
        )

        cameras.forEach { it.cameraReportsStatus() }
        stage = tiles(state())
        val first = stage[0]!!
        assertTrue(first.name == "Camera A" && first.tally == "STBY" && first.battery == 76)
        assertTrue(first.timecode == "01:02:03" && first.status == null)
        // The link as reported: a closed session is not connecting, and no report is a wait.
        val link = group.summary(state(), 30.seconds).entries[0]
        val closed = RoleStatus.Reported(ConnectionState.Disconnected(SessionCloseReason.LINK_LOST))
        val lost = MultiviewTile(group.entries[0], link.copy(control = closed), null)
        assertTrue(lost.status?.text == "Disconnected" && lost.status?.inProgress == false)
        val unreported = MultiviewTile(group.entries[0], link.copy(control = RoleStatus.Unreported), null)
        assertEquals("Waiting for the camera", unreported.detail)
        // A5-01: a reading declared in fifths is the camera's gauge: bars, never a percent.
        val reported = state().cameras.getValue(group.entries[0].cameraSession!!)
        val fifths = ObservedValue(0.6, ObservationOrigin.CAMERA_REPORTED, null, precision = ObservationPrecision.Quantized(0.2))
        val gauge = MultiviewTile(group.entries[0], link, reported.copy(power = reported.power.copy(battery = fifths)))
        assertEquals(listOf(null, 3, 5), listOf(gauge.battery, gauge.batteryBars, gauge.batteryBarCount))
        assertEquals(null, first.batteryBars, "a percent reading stays a percent")
        assertEquals(listOf("ISO", "SHUTTER", "WB", "FOCUS"), first.readouts.map { it.title })
        assertEquals(listOf("800", "1/50", "5600K", "\u2014"), first.readouts.map { it.value })
        assertTrue(stage.drop(members).all { it == null }, "the other slots stay empty")

        // One confirmed group start: one explicit command per camera, nothing else.
        val start = context()
        assertTrue(start.canConfirm && !start.stopping)
        assertEquals("Record on all cameras?", start.question(single = false))
        val submission = start.plan.submit(group, state(), sessions)
        cameras.forEach { it.advance(1.seconds) }
        val result = submission.finished(sessions)
        assertEquals(members, result.confirmed)
        cameras.forEach { assertEquals(listOf("record-toggle"), it.wire) }
        stage = tiles(state())
        assertTrue(stage.filterNotNull().all { it.recording && it.tally == "REC" })
        val stop = context()
        assertTrue(stop.stopping && stop.question(single = false) == "Stop recording on all cameras?")

        // Removing a member and closing its session sends nothing: it keeps recording, and so do
        // the others. No compensation, no stop on close.
        val last = group.entries.last()
        group.remove(last.id)
        cameras[members - 1].close(SessionCloseReason.REQUESTED)
        stage = tiles(state())
        assertTrue(stage.filterNotNull().size == members - 1)
        assertNull(stage[members - 1])
        cameras.forEach {
            assertEquals(listOf("record-toggle"), it.wire)
            assertEquals(true, it.device.recording)
        }
    }

    /** The camera an attempt connects. */
    private suspend fun connect(integration: FakeIntegration, name: String): ConnectedCamera {
        val sighting = NearbyCamera(id = name, name = name, model = "Test Body", routes = setOf(RouteKind.INFRASTRUCTURE_NETWORK))
        return integration.connect(ConnectTarget.Nearby(sighting)).filterIsInstance<ConnectionEvent.Connected>().first().camera
    }
}
