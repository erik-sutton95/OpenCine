package com.opencapture.opencine.appkit

import com.opencapture.opencine.core.MulticamQualification
import com.opencapture.opencine.core.MultiviewMemberLink

// The shared screen's rules over the coordinator: what the Add list offers, the close copy, the
// Auto LUT toggles, the stage tiles with the app's readings and the tools the app supports. Each
// follows a capability (the commissioner's presence, the camera policy, the host's values), never a
// brand. Swift twin: `MultiviewCoordinator+Screen.swift`.

/** [slot]'s camera name, null while the slot is empty. */
public fun <Camera, Link : MultiviewMemberLink<Camera>> MultiviewCoordinator<Camera, Link>.cameraName(slot: Int): String? =
    members[slot].camera?.let { describe(it).name }

/**
 * Found cameras the Add list offers: those the policy lets join (experimentally if need be and the
 * commissioner offers it) and that are not members. One without a picture says so and joins
 * experimentally where it can.
 */
public fun <Camera, Link : MultiviewMemberLink<Camera>> MultiviewCoordinator<Camera, Link>.pickerRows(): List<MultiviewPickerRow> =
    addable().map { camera ->
        val record = describe(camera)
        val preview = policy.hasPreview(camera)
        MultiviewPickerRow(
            record.id, record.name,
            detail = if (preview || !offersExperimentalJoin) null else MultiviewCopy.PREVIEW_UNAVAILABLE,
            limited = !preview,
        )
    }

/** The Add list's footer for this stage's network. */
public val <Camera, Link : MultiviewMemberLink<Camera>> MultiviewCoordinator<Camera, Link>.pickerFooter: String
    get() {
        val footer = MultiviewCopy.pickerFooter(
            ssid, commissioned = commissioner != null, asksApproval = commissioner?.asksApprovalOnCamera ?: false,
        )
        val guidance = host?.pickerGuidance
        return if (guidance.isNullOrEmpty()) footer else "$footer\n\n$guidance"
    }

/**
 * Adds the camera of the Add list's row [id] to [slot] (experimentally when it shows no picture and
 * the commissioner offers it); false when the row is gone.
 */
public fun <Camera, Link : MultiviewMemberLink<Camera>> MultiviewCoordinator<Camera, Link>.enqueueAdd(
    pickerRow: String,
    slot: Int,
): Boolean {
    val camera = addable().firstOrNull { describe(it).id == pickerRow } ?: return false
    enqueueAdd(camera, slot, experimental = offersExperimentalJoin && !policy.hasPreview(camera))
    return true
}

private fun <Camera, Link : MultiviewMemberLink<Camera>> MultiviewCoordinator<Camera, Link>.addable(): List<Camera> {
    val joined = members.mapNotNull { member -> member.camera?.let { describe(it).id } }.toSet()
    val experimental = offersExperimentalJoin
    return found.filter { camera ->
        policy.qualification(camera, experimental) !is MulticamQualification.Refused && describe(camera).id !in joined
    }
}

/**
 * The stage asks the operator for its shared network with the network wizard (and offers the Shared
 * Wi-Fi button): only where a commissioner moves cameras onto it. Without one the cameras already
 * share this phone's network.
 */
public val <Camera, Link : MultiviewMemberLink<Camera>> MultiviewCoordinator<Camera, Link>.choosesNetwork: Boolean
    get() = commissioner != null

/**
 * The experimental shared Wi-Fi path: a failed camera may try it and a camera without a picture joins
 * through it, only where the commissioner offers it.
 */
public val <Camera, Link : MultiviewMemberLink<Camera>> MultiviewCoordinator<Camera, Link>.offersExperimentalJoin: Boolean
    get() = commissioner?.joinsExperimentally ?: false

/**
 * What the shared screen does when it appears: starts the stage (unless [startsSession] is false, a
 * review fixture) and answers whether the network wizard opens first. Both screens call it, so an
 * app presents the screen over a coordinator it has not started.
 */
public fun <Camera, Link : MultiviewMemberLink<Camera>> MultiviewCoordinator<Camera, Link>.screenAppeared(
    startsSession: Boolean,
): Boolean {
    if (startsSession) start()
    return choosesNetwork && !networkConfigured
}

/** Whether closing returns cameras to their own networks: only an app that moved them there. */
public val <Camera, Link : MultiviewMemberLink<Camera>> MultiviewCoordinator<Camera, Link>.networkRestore: MultiviewNetworkRestore
    get() = if (commissioner == null) MultiviewNetworkRestore.NONE else MultiviewNetworkRestore.CAMERA_NETWORKS

/** The network wizard may scan through a nearby camera. */
public val <Camera, Link : MultiviewMemberLink<Camera>> MultiviewCoordinator<Camera, Link>.scansNetworks: Boolean
    get() = commissioner?.scansNetworks ?: false

/**
 * The network wizard's scan through a camera ([scan], null when the commissioner cannot scan) and
 * whether the camera can list networks at all (the wizard's "can't list networks" copy otherwise).
 */
internal class MultiviewWizardScan(
    val scan: (suspend ((String) -> Unit) -> Unit)?,
    val cameraScansNetworks: Boolean,
)

internal val <Camera, Link : MultiviewMemberLink<Camera>> MultiviewCoordinator<Camera, Link>.wizardScan: MultiviewWizardScan
    get() = if (scansNetworks) {
        MultiviewWizardScan({ found -> scanNetworks(found) }, cameraScansNetworks = true)
    } else {
        MultiviewWizardScan(null, cameraScansNetworks = false)
    }

/** Toggles [slot]'s Auto LUT and saves the choice. */
public fun <Camera, Link : MultiviewMemberLink<Camera>> MultiviewCoordinator<Camera, Link>.toggleLUT(slot: Int) {
    members[slot].lutEnabled = !members[slot].lutEnabled
    host?.lutChanged(slot)
    persistStage()
}

/** The LUT tool: every member on, unless all already are (then every member off). */
public fun <Camera, Link : MultiviewMemberLink<Camera>> MultiviewCoordinator<Camera, Link>.toggleLUT() {
    val slots = memberSlots
    val enabled = !slots.all { members[it].lutEnabled }
    for (slot in slots) {
        if (members[slot].lutEnabled != enabled) {
            members[slot].lutEnabled = enabled
            host?.lutChanged(slot)
        }
    }
    persistStage()
}

/** Some member grades its picture. */
public val <Camera, Link : MultiviewMemberLink<Camera>> MultiviewCoordinator<Camera, Link>.lutOn: Boolean
    get() = memberSlots.any { members[it].lutEnabled }

/**
 * The stage's values for [slot] from the app's readings (or the camera's name alone), null while it
 * is empty. The Auto LUT option shows only where the app grades pictures. Compose's status card
 * offers a failed member's own buttons (Reconnect, Try experimental, Remove; a per-platform look,
 * `docs/appkit`), which SwiftUI keeps in the options popup.
 */
public fun <Camera, Link : MultiviewMemberLink<Camera>> MultiviewCoordinator<Camera, Link>.stageTile(slot: Int): MultiviewTile? {
    val camera = members[slot].camera ?: return null
    val readings = host?.readings(slot)
        ?: MultiviewTileReadings(describe(camera).name, hasPicture = members[slot].publishing)
    val tile = tile(slot, readings) ?: return null
    val actions = if (host?.appliesAutoLUT == true) tile.actions
    else tile.actions.filter { it.id != MultiviewCameraAction.LUT }
    val status = tile.status?.let { status ->
        if (members[slot].failureMessage == null) status
        else status.copy(actions = actions.filter { it.id in FAILURE_ACTIONS })
    }
    return tile.copy(actions = actions, status = status)
}

private val FAILURE_ACTIONS = setOf(
    MultiviewCameraAction.EXPERIMENTAL, MultiviewCameraAction.RECONNECT, MultiviewCameraAction.REMOVE,
)

/** The program camera's readouts (Center stage), null while its slot is empty or the app reads nothing from it. */
public val <Camera, Link : MultiviewMemberLink<Camera>> MultiviewCoordinator<Camera, Link>.programReadouts: List<MultiviewReadout>?
    get() {
        if (members.isEmpty()) return null
        val slot = presentation.selected.coerceIn(0, members.size - 1)
        if (members[slot].camera == null) return null
        return host?.readings(slot)?.readouts
    }

/** Slots whose camera settings the popup edits: every member, when the app edits settings. */
public val <Camera, Link : MultiviewMemberLink<Camera>> MultiviewCoordinator<Camera, Link>.cameraSettingsSlots: List<Int>
    get() = if (host?.editsCameraSettings == true) memberSlots else emptyList()

/** The tools the stage offers: CAMERA where the app edits settings, LUT where it grades. */
public val <Camera, Link : MultiviewMemberLink<Camera>> MultiviewCoordinator<Camera, Link>.toolAvailability: MultiviewToolAvailability
    get() = MultiviewToolAvailability(
        cameraSettingsSlots = cameraSettingsSlots.toSet(),
        pictureLUTSlots = if (host?.appliesAutoLUT == true) memberSlots.toSet() else emptySet(),
    )
