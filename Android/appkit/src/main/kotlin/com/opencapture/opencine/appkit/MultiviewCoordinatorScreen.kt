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
 * Found cameras the Add list offers: those the policy lets join (experimentally if need be) and that
 * are not members. One without a picture says so and joins experimentally.
 */
public fun <Camera, Link : MultiviewMemberLink<Camera>> MultiviewCoordinator<Camera, Link>.pickerRows(): List<MultiviewPickerRow> =
    addable().map { camera ->
        val record = describe(camera)
        val preview = policy.hasPreview(camera)
        MultiviewPickerRow(
            record.id, record.name,
            detail = if (preview) null else MultiviewCopy.PREVIEW_UNAVAILABLE,
            limited = !preview,
        )
    }

/** The Add list's footer for this stage's network. */
public val <Camera, Link : MultiviewMemberLink<Camera>> MultiviewCoordinator<Camera, Link>.pickerFooter: String
    get() = MultiviewCopy.pickerFooter(ssid, commissioned = commissioner != null)

/**
 * Adds the camera of the Add list's row [id] to [slot] (experimentally when it shows no picture);
 * false when the row is gone.
 */
public fun <Camera, Link : MultiviewMemberLink<Camera>> MultiviewCoordinator<Camera, Link>.enqueueAdd(
    pickerRow: String,
    slot: Int,
): Boolean {
    val camera = addable().firstOrNull { describe(it).id == pickerRow } ?: return false
    enqueueAdd(camera, slot, experimental = !policy.hasPreview(camera))
    return true
}

private fun <Camera, Link : MultiviewMemberLink<Camera>> MultiviewCoordinator<Camera, Link>.addable(): List<Camera> {
    val joined = members.mapNotNull { member -> member.camera?.let { describe(it).id } }.toSet()
    return found.filter { camera ->
        policy.qualification(camera, true) !is MulticamQualification.Refused && describe(camera).id !in joined
    }
}

/** Whether closing returns cameras to their own networks: only an app that moved them there. */
public val <Camera, Link : MultiviewMemberLink<Camera>> MultiviewCoordinator<Camera, Link>.networkRestore: MultiviewNetworkRestore
    get() = if (commissioner == null) MultiviewNetworkRestore.NONE else MultiviewNetworkRestore.CAMERA_NETWORKS

/** The network wizard may scan through a nearby camera. */
public val <Camera, Link : MultiviewMemberLink<Camera>> MultiviewCoordinator<Camera, Link>.scansNetworks: Boolean
    get() = commissioner?.scansNetworks ?: false

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
