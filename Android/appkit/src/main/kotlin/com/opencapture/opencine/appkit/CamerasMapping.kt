package com.opencapture.opencine.appkit

import com.opencapture.monitorui.MonitorConnectFailure
import com.opencapture.monitorui.MonitorConnectStep
import com.opencapture.monitorui.MonitorPairingDevice
import com.opencapture.monitorui.MonitorPairingInstruction
import com.opencapture.monitorui.MonitorPairingInstructionIcon
import com.opencapture.monitorui.MonitorPairingPresentation
import com.opencapture.monitorui.MonitorPairingStep
import com.opencapture.monitorui.MonitorSetupChip
import com.opencapture.opencine.core.Availability
import com.opencapture.opencine.core.ConnectTarget
import com.opencapture.opencine.core.ConnectionFailure
import com.opencapture.opencine.core.ConnectionPrompt
import com.opencapture.opencine.core.ConnectionRouteID
import com.opencapture.opencine.core.RecoveryAction
import com.opencapture.opencine.core.RouteKind
import com.opencapture.opencine.core.SavedCamera
import com.opencapture.opencine.core.SavedRoute

/** One card of the cameras page (Swift `CameraListItem`). */
public data class CameraItem(
    public val id: String,
    public val name: String,
    public val subtitle: String,
    public val badge: String = "",
    public val status: String,
    public val actionTitle: String,
    public val isPrimary: Boolean = false,
    public val isBusy: Boolean = false,
    public val isAvailable: Boolean = true,
    public val signalBars: Int? = null,
    public val setups: List<MonitorSetupChip> = emptyList(),
    public val canAddSetup: Boolean = false,
    public val steps: List<MonitorConnectStep> = emptyList(),
    public val failure: MonitorConnectFailure? = null,
)

/** The route id as both platforms print it (Swift `UUID.uuidString`). */
public val ConnectionRouteID.text: String get() = uuid.toString().uppercase()

/**
 * The model as the shared camera pages show it (Swift `CamerasMapping`, same values). Integration
 * copy (steps, prompts, failures) is rendered as given; the shell's own copy is the pages' frame.
 */
public object CamerasMapping {
    /** Reopens a failed saved route only when it still exists and the chooser advertises it. */
    public fun addSetupSelection(model: CamerasModel, camera: SavedCamera, chooser: AddSetupChooser): String? {
        val target = model.state.value.failures[camera.id]?.target as? ConnectTarget.Saved ?: return null
        val kind = camera.routes.firstOrNull { it.id == target.route }?.kind ?: return null
        return chooser.options.firstOrNull { it.kind == kind && it.enabled }?.id
    }

    /** Saved cameras, most recently connected first. */
    public fun paired(model: CamerasModel): List<CameraItem> {
        val state = model.state.value
        val ordered = state.saved.withIndex().sortedWith { a, b ->
            val x = a.value.lastConnected
            val y = b.value.lastConnected
            when {
                x != null && y != null && x != y -> y.compareTo(x)
                x != null && y == null -> -1
                x == null && y != null -> 1
                else -> a.index.compareTo(b.index)
            }
        }.map { it.value }
        val latest = ordered.firstOrNull { it.lastConnected != null }?.id
        return ordered.map { camera ->
            val attempt = state.attempts[camera.id]
            val failure = state.failures[camera.id]
            val nearby = sighting(camera, state) != null
            val addable = addableRoutes(camera, model)
            val active = attempt?.route ?: failure?.let { route(it.target) } ?: model.defaultRoute(camera)
            val network = camera.routes.firstOrNull { it.id == active }?.network
            CameraItem(
                id = camera.id,
                name = camera.displayName,
                subtitle = listOfNotNull(camera.model, network).filter { it.isNotEmpty() }.joinToString(" · "),
                badge = when {
                    attempt != null -> "CONNECTING"
                    failure != null -> "NOT CONNECTED"
                    camera.id == latest -> "LAST USED"
                    nearby -> "PAIRED"
                    else -> "OFFLINE"
                },
                status = attempt?.let(::status) ?: if (nearby) "Nearby · ready to connect" else "Not found. Power it on to reconnect",
                actionTitle = if (nearby) "Connect" else "Reconnect",
                isPrimary = camera.id == latest,
                isBusy = attempt != null,
                isAvailable = nearby,
                setups = camera.routes.map {
                    MonitorSetupChip(
                        it.id.text, title(it), it.id == active, it.kind in addable && camera.routes.size > 1,
                        setupKind(it.kind),
                    )
                },
                // As on main: Add only while an addable kind is still missing.
                canAddSetup = (addable - camera.routes.map { it.kind }.toSet()).isNotEmpty(),
                steps = attempt?.let(::steps).orEmpty(),
                failure = failure?.let { failure(it.failure, camera) },
            )
        }
    }

    /** Sightings that are not saved cameras. */
    public fun nearby(model: CamerasModel): List<CameraItem> {
        val state = model.state.value
        return state.nearby.filter { sighting -> state.saved.none { matches(sighting, it) } }.map { device(it, state, model) }
    }

    /** The chip title: the operator's setup name, else the shell's name for the kind. */
    public fun title(route: SavedRoute): String = route.title ?: when (route.kind) {
        RouteKind.CAMERA_ACCESS_POINT -> "Camera Wi-Fi"
        RouteKind.INFRASTRUCTURE_NETWORK -> route.network?.let { "Wi-Fi · $it" } ?: "Wi-Fi"
        RouteKind.PHONE_HOTSPOT -> "Hotspot"
        RouteKind.USB -> "USB-C"
        RouteKind.CAPTURE_DEVICE -> "HDMI"
    }

    /** The chip's accessibility name: the setup names the apps' tests have always used. */
    internal fun setupKind(kind: RouteKind): String = when (kind) {
        RouteKind.CAMERA_ACCESS_POINT -> "cameraWiFi"
        RouteKind.INFRASTRUCTURE_NETWORK -> "wifi"
        RouteKind.PHONE_HOTSPOT, RouteKind.USB, RouteKind.CAPTURE_DEVICE -> kind.rawValue
    }

    /** The attempt's plan as card steps; the running step carries the one live caption. */
    public fun steps(attempt: CamerasModel.Attempt): List<MonitorConnectStep> {
        val progress = attempt.progress ?: return emptyList()
        return progress.steps.mapIndexed { index, step ->
            val state = when {
                index < progress.current -> MonitorConnectStep.State.DONE
                index == progress.current -> MonitorConnectStep.State.ACTIVE
                else -> MonitorConnectStep.State.WAITING
            }
            val detail = if (index == progress.current) attempt.prompt?.text ?: progress.note ?: step.detail else ""
            MonitorConnectStep(step.title, detail, state)
        }
    }

    public fun failure(failure: ConnectionFailure, camera: SavedCamera? = null): MonitorConnectFailure {
        val actions = mutableListOf<MonitorConnectFailure.Action>()
        var link: MonitorConnectFailure.Action? = null
        for (action in failure.actions) {
            when (action) {
                is RecoveryAction.UseRoute -> {
                    val route = camera?.routes?.firstOrNull { it.id == action.route }
                    link = MonitorConnectFailure.Action(id(action), "Connect over ${route?.let(::title) ?: "another setup"} instead")
                }
                RecoveryAction.Retry -> actions += MonitorConnectFailure.Action(id(action), "Try again", primary = true)
                is RecoveryAction.EditRoute -> actions += MonitorConnectFailure.Action(id(action), "Edit setup")
                RecoveryAction.PairAgain -> actions += MonitorConnectFailure.Action(id(action), "Pair again")
                RecoveryAction.OpenSettings -> actions += MonitorConnectFailure.Action(id(action), "Open Settings")
                is RecoveryAction.Integration -> actions += MonitorConnectFailure.Action(id(action), action.title)
            }
        }
        return MonitorConnectFailure(failure.title, failure.message, actions, link)
    }

    /** The stable id of a failure action on the page. */
    public fun id(action: RecoveryAction): String = when (action) {
        RecoveryAction.Retry -> "retry"
        is RecoveryAction.UseRoute -> "route:${action.route.text}"
        is RecoveryAction.EditRoute -> "edit:${action.route.text}"
        RecoveryAction.PairAgain -> "pair"
        RecoveryAction.OpenSettings -> "settings"
        is RecoveryAction.Integration -> "integration:${action.id}"
    }

    /** The failure action of [cameraID] a page action id names. */
    public fun action(id: String, cameraID: String, model: CamerasModel): RecoveryAction? =
        model.state.value.failures[cameraID]?.failure?.actions?.firstOrNull { id(it) == id }

    public fun pairing(model: CamerasModel): MonitorPairingPresentation {
        val state = model.state.value
        val selected = state.nearby.firstOrNull { it.id == state.selection }
        val cameraID = selected?.let { ConnectTarget.Nearby(it.camera).cameraID }
        val attempt = cameraID?.let { state.attempts[it] }
        val failure = cameraID?.let { state.failures[it] }?.failure
        val plan = attempt?.progress?.steps.orEmpty()
        val current = attempt?.progress?.let { 1 + it.current } ?: 0
        val choosing = attempt == null
        val step = attempt?.progress?.let { it.steps.getOrNull(it.current) }
        val instructions = when (val prompt = attempt?.prompt) {
            is ConnectionPrompt.ApproveOnCamera ->
                listOf(MonitorPairingInstruction("On the camera", MonitorPairingInstructionIcon.CAMERA, listOf(prompt.text)))
            is ConnectionPrompt.AcceptNetworkJoin ->
                listOf(MonitorPairingInstruction("On this phone", MonitorPairingInstructionIcon.PHONE, listOf(prompt.text)))
            is ConnectionPrompt.Integration ->
                listOf(MonitorPairingInstruction("Next", MonitorPairingInstructionIcon.CAMERA, listOf(prompt.text)))
            null -> emptyList()
        }
        val settings = failure?.actions?.contains(RecoveryAction.OpenSettings) == true
        return MonitorPairingPresentation(
            steps = listOf(MonitorPairingStep("Find your camera", "Nearby cameras")) + plan.map { MonitorPairingStep(it.title, it.detail) },
            currentStep = current,
            title = failure?.title ?: step?.title ?: "Find your camera",
            body = failure?.message ?: step?.detail ?: "Turn the camera on and keep this phone nearby.",
            target = selected?.camera?.name ?: "Nothing selected yet",
            hint = if (choosing) {
                selected?.let { "Selected ${it.camera.name}" } ?: "Choose the camera that matches your screen"
            } else {
                "Monitoring opens when the picture is ready"
            },
            // The prompt has its own card; the live line is the integration's note or step.
            progress = attempt?.let { it.progress?.note ?: step?.title ?: "Connecting…" },
            devices = if (choosing) {
                state.nearby.map {
                    MonitorPairingDevice(
                        it.id, it.camera.name, "${it.camera.model} · nearby", selected = state.selection == it.id,
                        busy = state.attempts.isNotEmpty(), signalBars = it.camera.signalBars,
                    )
                }
            } else {
                emptyList()
            },
            instructions = instructions,
            emptyTitle = if (choosing && state.nearby.isEmpty()) {
                if (state.scanning) "Looking for cameras" else "No cameras yet"
            } else {
                null
            },
            primaryAction = when {
                failure != null -> if (settings) "Open Settings" else "Try again"
                choosing -> "Continue"
                else -> null
            },
            primaryActionEnabled = failure != null || (choosing && selected != null),
            backAction = when {
                !choosing -> "Cancel"
                state.saved.isEmpty() -> null
                else -> "Back"
            },
        )
    }

    internal fun device(sighting: CamerasModel.Sighting, state: CamerasModel.State, model: CamerasModel): CameraItem {
        val camera = sighting.camera
        val held = camera.availability != Availability.Available
        val copy = model.entries.firstOrNull { it.integration.id == sighting.integration }?.slots?.nearbyCard?.invoke(camera)
        return CameraItem(
            id = camera.id,
            name = copy?.name ?: camera.name,
            subtitle = copy?.subtitle ?: if (camera.model.isEmpty()) "nearby" else "${camera.model} · nearby",
            badge = if (held) "IN USE" else "NEW",
            status = if (held) "In use by another device" else copy?.status ?: "Ready to pair",
            actionTitle = "Pair",
            isPrimary = state.selection == camera.id,
            isBusy = ConnectTarget.Nearby(camera).cameraID in state.attempts,
            isAvailable = !held,
            signalBars = camera.signalBars,
        )
    }

    internal fun status(attempt: CamerasModel.Attempt): String {
        val progress = attempt.progress ?: return "Connecting…"
        return attempt.prompt?.text ?: progress.note ?: progress.steps.getOrNull(progress.current)?.title ?: "Connecting…"
    }

    internal fun matches(sighting: CamerasModel.Sighting, camera: SavedCamera): Boolean =
        sighting.integration == camera.integration && (sighting.camera.savedID == camera.id || sighting.camera.id == camera.id)

    private fun sighting(camera: SavedCamera, state: CamerasModel.State) = state.nearby.firstOrNull { matches(it, camera) }

    /** The routes the camera's profile (matched by model title) can add; without one, any the integration can add. */
    private fun addableRoutes(camera: SavedCamera, model: CamerasModel): Set<RouteKind> {
        val profiles = model.entries.firstOrNull { it.integration.id == camera.integration }?.integration?.profiles ?: return emptySet()
        return profiles.firstOrNull { it.title == camera.model }?.addableRoutes ?: profiles.flatMapTo(mutableSetOf()) { it.addableRoutes }
    }

    private fun route(target: ConnectTarget): ConnectionRouteID? = (target as? ConnectTarget.Saved)?.route
}
