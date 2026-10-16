package com.opencapture.opencine.appkit

import com.opencapture.monitorui.MonitorTimecodeFormat
import com.opencapture.opencine.core.BatteryReading
import com.opencapture.opencine.core.CameraSnapshot
import com.opencapture.opencine.core.CommandRejection
import com.opencapture.opencine.core.ConnectionState
import com.opencapture.opencine.core.MonitorEntryDescriptor
import com.opencapture.opencine.core.RecordingState
import com.opencapture.opencine.core.SettingKey
import com.opencapture.opencine.core.UnavailableReason
import com.opencapture.opencine.multicam.EntrySummary
import com.opencapture.opencine.multicam.ExclusionReason
import com.opencapture.opencine.multicam.RecordDirection
import com.opencapture.opencine.multicam.RecordPlan
import com.opencapture.opencine.multicam.RoleStatus
import java.util.Locale

// Swift twin: Sources/OpenCineAppKit/MultiviewStage.swift (same types and copy).

/** One camera value: the stage's program readouts and Grid's in-tile row. */
public data class MultiviewReadout(
    val title: String,
    val value: String,
    /**
     * What the camera advertises for this value, in order. Empty: not settable from the stage.
     * Picking one calls the stage's `choose` action; the camera's readback decides what shows.
     */
    val choices: List<String> = emptyList(),
)

/** Over a tile's picture while it is not live. */
public data class MultiviewTileStatus(
    /** The short line on the tile. */
    val text: String,
    /** The full sentence: the status card's text and what assistive technology reads. */
    val detail: String = text,
    /** Shows a spinner: the app is still working on it. */
    val inProgress: Boolean,
    /**
     * What the status offers as its own buttons, each run through `perform` (the Compose status
     * card shows them; the SwiftUI pill opens the options instead).
     */
    val actions: List<MultiviewCameraAction> = emptyList(),
)

/**
 * One entry of a camera's options. [Kind.RECORD] opens the stage's record confirmation for that
 * camera; every other kind calls the stage's `perform` action with [id].
 */
public data class MultiviewCameraAction(
    val id: String,
    val title: String,
    val kind: Kind = Kind.ACTION,
    val enabled: Boolean = true,
    /** The SwiftUI options close before `perform` runs (a Compose menu always closes). */
    val closes: Boolean = false,
) {
    public enum class Kind { ACTION, RECORD, DESTRUCTIVE }

    public companion object {
        /** The id the stage's double tap and the Live View entry share. */
        public const val LIVE_VIEW: String = "liveView"
    }
}

/**
 * One occupied slot as the app sees it now. Values only: the app maps its camera state, the
 * stage never reads a session.
 */
public data class MultiviewTile(
    val name: String,
    val model: String = "",
    /** Resolution, rate and look, on roomy tiles and in the options. */
    val format: String = "",
    /** 0..100, null when unknown or when the camera reports [batteryBars] instead. */
    val battery: Int? = null,
    val charging: Boolean = false,
    /** Filled steps of [batteryBarCount] when the camera reports a coarse gauge, never a percent. */
    val batteryBars: Int? = null,
    val batteryBarCount: Int = 5,
    val storage: String = MultiviewTally.UNAVAILABLE,
    val timecode: String? = null,
    /** [MultiviewTally] copy, or the app's own. */
    val tally: String = MultiviewTally.UNAVAILABLE,
    /** Set (epoch milliseconds) while a take runs that the camera does not time: the tally counts. */
    val recordingSince: Long? = null,
    /** Camera-reported recording: red tally and the recording border. */
    val recording: Boolean = false,
    val lut: Boolean = false,
    /** The last result worth showing (a refused value, a failed start), in the options. */
    val note: String? = null,
    /** The note on the tile itself, null to keep the tile quiet. */
    val tileNote: String? = null,
    /** The camera's values, for Grid's in-tile row. */
    val readouts: List<MultiviewReadout> = emptyList(),
    /** Over the picture while it is not live. */
    val status: MultiviewTileStatus? = null,
    /** The options' link line, a failure and a footnote. */
    val detail: String = "",
    val failure: String? = null,
    val footnote: String? = null,
    val actions: List<MultiviewCameraAction> = emptyList(),
    /** What TalkBack reads after the slot letter. */
    val accessibilityValue: String = "",
) {
    public companion object {
        /** The slot letter, A for the first. */
        public fun letter(slot: Int): String = ('A' + slot.coerceIn(0, 25)).toString()

        /**
         * A tile from Core values alone, for an app whose cameras report only through their
         * `CameraSession`: battery, take state, timecode and the common settings. What the
         * camera has not reported stays unavailable.
         */
        public operator fun invoke(
            entry: MonitorEntryDescriptor,
            summary: EntrySummary,
            snapshot: CameraSnapshot?,
            waiting: Boolean = false,
        ): MultiviewTile {
            fun value(key: SettingKey) = MultiviewReadout(
                MonitorCapturePresentation.title(key).orEmpty(),
                snapshot?.value(key)?.value?.let(MonitorCapturePresentation::label) ?: MultiviewTally.UNAVAILABLE,
            )
            val state = summary.recording.value
            val recording = state?.let { it == RecordingState.RECORDING || it == RecordingState.TRANSITIONING }
            val control = (summary.control as? RoleStatus.Reported)?.value
            // The link as reported: a closed session is not connecting, and no report is a wait.
            val (status, detail) = when (control) {
                ConnectionState.Ready -> null to "Connected"
                is ConnectionState.Disconnected ->
                    MultiviewTileStatus("Disconnected", inProgress = false) to "Disconnected"
                null -> MultiviewTileStatus("Waiting for the camera", inProgress = true) to "Waiting for the camera"
                else -> MultiviewTileStatus("Connecting…", inProgress = true) to "Connecting…"
            }
            return MultiviewTile(
                name = entry.name,
                timecode = MonitorTimecodeFormat.label(snapshot),
                tally = MultiviewTally.text(recording, waiting = waiting, failed = control is ConnectionState.Disconnected),
                recording = state == RecordingState.RECORDING,
                readouts = listOf(
                    value(SettingKey.ISO), value(SettingKey.SHUTTER), value(SettingKey.WHITE_BALANCE),
                    value(SettingKey.FOCUS_MODE),
                ),
                status = status,
                detail = detail,
                actions = listOf(
                    MultiviewCameraAction(MultiviewCameraAction.LIVE_VIEW, "Live View"),
                    MultiviewCameraAction(
                        "record", if (state == RecordingState.RECORDING) "Stop recording" else "Start recording",
                        MultiviewCameraAction.Kind.RECORD,
                    ),
                    MultiviewCameraAction("remove", "Remove camera", MultiviewCameraAction.Kind.DESTRUCTIVE),
                ),
            ).withPower(snapshot?.power)
        }
    }
}

/** The tally copy. Only what the camera reported: no clock of the stage's own. */
public object MultiviewTally {
    /** An unknown value. Never a guess. */
    public const val UNAVAILABLE: String = "\u2014"

    /**
     * [waiting]: a record command is in flight; [holding]: the picture is being restored;
     * [failed]: the link needs attention. [seconds] is the camera's take length, null while it
     * reports none.
     */
    public fun text(
        recording: Boolean?,
        seconds: Int? = null,
        waiting: Boolean = false,
        holding: Boolean = false,
        failed: Boolean = false,
    ): String = when {
        waiting -> "WAIT"
        holding -> "HOLD"
        failed -> "CHECK"
        recording == null -> UNAVAILABLE
        !recording -> "STBY"
        else -> seconds?.let(::running) ?: "REC"
    }

    /** `REC mm:ss`. */
    public fun running(seconds: Int): String {
        val elapsed = seconds.coerceAtLeast(0)
        return String.format(Locale.ROOT, "REC %02d:%02d", elapsed / 60, elapsed % 60)
    }
}

/** The stage's assist tools. Apps list the ones they offer, in their palette order. */
public enum class MultiviewTool { LAYOUT, CAMERA, FIT, LUT }

/** Working host adapters for occupied member slots. An empty value offers no executable tools. */
public data class MultiviewToolAvailability(
    val cameraSettingsSlots: Set<Int> = emptySet(),
    val pictureLUTSlots: Set<Int> = emptySet(),
) {
    /** Preserve the caller's order while intersecting services with current occupied slots. */
    public fun offeredTools(requested: List<MultiviewTool>, occupiedSlots: Set<Int>): List<MultiviewTool> =
        requested.filter { tool ->
            when (tool) {
                MultiviewTool.CAMERA -> cameraSettingsSlots.any { it in occupiedSlots }
                MultiviewTool.LUT -> pictureLUTSlots.any { it in occupiedSlots }
                MultiviewTool.LAYOUT, MultiviewTool.FIT -> true
            }
        }

    public fun cameraSettingsSlot(selected: Int, occupiedSlots: Set<Int>): Int? =
        preferred(selected, cameraSettingsSlots, occupiedSlots)

    public fun pictureLUTSlot(selected: Int, occupiedSlots: Set<Int>): Int? =
        preferred(selected, pictureLUTSlots, occupiedSlots)

    private fun preferred(selected: Int, services: Set<Int>, occupiedSlots: Set<Int>): Int? {
        val admitted = services.intersect(occupiedSlots)
        return selected.takeIf { it in admitted } ?: admitted.minOrNull()
    }
}

/** One camera the Add camera list offers. */
public data class MultiviewPickerRow(
    val id: String,
    val title: String,
    /** Under the title: why it cannot join, or how it will. */
    val detail: String? = null,
    val enabled: Boolean = true,
    /** Joins without its picture: an info glyph instead of the plus. */
    val limited: Boolean = false,
)

/**
 * A record confirmation applies to the plan the operator saw: the same cameras, sessions, links
 * (control epochs), modes, command availability and reported recording states, as the engine's
 * admission fingerprint records them. Timestamps and routine telemetry are excluded so refreshes
 * do not dismiss it; a replacement link, a changed camera or availability does.
 */
public data class MultiviewRecordContext(
    val plan: RecordPlan,
    val busy: Boolean = false,
    val closing: Boolean = false,
    /**
     * The app's own confirmation question (an eligible-subset plan naming the cameras it
     * commands); null asks the shared [question].
     */
    val prompt: String? = null,
) {
    val stopping: Boolean get() = plan.direction == RecordDirection.STOP

    /** Nothing in flight, not closing, and the plan commands at least one camera. */
    val canConfirm: Boolean get() = !busy && !closing && plan.isExecutable

    /** Why the plan is refused, for the disabled control's accessibility description. */
    val refusal: String?
        get() {
            if (!plan.isRefused) return null
            val reason = plan.exclusions.firstOrNull()?.reason ?: return null
            return when {
                reason == ExclusionReason.Busy || reason == ExclusionReason.CameraTransitioning -> "A camera is busy."
                reason == ExclusionReason.Rejected(CommandRejection.RecordingStateUnknown) ->
                    "Waiting for a camera's record state."
                reason == ExclusionReason.Rejected(CommandRejection.Unavailable(UnavailableReason.Mode)) ->
                    "A camera is not in a video mode."
                else -> "A camera is not connected."
            }
        }

    /** The confirmation question for every camera, or for one ([single]). */
    public fun question(single: Boolean): String = when {
        single -> if (stopping) "Stop recording?" else "Start recording?"
        else -> if (stopping) "Stop recording on all cameras?" else "Record on all cameras?"
    }

    public companion object {
        /** A group command is coordinated dispatch, not synchronized recording. */
        public const val GROUP_NOTE: String = "Each camera confirms independently; recording is not synchronized."
    }
}

/**
 * The tile's battery from the camera's typed power: a percent or a declared gauge (a five-bar
 * gauge draws bars, never a percent), and charging as the live chrome reads it (charging, else
 * external power). Twin of Swift `MultiviewTile.withPower`.
 */
public fun MultiviewTile.withPower(power: com.opencapture.opencine.core.PowerStatus?): MultiviewTile {
    val reading = power?.batteryReading
    return copy(
        battery = (reading as? BatteryReading.Fraction)?.let { Math.round(it.value * 100).toInt() },
        batteryBars = (reading as? BatteryReading.Steps)?.filled,
        batteryBarCount = (reading as? BatteryReading.Steps)?.of ?: batteryBarCount,
        charging = (power?.charging?.value ?: power?.externalPower?.value) ?: false,
    )
}
