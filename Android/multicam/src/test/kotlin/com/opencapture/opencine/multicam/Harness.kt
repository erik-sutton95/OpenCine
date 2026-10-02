package com.opencapture.opencine.multicam

import com.opencapture.opencine.core.CameraSession
import com.opencapture.opencine.core.CameraSessionID
import com.opencapture.opencine.core.ControlAuthority
import com.opencapture.opencine.core.MonitorEntryDescriptor
import com.opencapture.opencine.core.MonitorEntryID
import com.opencapture.opencine.core.MonotonicInstant
import com.opencapture.opencine.core.PictureHealth
import com.opencapture.opencine.core.StreamID
import com.opencapture.opencine.core.TelemetrySource
import com.opencapture.opencine.core.testing.FakeCameraSession
import com.opencapture.opencine.core.testing.FakePictureSource
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.runBlocking
import kotlin.time.Duration

/** A camera that has reported once and, where it needs one, runs its own live view. */
fun reported(camera: FakeCameraSession): FakeCameraSession = camera.apply {
    cameraReportsStatus()
    setLiveViewReady(true)
}

/** The engine's input, gathered from the fakes the way an app gathers it from its sessions. */
fun state(
    cameras: List<FakeCameraSession>,
    pictures: Map<StreamID, PictureHealth> = emptyMap(),
    busy: Set<MonitorEntryID> = emptySet(),
): MulticamSnapshot = MulticamSnapshot(
    cameras.map { it.current }, pictures, busy, cameras.map { it.now }.fold(MonotonicInstant.ZERO, ::maxOf),
)

fun sessions(cameras: List<FakeCameraSession>): Map<CameraSessionID, CameraSession> = cameras.associateBy { it.id }

/** Moves every fake clock together. */
fun advance(cameras: List<FakeCameraSession>, by: Duration) {
    for (camera in cameras) camera.advance(by)
}

/** An entry with picture, camera session and session telemetry. */
fun entry(
    name: String,
    camera: FakeCameraSession,
    picture: Boolean = true,
    authority: ControlAuthority = ControlAuthority.Owner,
): MonitorEntryDescriptor = MonitorEntryDescriptor(
    name = name,
    picture = if (picture) FakePictureSource(name).descriptor else null,
    cameraSession = camera.id,
    telemetry = TelemetrySource.CAMERA_SESSION,
    controlAuthority = authority,
)

fun group(entries: List<MonitorEntryDescriptor>): MulticamGroup = MulticamGroup().apply { entries.forEach { add(it) } }

/** The entry with its camera session replaced, keeping its slot. */
fun MulticamGroup.replaceSession(id: MonitorEntryID, camera: FakeCameraSession) {
    update(get(id)!!.copy(cameraSession = camera.id))
}

/** One scenario on one thread, as the fakes require. */
fun scenario(body: suspend CoroutineScope.() -> Unit): Unit = runBlocking { body() }
