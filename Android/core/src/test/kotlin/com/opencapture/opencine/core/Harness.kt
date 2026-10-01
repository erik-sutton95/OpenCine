package com.opencapture.opencine.core

import com.opencapture.opencine.core.testing.FakeCameraSession
import com.opencapture.opencine.core.testing.djiLike
import com.opencapture.opencine.core.testing.lunaLike
import com.opencapture.opencine.core.testing.nikonLike
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.runBlocking

/** Fixture families. The harness only constructs them; no scenario branches on which one it got. */
enum class Fixture(val make: () -> FakeCameraSession) {
    DJI_LIKE({ FakeCameraSession.djiLike() }),
    NIKON_LIKE({ FakeCameraSession.nikonLike() }),
    LUNA_LIKE({ FakeCameraSession.lunaLike() }),
}

/** A camera that has reported once and, where it needs one, runs its own live view. */
fun reportedCamera(fixture: Fixture): FakeCameraSession = fixture.make().apply {
    cameraReportsStatus()
    setLiveViewReady(true)
}

/**
 * A different valid value for some writable, available setting, chosen from descriptors alone:
 * what a generic control does.
 */
fun someChange(snapshot: CameraSnapshot): SettingValue? {
    for (key in SettingKey.entries) {
        val descriptor = snapshot.capabilities[key] ?: continue
        if (descriptor.access != SettingAccess.READ_WRITE || descriptor.availability != Availability.Available) continue
        val domain = descriptor.domain ?: continue
        domain.choices.firstOrNull { it != snapshot.value(key).value }?.let { return it }
    }
    return null
}

/** A command carrying the assumptions of an operator looking at the current snapshot. */
fun FakeCameraSession.command(intent: CameraCommandIntent, deadline: MonotonicInstant? = null): CameraCommand =
    CameraCommand(intent, CommandPreconditions(current, deadline))

suspend fun FakeCameraSession.submit(intent: CameraCommandIntent): CommandReceipt = submit(command(intent))

/** One scenario on one thread, as the fakes require. */
fun scenario(body: suspend CoroutineScope.() -> Unit): Unit = runBlocking { body() }

/** Runs [body] once per fixture family, naming the family in a failure. */
fun forEachFixture(body: suspend CoroutineScope.(Fixture) -> Unit): Unit = runBlocking {
    for (fixture in Fixture.entries) {
        try {
            body(fixture)
        } catch (failure: AssertionError) {
            throw AssertionError("$fixture: ${failure.message}", failure)
        }
    }
}
