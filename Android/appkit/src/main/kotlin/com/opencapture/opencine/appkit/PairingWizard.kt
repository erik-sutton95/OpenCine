package com.opencapture.opencine.appkit

import androidx.compose.runtime.Composable
import com.opencapture.monitorui.MonitorPairingCheck
import com.opencapture.monitorui.MonitorPairingCheckState
import com.opencapture.monitorui.MonitorPairingDevice
import com.opencapture.monitorui.MonitorPairingInstruction
import com.opencapture.monitorui.MonitorPairingInstructionIcon
import com.opencapture.monitorui.MonitorPairingPresentation
import com.opencapture.monitorui.MonitorPairingStep
import com.opencapture.opencine.core.ConnectTarget
import com.opencapture.opencine.core.ConnectionPhase
import com.opencapture.opencine.core.LocalVPNFilter

/**
 * The four-page pair wizard the camera apps showed before the shared pair page (Swift
 * `PairingWizard`): find, approve, join camera Wi-Fi, open the video link, with a body and cards per
 * page, a check list from the Wi-Fi page on, the connection's live label and a failure as the page's
 * error. The app gives its copy and what only it knows. On Android, [blocker] is the primary action
 * while discovery cannot run (Nearby devices, Settings or Bluetooth), and the app's callouts are the
 * flow's content.
 */
public data class PairingWizard(
    /** One body per page. */
    val bodies: List<String>,
    /** "On the camera" lines on the approve page and on the Wi-Fi page. */
    val approveLines: List<String>,
    val joinLines: List<String>,
    /** The card while choosing; null shows none. */
    val choosing: MonitorPairingInstruction? = null,
    /** The connection's live label, shown while it scans or connects. */
    val label: String? = null,
    val joinedNetwork: String? = null,
    val vpnActive: Boolean = false,
    val blocker: String? = null,
) {
    public companion object {
        internal val titles = listOf("Find your camera", "Approve on the camera", "Join camera Wi-Fi", "Open video link")
        internal val rail = listOf("Bluetooth scan", "Camera prompt", "Camera network", "Video link")

        /**
         * The apps' live label for a connection phase (Swift `ConnectionPhase.label`). Reads each
         * integration's phase enum by its constant names, which match by design.
         */
        public fun phaseLabel(phase: Enum<*>): String = when (phase.name) {
            "SCANNING" -> "Scanning for camera…"
            "CONNECTING_GATT" -> "Connecting (Bluetooth)…"
            "PAIRING" -> "Pairing…"
            "AWAITING_APPROVAL" -> "Approve on the camera screen"
            "READING_WIFI_CREDS" -> "Reading Wi-Fi credentials…"
            "JOINING_WIFI" -> "Joining camera Wi-Fi…"
            "OPENING_DATALINK" -> "Opening datalink…"
            "LIVE" -> "Connected"
            else -> "Idle"
        }

        /** A connect's scan (a first step with a live note, as both integrations report it) is still page 0. */
        internal fun page(attempt: CamerasModel.Attempt?): Int {
            attempt ?: return 0
            val progress = attempt.progress ?: return 1
            return when (progress.current) {
                0 -> if (progress.phase == ConnectionPhase.LINK && progress.note != null) 0 else 1
                1 -> 2
                else -> 3
            }
        }
    }

    /** The wizard with its actions: Continue connects the selection; [blocker] calls [onBlocker]; a failure's Try again goes back to choosing and calls [rescan]; Cancel stops the connect and calls [onDone]. */
    public fun flow(
        model: CamerasModel,
        onDone: () -> Unit,
        rescan: () -> Unit,
        onBlocker: () -> Unit = {},
        content: @Composable () -> Unit = {},
    ): IntegrationPairingFlow = IntegrationPairingFlow(
        presentation = CamerasMapping.wizard(model, this),
        onSelect = { id -> if (model.state.value.attempts.isEmpty()) model.select(id) },
        onPrimary = primary@{
            val state = model.state.value
            if (state.attempts.isNotEmpty()) return@primary
            val sighting = state.nearby.firstOrNull { it.id == state.selection }
            val failure = model.failureFor(state.selection)
            when {
                failure != null -> {
                    model.dismissFailure(failure.target.cameraID)
                    rescan()
                }
                blocker != null -> onBlocker()
                sighting != null -> model.connect(sighting)
            }
        },
        onBack = {
            model.cancelAll()
            onDone()
        },
        content = content,
    )
}

/** The selected camera's connect as the wizard shows it; any running attempt makes it busy (Swift `CamerasMapping.wizard`). */
public fun CamerasMapping.wizard(model: CamerasModel, wizard: PairingWizard): MonitorPairingPresentation {
    val state = model.state.value
    val selected = state.nearby.firstOrNull { it.id == state.selection }
    val cameraID = selected?.let { ConnectTarget.Nearby(it.camera).cameraID }
    val busy = state.attempts.isNotEmpty()
    val failed = if (busy) null else model.failureFor(state.selection)
    val failure = failed?.failure
    val page = if (failure != null) 0 else PairingWizard.page(cameraID?.let { state.attempts[it] })
    val choosing = page == 0
    val instructions = when (page) {
        0 -> listOfNotNull(wizard.choosing.takeIf { failure == null })
        1 -> listOf(
            MonitorPairingInstruction("On the camera", MonitorPairingInstructionIcon.CAMERA, wizard.approveLines),
            MonitorPairingInstruction(
                "On this phone", MonitorPairingInstructionIcon.PHONE,
                listOf("Wait here, we keep the Bluetooth link alive", "Don't force-quit the app"),
            ),
        )
        2 -> listOf(
            MonitorPairingInstruction("On the camera", MonitorPairingInstructionIcon.CAMERA, wizard.joinLines),
            MonitorPairingInstruction(
                "On this phone", MonitorPairingInstructionIcon.PHONE,
                listOf("Tap Join when Android asks to join the camera network", LocalVPNFilter.JOIN_WIFI_PHONE_STEP),
            ),
        )
        else -> if (wizard.vpnActive) {
            listOf(MonitorPairingInstruction("Check the connection", MonitorPairingInstructionIcon.PHONE, listOf(LocalVPNFilter.WIZARD_BANNER)))
        } else {
            emptyList()
        }
    }
    val failedName = when (val target = failed?.target) {
        is ConnectTarget.Nearby -> target.camera.name
        is ConnectTarget.Saved -> target.camera.displayName
        is ConnectTarget.AddRoute -> target.camera.displayName
        null -> null
    }
    val name = selected?.let { device(it, state, model).name } ?: failedName
    val checks = if (page >= 2) {
        listOf(
            MonitorPairingCheck("Bluetooth link", name ?: "Camera connected", MonitorPairingCheckState.COMPLETE, "OK"),
            MonitorPairingCheck(
                "Camera Wi-Fi", wizard.joinedNetwork ?: "Waiting for the camera network",
                if (page > 2) MonitorPairingCheckState.COMPLETE else MonitorPairingCheckState.ACTIVE,
                if (page > 2) "OK" else "JOINING",
            ),
            MonitorPairingCheck(
                "Live picture", if (page > 2) "Opening the video link…" else "Starts after Wi-Fi joins",
                if (page > 2) MonitorPairingCheckState.ACTIVE else MonitorPairingCheckState.WAITING, "WAITING",
            ),
        )
    } else {
        emptyList()
    }
    val hint = when (page) {
        0 -> name?.let { "Selected $it" } ?: "Choose the camera that matches your screen"
        1 -> "Nothing to type. Approve it on the camera"
        2 -> "Android asks to join the camera network"
        else -> "Monitoring opens when the picture is ready"
    }
    val (primary, enabled) = when {
        failure != null -> "Try again" to true
        wizard.blocker != null -> wizard.blocker to true
        choosing -> "Continue" to (selected != null && !busy)
        else -> null to false
    }
    return MonitorPairingPresentation(
        steps = PairingWizard.titles.zip(PairingWizard.rail) { title, rail -> MonitorPairingStep(title, rail) },
        currentStep = page,
        title = PairingWizard.titles[page],
        body = wizard.bodies[page],
        target = name ?: "Nothing selected yet",
        hint = hint,
        // A blocker means discovery is not running (main's scan never started).
        progress = wizard.label.takeIf { failure == null && (busy || state.scanning && wizard.blocker == null) },
        error = failure?.message,
        devices = if (choosing) {
            state.nearby.map {
                val item = device(it, state, model)
                MonitorPairingDevice(it.id, item.name, item.subtitle, selected = item.isPrimary, busy = busy, signalBars = item.signalBars)
            }
        } else {
            emptyList()
        },
        instructions = instructions,
        checks = checks,
        emptyTitle = if (choosing && state.nearby.isEmpty() && wizard.blocker == null) {
            if (state.scanning) "Looking for cameras" else "No cameras yet"
        } else {
            null
        },
        primaryAction = primary,
        primaryActionEnabled = enabled,
        backAction = if (busy) "Cancel" else null,
    )
}
