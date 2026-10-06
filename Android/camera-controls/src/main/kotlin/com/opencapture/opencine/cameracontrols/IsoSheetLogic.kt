package com.opencapture.opencine.cameracontrols

import com.opencapture.opencine.vocabulary.CameraCommands
import com.opencapture.opencine.vocabulary.CameraStatus

/** COLOR drum write: `0x02/0x42` then optional native ISO hop. */
data class ColorDrumCommand(val colorMode: Int, val hopIsoIndex: Int?)

/**
 * ISO sheet reseat / apply — mirrors iOS `CapturePickerPanel` ISO seed,
 * `onChange(availableIsoIndices, colorMode)`, `applyDrum`, and Auto/Manual tabs.
 */
object IsoSheetLogic {
    data class State(
        val selectedMode: Int,
        val drumSelection: String,
        val lastApplied: String,
    )

    sealed class Command {
        data class SetIndex(val index: Int) : Command()
        data class SetLimit(val raw: Int) : Command()
    }

    fun isAutoTab(status: CameraStatus, selectedMode: Int): Boolean =
        CaptureLists.offersIsoAuto(status) && selectedMode == 0

    fun reseat(status: CameraStatus, bodyName: String = ""): State {
        val selectedMode =
            if (CaptureLists.offersIsoAuto(status)) {
                if (status.isoIndex == 0) 0 else 1
            } else {
                0
            }
        return reseatDrum(status, selectedMode, bodyName)
    }

    fun reseatDrum(status: CameraStatus, selectedMode: Int, bodyName: String = ""): State {
        val autoTab = isAutoTab(status, selectedMode)
        val labels =
            if (autoTab) CaptureLists.isoAutoLabels(status, bodyName)
            else CaptureLists.isoDrumLabels(status)
        val live =
            if (autoTab) {
                CaptureLists.isoAutoLabel(status, bodyName)
            } else {
                when {
                    status.isoIndex > 0 -> CameraCommands.isoLabel(status.isoIndex)
                    status.iso > 0 -> "${status.iso}"
                    else -> labels.firstOrNull().orEmpty()
                }
            }
        val next = if (live in labels) live else labels.firstOrNull().orEmpty()
        return State(selectedMode, next, next)
    }

    fun applyDrum(
        value: String,
        status: CameraStatus,
        selectedMode: Int,
        bodyName: String = "",
    ): Command? {
        if (value.isEmpty()) return null
        if (isAutoTab(status, selectedMode)) {
            val limit = CaptureLists.isoLimit(value, status, bodyName) ?: return null
            return Command.SetLimit(limit.rawValue)
        }
        val idx = CaptureLists.isoIndexFromLabel(value) ?: return null
        if (idx !in CaptureLists.isoIndices(status) || idx == 0) return null
        return Command.SetIndex(idx)
    }

    fun handleModeChange(
        index: Int,
        status: CameraStatus,
        bodyName: String = "",
    ): Pair<State, Command?> {
        if (!CaptureLists.offersIsoAuto(status)) return reseatDrum(status, 0, bodyName) to null
        return if (index == 0) {
            reseatDrum(status, 0, bodyName) to Command.SetIndex(0)
        } else {
            val state = reseatDrum(status, 1, bodyName)
            val cmd =
                CaptureLists.isoIndexFromLabel(state.drumSelection)?.let { idx ->
                    if (idx in CaptureLists.isoIndices(status)) Command.SetIndex(idx) else null
                }
            state to cmd
        }
    }

    /** iOS `onChange` keys: `availableIsoIndices`, `colorMode` — not live `isoIndex`. */
    fun shouldReseat(previous: CameraStatus, next: CameraStatus): Boolean =
        previous.availableIsoIndices != next.availableIsoIndices ||
            previous.colorMode != next.colorMode
}
