package com.opencapture.opencine.appuitesting

import android.os.SystemClock
import android.util.Log
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.After
import org.junit.Assume.assumeTrue
import org.junit.Test

/**
 * Physical record cell (Swift twin: `PhysicalMigrationQualificationTests` short recording). It opens the
 * app's real launcher, connects the saved camera named by the run, starts recording through the public
 * record control (answering the record confirmation when the operator enabled it), observes the
 * camera-reported state turn to Recording with its elapsed time advancing, stops through the same control
 * and observes the camera report Standby. Media is never deleted; the clip stays on the camera.
 *
 * Opt-in only, so ordinary instrumented runs skip it:
 * `-e opencinePhysicalRecord 1 -e opencinePhysicalCamera <camera row name>`.
 * Stop authority comes only from the start this probe issued: a camera that is already recording, or a
 * recording state that is unknown, is never stopped by it.
 */
public abstract class PhysicalRecordProbe(subject: ConformanceApp) : ConformanceTest(subject) {
    private var startIssued = false
    private val ledger = StringBuilder()

    @Test
    public fun recordsAShortClipThroughThePublicControl() {
        val arguments = InstrumentationRegistry.getArguments()
        assumeTrue("Requires the opted-in physical record run", arguments.getString(OPT_IN) == "1")
        val camera = arguments.getString(CAMERA).orEmpty()
        if (camera.isEmpty()) fail("Name the saved camera with -e $CAMERA <name>")
        launchProduction()
        connect(camera)
        val idle = readout("live-before-recording")
        if (!idle.isIdle) fail("The camera must report Standby before the probe records (reported: ${idle.label})")
        capture("${profile.app}-${device}-physical-record-idle")

        setRecording(start = true)
        val first = awaitReadout("Camera-reported recording", 20_000) { it.isRecording }
        note("recording-confirmed", first)
        val elapsedStart = first.elapsedSeconds ?: awaitReadout("Camera-reported elapsed time", 10_000) {
            it.isRecording && it.elapsedSeconds != null
        }.elapsedSeconds!!
        val advanced = awaitReadout("Camera-reported elapsed time must advance", 20_000) {
            if (!it.isRecording) fail("The camera left recording before the stop was issued (${it.label})")
            (it.elapsedSeconds ?: -1) >= elapsedStart + ADVANCE_SECONDS
        }
        note("recording-advanced", advanced)
        capture("${profile.app}-${device}-physical-record-recording")

        setRecording(start = false)
        val stopped = awaitReadout("Camera-reported Standby after stop", 30_000) { it.isIdle }
        startIssued = false
        note("recording-stopped", stopped)
        capture("${profile.app}-${device}-physical-record-stopped")
        evidence("${javaClass.simpleName}-ledger.txt", ledger.toString())
    }

    /** Stops only a recording this probe started, so a failed run never leaves the camera recording. */
    @After
    public fun stopOwnedRecording() {
        if (!startIssued) return
        runCatching {
            if (readout("teardown").isRecording) setRecording(start = false)
            awaitReadout("Teardown Standby", 30_000) { it.isIdle }
            startIssued = false
        }
        log("teardown startIssued=$startIssued")
        runCatching { evidence("${javaClass.simpleName}-ledger.txt", ledger.toString()) }
    }

    private fun connect(camera: String) {
        val deadline = SystemClock.uptimeMillis() + CONNECT_TIMEOUT_MS
        var tapped = false
        while (SystemClock.uptimeMillis() < deadline) {
            val nodes = snapshot().nodes.filter { it.visible }
            if (nodes.any { it.tag == RECORD && it.enabled }) {
                log("connected camera=$camera tapped=$tapped")
                return
            }
            if (!tapped) {
                // The row's action label; Compose may report the click on a merged ancestor, so the
                // touch goes to the labelled node's bounds as the operator's finger does.
                val row = nodes.firstOrNull { it.label == "Reconnect $camera" || it.label == "Connect $camera" }
                    ?: nodes.firstOrNull { it.label.startsWith("Connect $camera ") }
                if (row != null) {
                    log("connect-row label=${row.label}")
                    tap(row)
                    tapped = true
                }
            }
            pause(500)
        }
        val seen = snapshot().nodes.filter { it.visible && camera in it.label }
            .joinToString("; ") { "${it.label} clickable=${it.info.isClickable} tag=${it.tag}" }
        log("connect-failed rows=[$seen]")
        fail(if (tapped) "The saved camera $camera did not reach the live monitor" else "No saved connect row for $camera")
    }

    private fun setRecording(start: Boolean) {
        val expected = if (start) "Start recording" else "Stop recording"
        val button = awaitTag(RECORD)
        // The control's spoken label sits on the tagged node or on the node inside it that carries it.
        val deadline = SystemClock.uptimeMillis() + 5_000
        var spoken: List<String>
        while (true) {
            spoken = snapshot().nodes.filter { it.visible && button.bounds.contains(it.bounds, 0) }
                .map { it.label }.filter { it == "Start recording" || it == "Stop recording" }.distinct()
            if (spoken == listOf(expected) || SystemClock.uptimeMillis() > deadline) break
            pause(200)
        }
        if (spoken != listOf(expected)) fail("The public record action must read $expected (reads $spoken)")
        if (!start && !startIssued) fail("Stop authority comes only from this probe's own start")
        tap(button)
        val confirm = if (start) "Start" else "Stop"
        val dialog = runCatching { await("Record confirmation", 3_000) { it.label == confirm } }.getOrNull()
        if (start) startIssued = true
        if (dialog != null) {
            log("confirmation=$confirm")
            tap(dialog)
        }
        log("issued ${if (start) "start" else "stop"} at ${SystemClock.uptimeMillis()}")
    }

    private fun readout(stage: String): Readout {
        val node = snapshot().nodes.firstOrNull { it.visible && Readout.matches(it.label) }
            ?: fail("The camera-reported recording readout is missing ($stage)")
        return Readout(node.label)
    }

    private fun awaitReadout(what: String, timeoutMs: Long, done: (Readout) -> Boolean): Readout {
        val deadline = SystemClock.uptimeMillis() + timeoutMs
        while (true) {
            val node = snapshot().nodes.firstOrNull { it.visible && Readout.matches(it.label) }
            val current = node?.let { Readout(it.label) }
            if (current != null && done(current)) return current
            if (SystemClock.uptimeMillis() > deadline) fail("$what (last: ${current?.label})")
            pause(250)
        }
    }

    private fun note(stage: String, readout: Readout) {
        log("$stage at=${SystemClock.uptimeMillis()} label=${readout.label}")
    }

    /** The ledger goes to the test storage and to logcat (tag OpenCinePhysical), which every run keeps. */
    private fun log(line: String) {
        ledger.append(line).append('\n')
        Log.i(LOG_TAG, line)
    }

    /** The recording readout as the camera reports it (`MonitorRecordingReadout` semantics). */
    private class Readout(val label: String) {
        val isRecording: Boolean get() = label == "Recording" || label.startsWith("Recording, ")
        val isIdle: Boolean get() = label == "Standby" || label.startsWith("Standby, ")
        val elapsedSeconds: Int? get() {
            val text = label.substringAfter(", ", "")
            if (text.isEmpty() || text == "Elapsed time unknown") return null
            val minutes = Regex("(\\d+) minutes?").find(text)?.groupValues?.get(1)?.toInt() ?: 0
            val seconds = Regex("(\\d+) seconds?").find(text)?.groupValues?.get(1)?.toInt() ?: 0
            return minutes * 60 + seconds
        }

        companion object {
            fun matches(label: String): Boolean =
                label == "Recording" || label.startsWith("Recording, ") || label == "Standby" || label.startsWith("Standby, ")
        }
    }

    private companion object {
        const val OPT_IN = "opencinePhysicalRecord"
        const val CAMERA = "opencinePhysicalCamera"
        const val RECORD = "monitor.system.record"
        const val ADVANCE_SECONDS = 3
        const val CONNECT_TIMEOUT_MS = 90_000L
        const val LOG_TAG = "OpenCinePhysical"
    }
}
