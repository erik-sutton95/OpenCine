package com.opencapture.opencine.appkit

import com.opencapture.monitorui.MonitorPairingCheck
import com.opencapture.monitorui.MonitorPairingCheckState
import com.opencapture.monitorui.MonitorPairingInstruction
import com.opencapture.monitorui.MonitorPairingInstructionIcon
import com.opencapture.monitorui.MonitorPairingPresentation
import com.opencapture.monitorui.MonitorPairingStep
import com.opencapture.opencine.core.Availability
import com.opencapture.opencine.core.ConnectionPhase
import com.opencapture.opencine.core.ConnectionPrompt
import com.opencapture.opencine.core.IntegrationID
import com.opencapture.opencine.core.LocalVPNFilter
import com.opencapture.opencine.core.NearbyCamera
import com.opencapture.opencine.core.RecoveryAction
import com.opencapture.opencine.core.RouteKind
import com.opencapture.opencine.core.SavedCamera
import com.opencapture.opencine.core.UnavailableReason
import com.opencapture.opencine.core.testing.FakeIntegration
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * Swift suite `PairingWizardTests`, same method names and values, with Android main's words ("On
 * this phone", "Android asks"), no Back while idle, and the discovery blocker as the primary action.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class PairingWizardTest {
    private val wizard = PairingWizard(
        bodies = listOf("Find body", "Approve body", "Wi-Fi body", "Video body"),
        approveLines = listOf("Tap Allow"), joinLines = listOf("Leave it on"),
        choosing = MonitorPairingInstruction("Check first", MonitorPairingInstructionIcon.PHONE, listOf("Quit the other app.")),
        label = "Live label",
    )

    private fun model(
        fake: FakeIntegration,
        scope: CoroutineScope,
        saved: List<SavedCamera> = emptyList(),
        copy: ((NearbyCamera) -> NearbyCardCopy)? = null,
    ): CamerasModel {
        val store = SavedCamerasStore(Defaults(emptyMap()).at("document"))
        store.save(saved)
        return CamerasModel(listOf(AppIntegration(fake, IntegrationSlots(nearbyCard = copy))), store, scope)
    }

    @Test
    fun choosingShowsTheFourPagesThePreCheckAndTheScanLabel() = runTest {
        val fake = FakeIntegration(id = IntegrationID("test.cameras"))
        val model = model(fake, backgroundScope)
        model.beginPairing()
        runCurrent()
        assertEquals(
            MonitorPairingPresentation(
                steps = listOf(
                    MonitorPairingStep("Find your camera", "Bluetooth scan"), MonitorPairingStep("Approve on the camera", "Camera prompt"),
                    MonitorPairingStep("Join camera Wi-Fi", "Camera network"), MonitorPairingStep("Open video link", "Video link"),
                ),
                currentStep = 0, title = "Find your camera", body = "Find body", target = "Nothing selected yet",
                hint = "Choose the camera that matches your screen", progress = "Live label",
                instructions = listOf(MonitorPairingInstruction("Check first", MonitorPairingInstructionIcon.PHONE, listOf("Quit the other app."))),
                emptyTitle = "Looking for cameras", primaryAction = "Continue",
            ),
            CamerasMapping.wizard(model, wizard),
        )

        fake.publish(listOf(Values.sighting))
        runCurrent()
        assertFalse(CamerasMapping.wizard(model, wizard).primaryActionEnabled)
        model.select("n2")
        val chosen = CamerasMapping.wizard(model, wizard)
        assertTrue(chosen.target == "CAM-2" && chosen.hint == "Selected CAM-2" && chosen.primaryActionEnabled)
        assertTrue(chosen.devices.map { it.id } == listOf("n2") && chosen.devices[0].selected && chosen.emptyTitle == null)
        assertEquals(null, chosen.backAction)

        val blocked = CamerasMapping.wizard(model, wizard.copy(blocker = "Turn Bluetooth on"))
        assertTrue(blocked.primaryAction == "Turn Bluetooth on" && blocked.primaryActionEnabled && blocked.progress == null)
    }

    @Test
    fun aConnectAdvancesTheRailFromTheReportedSteps() = runTest {
        val fake = FakeIntegration(id = IntegrationID("test.cameras"))
        val model = model(fake, backgroundScope, saved = listOf(Values.camera))
        model.beginPairing()
        fake.publish(listOf(Values.sighting))
        runCurrent()
        model.select("n2")
        model.connect(model.state.value.nearby.first())
        runCurrent()
        val starting = CamerasMapping.wizard(model, wizard)
        assertTrue(starting.currentStep == 1 && starting.devices.isEmpty() && starting.progress == "Live label")
        assertTrue(starting.primaryAction == null && !starting.primaryActionEnabled && starting.backAction == "Cancel")

        fake.attempts[0].progress(ConnectionPhase.LINK, 0, note = "Looking for the camera")
        runCurrent()
        assertEquals(0, CamerasMapping.wizard(model, wizard).currentStep)

        fake.attempts[0].progress(ConnectionPhase.AWAITING_APPROVAL, 0, prompt = ConnectionPrompt.ApproveOnCamera("Approve"))
        runCurrent()
        val approve = CamerasMapping.wizard(model, wizard)
        assertTrue(approve.currentStep == 1 && approve.title == "Approve on the camera" && approve.body == "Approve body")
        assertTrue(approve.hint == "Nothing to type. Approve it on the camera" && approve.checks.isEmpty())
        assertEquals(
            listOf(
                MonitorPairingInstruction("On the camera", MonitorPairingInstructionIcon.CAMERA, listOf("Tap Allow")),
                MonitorPairingInstruction(
                    "On this phone", MonitorPairingInstructionIcon.PHONE,
                    listOf("Wait here, we keep the Bluetooth link alive", "Don't force-quit the app"),
                ),
            ),
            approve.instructions,
        )

        fake.attempts[0].progress(ConnectionPhase.JOINING_NETWORK, 1)
        runCurrent()
        val join = CamerasMapping.wizard(model, wizard.copy(joinedNetwork = "LUNA-1"))
        assertTrue(join.currentStep == 2 && join.hint == "Android asks to join the camera network")
        assertEquals(
            listOf(
                MonitorPairingInstruction("On the camera", MonitorPairingInstructionIcon.CAMERA, listOf("Leave it on")),
                MonitorPairingInstruction(
                    "On this phone", MonitorPairingInstructionIcon.PHONE,
                    listOf("Tap Join when Android asks to join the camera network", LocalVPNFilter.JOIN_WIFI_PHONE_STEP),
                ),
            ),
            join.instructions,
        )
        assertEquals(
            listOf(
                MonitorPairingCheck("Bluetooth link", "CAM-2", MonitorPairingCheckState.COMPLETE, "OK"),
                MonitorPairingCheck("Camera Wi-Fi", "LUNA-1", MonitorPairingCheckState.ACTIVE, "JOINING"),
                MonitorPairingCheck("Live picture", "Starts after Wi-Fi joins", MonitorPairingCheckState.WAITING, "WAITING"),
            ),
            join.checks,
        )

        fake.attempts[0].progress(ConnectionPhase.LINK, 2)
        runCurrent()
        val video = CamerasMapping.wizard(model, wizard)
        assertTrue(video.currentStep == 3 && video.instructions.isEmpty() && video.checks.last().stateLabel == "WAITING")
        assertEquals("Opening the video link…", video.checks.last().subtitle)
        assertEquals(
            listOf(MonitorPairingInstruction("Check the connection", MonitorPairingInstructionIcon.PHONE, listOf(LocalVPNFilter.WIZARD_BANNER))),
            CamerasMapping.wizard(model, wizard.copy(vpnActive = true)).instructions,
        )
    }

    @Test
    fun aFailureReturnsToTheFirstPageWithItsErrorAndAction() = runTest {
        val fake = FakeIntegration(id = IntegrationID("test.cameras"))
        val model = model(fake, backgroundScope)
        model.beginPairing()
        fake.publish(listOf(Values.sighting))
        runCurrent()
        model.select("n2")
        model.connect(model.state.value.nearby.first())
        runCurrent()
        fake.attempts[0].fail(Values.failure)
        runCurrent()
        val failed = CamerasMapping.wizard(model, wizard)
        assertTrue(failed.currentStep == 0 && failed.title == "Find your camera" && failed.body == "Find body")
        assertTrue(failed.error == "Turn on Bluetooth for this app." && failed.progress == null && failed.instructions.isEmpty())
        // Android main: Try again even when Settings could fix it.
        assertTrue(failed.primaryAction == "Try again" && failed.primaryActionEnabled)

        model.dismissFailure("n2")
        assertEquals(null, CamerasMapping.wizard(model, wizard).error)
        assertTrue(RecoveryAction.OpenSettings in Values.failure.actions)
    }

    @Test
    fun aFailedPairKeepsItsReasonAfterTheRescanClearsSightings() = runTest {
        val fake = FakeIntegration(id = IntegrationID("test.cameras"))
        val model = model(fake, backgroundScope)
        model.beginPairing()
        fake.publish(listOf(Values.sighting))
        runCurrent()
        model.select("n2")
        model.connect(model.state.value.nearby.first())
        runCurrent()
        fake.attempts[0].fail(Values.failure)
        runCurrent()
        fake.publish(emptyList())
        runCurrent()
        assertTrue(model.state.value.nearby.isEmpty())
        val failed = CamerasMapping.wizard(model, wizard)
        assertEquals(Values.failure.message, failed.error)
        assertEquals("Try again", failed.primaryAction)
        assertEquals("CAM-2", failed.target)
    }

    @Test
    fun theAppWordsNearbyCards() = runTest {
        val fake = FakeIntegration(id = IntegrationID("test.cameras"))
        val model = model(fake, backgroundScope, copy = { NearbyCardCopy(it.name, "Brand · nearby", "Needs approval on the camera") })
        fake.publish(
            listOf(
                Values.sighting,
                NearbyCamera(
                    "n3", name = "CAM-3", model = "Test Body", routes = setOf(RouteKind.CAMERA_ACCESS_POINT),
                    availability = Availability.Unavailable(UnavailableReason.Busy),
                ),
            ),
        )
        runCurrent()
        assertEquals(
            listOf(
                CameraItem(
                    id = "n2", name = "CAM-2", subtitle = "Brand · nearby", badge = "NEW",
                    status = "Needs approval on the camera", actionTitle = "Pair",
                ),
                CameraItem(
                    id = "n3", name = "CAM-3", subtitle = "Brand · nearby", badge = "IN USE",
                    status = "In use by another device", actionTitle = "Pair", isAvailable = false,
                ),
            ),
            CamerasMapping.nearby(model),
        )
    }
}
