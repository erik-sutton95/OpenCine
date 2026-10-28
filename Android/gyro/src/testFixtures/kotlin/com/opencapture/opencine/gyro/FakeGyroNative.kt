package com.opencapture.opencine.gyro

import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.Base64
import java.util.UUID
import org.json.JSONArray
import org.json.JSONObject

/**
 * A deterministic [GyroNativeApi] for JVM and UI tests, where no Swift library is loaded.
 *
 * By default it behaves "realish": it answers every member with the JSON shapes the Swift wires
 * produce (the `Wire.swift` files in `Sources/OpenCineGyroAndroid`) from small Kotlin stand-ins: a take
 * session (REC opens a take with the [HEADER] bytes, samples append, REC stop closes after a
 * two-second postroll, 0.5 s without samples stalls), the arming machine (a line-for-line port
 * of `GyroArmingMachine`), a ring that fills [ringHoldStep] per reading with a camera level and
 * captures three poses, and a drift detector that confirms after [driftConfirmAfter] steady
 * readings while [driftMismatch] is true. Policy in production stays in Swift; these stand-ins
 * only exist so coordinator tests can reach realistic states.
 *
 * Tests can also queue literal replies per member with [script] (they win over the realish
 * answer) and read every call in [calls]. Owners are named `<family>-<n>` in creation order.
 */
open class FakeGyroNative : GyroNativeApi {
    /** One recorded native call: the member name and its arguments (byte arrays as sizes). */
    data class Call(val member: String, val args: List<Any?>)

    private val log = mutableListOf<Call>()
    private val scripts = mutableMapOf<String, ArrayDeque<String?>>()
    private val counters = mutableMapOf<String, Int>()
    private val loggers = mutableMapOf<String, FakeTakeSession>()
    private val recoveries = mutableMapOf<String, ByteArray>()
    private val rings = mutableMapOf<String, FakeRing>()
    private val drifts = mutableMapOf<String, FakeDrift>()
    private val machines = mutableMapOf<String, FakeArmingMachine>()

    /** Every call so far, in order. */
    val calls: List<Call> get() = synchronized(log) { log.toList() }

    /** The calls to one member, in order. */
    fun calls(member: String): List<Call> = calls.filter { it.member == member }

    /** Member names in call order, for ordering assertions. */
    fun members(): List<String> = calls.map { it.member }

    /** Queues literal replies for the next calls to [member]; null models a refused call. */
    fun script(member: String, vararg replies: String?) {
        scripts.getOrPut(member) { ArrayDeque() }.addAll(replies)
    }

    /** What [calibrationValidate] answers. */
    var validCalibrations: Boolean = true

    /** The calibration a completed realish ring returns. */
    var ringCalibrationJSON: String = DEFAULT_CALIBRATION

    /** How much one in-zone ring reading fills the hold. */
    var ringHoldStep: Double = 0.5

    /** Steady phone readings with a camera level before a realish drift confirmation. */
    var driftConfirmAfter: Int = 3

    /** Whether the realish drift detector sees a disagreement at all. */
    var driftMismatch: Boolean = true

    /** Whether the realish take session reports a gap warning for open takes. */
    var forceGapWarning: Boolean = false

    /** Owners that are created and not yet closed, by family (logging, ring, drift, arming). */
    fun openOwners(family: String): Set<String> =
        when (family) {
            "logging" -> loggers.keys.toSet()
            "ring" -> rings.keys.toSet()
            "drift" -> drifts.keys.toSet()
            "arming" -> machines.keys.toSet()
            "recovery" -> recoveries.keys.toSet()
            else -> error("Unknown owner family: $family")
        }

    private fun record(member: String, vararg args: Any?) {
        synchronized(log) { log += Call(member, args.toList()) }
    }

    private fun scripted(member: String): Pair<Boolean, String?> {
        val queue = scripts[member] ?: return false to null
        if (queue.isEmpty()) return false to null
        return true to queue.removeFirst()
    }

    private inline fun reply(member: String, realish: () -> String?): String? {
        val (has, value) = scripted(member)
        return if (has) value else realish()
    }

    private fun next(family: String): String {
        val n = (counters[family] ?: 0) + 1
        counters[family] = n
        return "$family-$n"
    }

    // Logging

    override fun loggingCreate(appName: String): String {
        record("loggingCreate", appName)
        return reply("loggingCreate") { null } ?: next("logging").also {
            loggers[it] = FakeTakeSession(appName)
        }
    }

    override fun loggingIngest(owner: String, bytes: ByteArray): String? {
        record("loggingIngest", owner, bytes.size)
        return reply("loggingIngest") { loggers[owner]?.let { it.reply(it.ingest(bytes)) } }
    }

    override fun loggingObserve(
        owner: String,
        recording: Boolean,
        timestamp: Double,
        dateSeconds: Double,
        cameraLabel: String,
        calibrationJSON: String,
    ): String? {
        record("loggingObserve", owner, recording, timestamp, dateSeconds, cameraLabel, calibrationJSON)
        return reply("loggingObserve") {
            loggers[owner]?.let {
                it.reply(it.observe(recording, timestamp, dateSeconds, cameraLabel, calibrationJSON))
            }
        }
    }

    override fun loggingMountMoved(owner: String, timestamp: Double): String? {
        record("loggingMountMoved", owner, timestamp)
        return reply("loggingMountMoved") { loggers[owner]?.let { it.reply(it.mountMoved(timestamp)) } }
    }

    override fun loggingPoll(owner: String, timestamp: Double): String? {
        record("loggingPoll", owner, timestamp)
        return reply("loggingPoll") { loggers[owner]?.let { it.reply(it.poll(timestamp)) } }
    }

    override fun loggingFinish(owner: String, reason: String): String? {
        record("loggingFinish", owner, reason)
        return reply("loggingFinish") { loggers[owner]?.let { it.reply(it.finish(reason)) } }
    }

    override fun loggingClose(owner: String) {
        record("loggingClose", owner)
        loggers.remove(owner)
    }

    // Recovery

    override fun recoveryCreate(): String {
        record("recoveryCreate")
        return next("recovery").also { recoveries[it] = ByteArray(0) }
    }

    override fun recoveryAccept(owner: String, bytes: ByteArray): Long {
        record("recoveryAccept", owner, bytes.size)
        val buffer = (recoveries[owner] ?: return -1) + bytes
        recoveries[owner] = buffer
        val header = HEADER.toByteArray()
        val prefix = buffer.copyOf(minOf(buffer.size, header.size))
        return if (header.copyOf(prefix.size).contentEquals(prefix)) buffer.size.toLong() else -1
    }

    override fun recoveryFinish(
        owner: String,
        descriptorJSON: String,
        mountMovedOffset: Double,
    ): String? {
        record("recoveryFinish", owner, descriptorJSON, mountMovedOffset)
        return reply("recoveryFinish") {
            val buffer = recoveries.remove(owner) ?: return@reply null
            if (!buffer.decodeToString().startsWith(HEADER)) return@reply null
            val descriptor = JSONObject(descriptorJSON)
            summary(descriptor, "recovered", sampleCount = 0, duration = 0.0, partial = true)
                .also { if (!mountMovedOffset.isNaN()) it.put("mountMovedOffset", mountMovedOffset) }
                .toString()
        }
    }

    // Ring calibration

    override fun ringCreate(): String {
        record("ringCreate")
        return next("ring").also { rings[it] = FakeRing() }
    }

    override fun ringStart(owner: String, cameraConnected: Boolean, recording: Int): String? {
        record("ringStart", owner, cameraConnected, recording)
        return reply("ringStart") { rings[owner]?.let { it.start(cameraConnected, recording); it.reply(null) } }
    }

    override fun ringUpdateCamera(owner: String, connected: Boolean, recording: Int): String? {
        record("ringUpdateCamera", owner, connected, recording)
        return reply("ringUpdateCamera") {
            rings[owner]?.let { it.updateCamera(connected, recording); it.reply(null) }
        }
    }

    override fun ringObserve(
        owner: String,
        phoneX: Double,
        phoneY: Double,
        phoneZ: Double,
        phoneTimestamp: Double,
        hasCameraLevel: Boolean,
        cameraX: Double,
        cameraY: Double,
        cameraZ: Double,
        cameraTimestamp: Double,
    ): String? {
        record(
            "ringObserve", owner, phoneX, phoneY, phoneZ, phoneTimestamp, hasCameraLevel,
            cameraX, cameraY, cameraZ, cameraTimestamp,
        )
        return reply("ringObserve") {
            rings[owner]?.let { ring -> ring.reply(ring.observe(hasCameraLevel)) }
        }
    }

    override fun ringInvalidate(owner: String, reason: String): String? {
        record("ringInvalidate", owner, reason)
        return reply("ringInvalidate") { rings[owner]?.let { it.invalidate(reason); it.reply(null) } }
    }

    override fun ringCancel(owner: String): String? {
        record("ringCancel", owner)
        return reply("ringCancel") { rings[owner]?.let { it.cancel(); it.reply(null) } }
    }

    override fun ringClose(owner: String) {
        record("ringClose", owner)
        rings.remove(owner)
    }

    override fun calibrationValidate(calibrationJSON: String): Boolean {
        record("calibrationValidate", calibrationJSON)
        return validCalibrations &&
            runCatching { JSONObject(calibrationJSON).has("rotation") }.getOrDefault(false)
    }

    // Drift

    override fun driftCreate(calibrationJSON: String): String? {
        record("driftCreate", calibrationJSON)
        return reply("driftCreate") {
            if (!calibrationValidateQuiet(calibrationJSON)) null
            else next("drift").also { drifts[it] = FakeDrift() }
        }
    }

    override fun driftObserveCamera(
        owner: String,
        hasLevel: Boolean,
        x: Double,
        y: Double,
        z: Double,
        timestamp: Double,
    ) {
        record("driftObserveCamera", owner, hasLevel, x, y, z, timestamp)
        drifts[owner]?.let {
            it.cameraLevel = hasLevel
            if (!hasLevel) it.steady = 0
        }
    }

    override fun driftObservePhone(
        owner: String,
        x: Double,
        y: Double,
        z: Double,
        timestamp: Double,
        rotationRate: Double,
        accelerationG: Double,
    ): Boolean {
        record("driftObservePhone", owner, x, y, z, timestamp, rotationRate, accelerationG)
        val drift = drifts[owner] ?: return false
        val steady = rotationRate < 0.05 && kotlin.math.abs(accelerationG - 1) <= 0.03
        if (!steady || !drift.cameraLevel || !driftMismatch || drift.confirmed) return false
        drift.steady += 1
        if (drift.steady < driftConfirmAfter) return false
        drift.confirmed = true
        return true
    }

    override fun driftReset(owner: String) {
        record("driftReset", owner)
        drifts[owner]?.let {
            it.steady = 0
            it.confirmed = false
        }
    }

    override fun driftClose(owner: String) {
        record("driftClose", owner)
        drifts.remove(owner)
    }

    // Arming

    override fun armingCreate(pendingRestoresJSON: String): String {
        record("armingCreate", pendingRestoresJSON)
        return next("arming").also { machines[it] = FakeArmingMachine(decodeRestores(pendingRestoresJSON)) }
    }

    override fun armingUpdate(owner: String, inputsJSON: String): String? {
        record("armingUpdate", owner, inputsJSON)
        return reply("armingUpdate") {
            machines[owner]?.let { it.reply(it.update(decodeInputs(inputsJSON))) }
        }
    }

    override fun armingChooseTurnOff(owner: String): String? {
        record("armingChooseTurnOff", owner)
        return reply("armingChooseTurnOff") { machines[owner]?.let { it.reply(it.chooseTurnOff()) } }
    }

    override fun armingChooseKeepOn(owner: String): String? {
        record("armingChooseKeepOn", owner)
        return reply("armingChooseKeepOn") { machines[owner]?.let { it.reply(it.chooseKeepOn()) } }
    }

    override fun armingWriteFinished(owner: String, purpose: String, succeeded: Boolean): String? {
        record("armingWriteFinished", owner, purpose, succeeded)
        return reply("armingWriteFinished") {
            machines[owner]?.let { it.reply(it.writeFinished(purpose, succeeded)) }
        }
    }

    override fun armingClose(owner: String) {
        record("armingClose", owner)
        machines.remove(owner)
    }

    override fun cameraDown(roll: Double, pitch: Double): String? {
        record("cameraDown", roll, pitch)
        return reply("cameraDown") { null }
    }

    private fun calibrationValidateQuiet(json: String): Boolean =
        validCalibrations && runCatching { JSONObject(json).has("rotation") }.getOrDefault(false)

    /** Shared constants. */
    companion object {
        /** The bytes a realish take starts with; realish recovery accepts files that start so. */
        const val HEADER: String = "valid gyro header\n"

        /** An identity mount rotation in the shape `GyroMountCalibration` encodes. */
        const val DEFAULT_CALIBRATION: String =
            """{"rotation":[{"x":1,"y":0,"z":0},{"x":0,"y":1,"z":0},{"x":0,"y":0,"z":1}],"validationErrorDegrees":1.5,"separationDegrees":60}"""

        internal fun summary(
            descriptor: JSONObject,
            termination: String,
            sampleCount: Int,
            duration: Double,
            partial: Boolean,
            largestGap: Double = 0.01,
        ): JSONObject =
            JSONObject()
                .put("descriptor", descriptor)
                .put("sampleCount", sampleCount)
                .put("duration", duration)
                .put("measuredRate", 100)
                .put("largestGap", largestGap)
                .put("rejectedSampleCount", 0)
                .put("termination", termination)
                .put("isPartial", partial)
                .put("approximateStartOffset", descriptor.getDouble("approximateStartOffset"))
    }

    // Realish stand-ins

    private inner class FakeTakeSession(private val appName: String) {
        private inner class Take(val descriptor: JSONObject, val origin: Double) {
            val id: String get() = descriptor.getString("id")
            var end: Double? = null
            var mountMovedOffset: Double? = null
            var first: Double? = null
            var last: Double? = null
            var count = 0
            var largestGap = 0.0
        }

        private val takes = mutableListOf<Take>()
        private val prebuffer = ArrayDeque<DoubleArray>()
        private var observed: Boolean? = null
        private var latest: Double? = null
        private var armedAt: Double? = null
        private var finished = false
        private var termination: String? = null

        fun ingest(bytes: ByteArray): List<JSONObject> {
            if (finished) return emptyList()
            val buffer = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
            val samples = mutableListOf<DoubleArray>()
            while (buffer.remaining() >= 32) {
                val sample = DoubleArray(4) { buffer.double }
                if (latest?.let { sample[0] > it } != false) {
                    latest = sample[0]
                    samples += sample
                    prebuffer.addLast(sample)
                }
            }
            latest?.let { newest -> while (prebuffer.firstOrNull()?.let { it[0] < newest - 2 } == true) prebuffer.removeFirst() }
            val updates = mutableListOf<JSONObject>()
            for (take in takes) append(take, samples)?.let { updates += it }
            latest?.let { updates += completePostroll(it) }
            return updates
        }

        fun observe(
            recording: Boolean,
            timestamp: Double,
            date: Double,
            label: String,
            calibration: String,
        ): List<JSONObject> {
            if (finished) return emptyList()
            if (armedAt == null) armedAt = timestamp
            if (observed == recording) return emptyList()
            val wasUnknown = observed == null
            observed = recording
            val updates = completePostroll(timestamp).toMutableList()
            if (!recording) {
                takes.filter { it.end == null }.forEach { it.end = timestamp + 2 }
                return updates
            }
            val origin = maxOf(0.0, timestamp - 2)
            val id = UUID.randomUUID().toString().uppercase()
            val descriptor = JSONObject()
                .put("id", id)
                .put("cameraLabel", label)
                .put("writer", appName)
                .put("startDate", date * 1000)
                .put("filename", "$appName-$id.gcsv")
                .put("approximateStartOffset", timestamp - origin)
                .put("isPartial", wasUnknown)
                .put("mountPreset", "unconfigured")
            if (calibration.isNotEmpty()) descriptor.put("mountCalibration", JSONObject(calibration))
            val take = Take(descriptor, origin)
            updates += JSONObject().put("kind", "opened").put("id", id).put("descriptor", descriptor)
            updates += appended(id, HEADER.toByteArray())
            append(take, prebuffer.toList())?.let { updates += it }
            takes += take
            return updates
        }

        fun mountMoved(timestamp: Double): List<JSONObject> {
            if (finished) return emptyList()
            return takes.filter { it.end == null && it.mountMovedOffset == null }.map { take ->
                val start = take.origin + take.descriptor.getDouble("approximateStartOffset")
                val offset = Math.round(maxOf(0.0, timestamp - start) * 1000) / 1000.0
                take.mountMovedOffset = offset
                JSONObject().put("kind", "mountMoved").put("id", take.id).put("offsetSeconds", offset)
            }
        }

        fun poll(timestamp: Double): List<JSONObject> {
            if (finished) return emptyList()
            if (armedAt == null) armedAt = timestamp
            val reference = latest ?: armedAt ?: timestamp
            if (timestamp - reference >= 0.5) return finish("sensorStalled")
            return completePostroll(timestamp)
        }

        fun finish(reason: String): List<JSONObject> {
            if (finished) return emptyList()
            finished = true
            termination = reason
            val updates = takes.map { finishedUpdate(it, reason) }
            takes.clear()
            prebuffer.clear()
            return updates
        }

        fun reply(updates: List<JSONObject>): String =
            JSONObject()
                .put("updates", JSONArray(updates))
                .put("active", takes.isNotEmpty())
                .put("gapWarning", takes.isNotEmpty() && (forceGapWarning || takes.any { it.largestGap > 0.05 }))
                .put("finished", finished)
                .put("hasSamples", latest != null)
                .also { reply -> termination?.let { reply.put("termination", it) } }
                .toString()

        private fun append(take: Take, samples: List<DoubleArray>): JSONObject? {
            val accepted = samples.filter { it[0] >= take.origin && (take.end?.let { end -> it[0] <= end } ?: true) && (take.last?.let { last -> it[0] > last } ?: true) }
            if (accepted.isEmpty()) return null
            val buffer = ByteBuffer.allocate(accepted.size * 32).order(ByteOrder.LITTLE_ENDIAN)
            for (sample in accepted) {
                take.last?.let { take.largestGap = maxOf(take.largestGap, sample[0] - it) }
                if (take.first == null) take.first = sample[0]
                take.last = sample[0]
                take.count += 1
                sample.forEach { buffer.putDouble(it) }
            }
            return appended(take.id, buffer.array())
        }

        private fun completePostroll(timestamp: Double): List<JSONObject> {
            val done = takes.filter { take -> take.end?.let { timestamp >= it } == true }
            takes.removeAll(done)
            return done.map { finishedUpdate(it, "normal") }
        }

        private fun finishedUpdate(take: Take, reason: String): JSONObject {
            val duration = (take.last ?: take.origin) - (take.first ?: take.origin)
            val summary = summary(
                take.descriptor, reason, take.count, duration,
                partial = reason != "normal" || take.descriptor.getBoolean("isPartial"),
                largestGap = take.largestGap,
            )
            take.mountMovedOffset?.let { summary.put("mountMovedOffset", it) }
            return JSONObject().put("kind", "finished").put("id", take.id).put("summary", summary)
        }

        private fun appended(id: String, bytes: ByteArray): JSONObject =
            JSONObject().put("kind", "appended").put("id", id)
                .put("data", Base64.getEncoder().encodeToString(bytes))
    }

    private inner class FakeRing {
        var phase = "intro"
        var step: Int? = null
        var inZone: Boolean? = null
        var hold: Double? = null
        var block: String? = null
        var invalidation: String? = null
        var completed = 0
        var connected = false
        var recording = -1
        var calibration: String? = null

        private val inProgress: Boolean get() = phase in setOf("posing", "blocked", "retrying")

        fun start(cameraConnected: Boolean, recording: Int) {
            completed = 0
            calibration = null
            connected = cameraConnected
            this.recording = recording
            invalidation = null
            when {
                !cameraConnected -> blocked(0, "cameraDisconnected")
                recording == 1 -> blocked(0, "recording")
                else -> posing(0, false, 0.0)
            }
        }

        fun updateCamera(connected: Boolean, recording: Int) {
            val wasConnected = this.connected
            val wasRecording = this.recording
            this.connected = connected
            this.recording = recording
            if (completed == 0 || !inProgress) return
            if (wasConnected && !connected) invalidate("connectionEnded")
            else if (recording == 1 && wasRecording != 1) invalidate("recordingStarted")
        }

        fun observe(hasCameraLevel: Boolean): String? {
            if (!inProgress) return null
            val current = minOf(completed, 2)
            when {
                !connected -> { blocked(current, "cameraDisconnected"); return null }
                recording == 1 -> { blocked(current, "recording"); return null }
                !hasCameraLevel -> { blocked(current, "waitingForCamera"); return null }
            }
            val filled = minOf(1.0, (if (phase == "posing" && inZone == true) hold ?: 0.0 else 0.0) + ringHoldStep)
            posing(current, true, filled)
            if (filled < 1) return null
            completed += 1
            if (completed == 3) {
                phase = "complete"
                step = null; inZone = null; hold = null; block = null
                calibration = ringCalibrationJSON
                return "completed"
            }
            posing(completed, false, 0.0)
            return "stepCaptured"
        }

        fun invalidate(reason: String) {
            completed = 0
            phase = "invalidated"
            step = null; inZone = null; hold = null; block = null
            invalidation = reason
        }

        fun cancel() {
            completed = 0
            connected = false
            recording = -1
            phase = "intro"
            step = null; inZone = null; hold = null; block = null; invalidation = null
        }

        fun reply(event: String?): String =
            JSONObject()
                .put("phase", phase)
                .put("step", step ?: JSONObject.NULL)
                .put("inZone", inZone ?: JSONObject.NULL)
                .put("hold", hold ?: JSONObject.NULL)
                .put("block", block ?: JSONObject.NULL)
                .put("invalidation", invalidation ?: JSONObject.NULL)
                .put("completedSteps", completed)
                .put("event", event ?: JSONObject.NULL)
                .put(
                    "calibration",
                    if (phase == "complete" || event == "completed") JSONObject(calibration ?: ringCalibrationJSON)
                    else JSONObject.NULL,
                )
                .toString()

        private fun posing(step: Int, inZone: Boolean, hold: Double) {
            phase = "posing"; this.step = step; this.inZone = inZone; this.hold = hold; block = null
        }

        private fun blocked(step: Int, reason: String) {
            phase = "blocked"; this.step = step; inZone = null; hold = null; block = reason
        }
    }

    private class FakeDrift {
        var cameraLevel = false
        var steady = 0
        var confirmed = false
    }
}

/** One owed restore in the realish arming machine. */
private data class FakeRestore(
    val cameraID: String,
    val saved: Map<String, String>,
    val applied: Map<String, String>,
)

private data class FakeInputs(
    val toggleOn: Boolean,
    val cameraID: String?,
    val hostEligible: Boolean,
    val videoMode: Boolean?,
    val recording: Boolean?,
    val values: Map<String, String>?,
    val lensHasVRSwitch: Boolean?,
    val settings: List<Pair<String, String>>,
    val providesLevel: Boolean,
    val hasSavedCalibration: Boolean,
) {
    fun isOff(): Boolean? {
        val known = settings.mapNotNull { (key, off) -> values?.get(key)?.let { it == off } }
        return if (known.isEmpty()) null else known.all { it }
    }
}

/** A line-for-line Kotlin port of `GyroArmingMachine`, emitting the wire's JSON effects. */
private class FakeArmingMachine(restores: List<FakeRestore>) {
    private data class WriteContext(val cameraID: String, val connection: Int, val applied: Map<String, String>)

    var isArmed = false
    var stabilizationWarning = false
    var pendingRestores = restores.toMutableList()
    private var latest: FakeInputs? = null
    private val writesInFlight = mutableMapOf<String, WriteContext>()
    private var connection = 0
    private var restoreBlocked = false
    private var deferredSetup = false

    fun update(inputs: FakeInputs): List<JSONObject> {
        val effects = mutableListOf<JSONObject>()
        if (stabilizationWarning && inputs.isOff() == true) stabilizationWarning = false
        if (latest?.cameraID != inputs.cameraID) {
            connection += 1
            restoreBlocked = false
            writesInFlight.clear()
            stabilizationWarning = false
            if (isArmed) {
                isArmed = false
                deferredSetup = false
                effects += kind("sessionEnded")
            }
        }
        latest = inputs
        reconcile(inputs, effects)
        return effects
    }

    fun chooseTurnOff(): List<JSONObject> {
        val inputs = latest ?: return emptyList()
        val camera = inputs.cameraID ?: return emptyList()
        if (!isArmed || writesInFlight.isNotEmpty()) return emptyList()
        val saved = mutableMapOf<String, String>()
        var applied = mutableMapOf<String, String>()
        inputs.values?.let { values ->
            for ((key, off) in inputs.settings) {
                val value = values[key] ?: continue
                if (value == off) continue
                saved[key] = value
                applied[key] = off
            }
        }
        if (applied.isEmpty()) return emptyList()
        val index = pendingRestores.indexOfFirst { it.cameraID == camera }
        if (index >= 0) {
            val pending = pendingRestores[index]
            val mergedSaved = pending.saved.toMutableMap()
            val mergedApplied = pending.applied.toMutableMap()
            for ((key, value) in saved) {
                if (mergedSaved[key] == null) {
                    mergedSaved[key] = value
                    mergedApplied[key] = applied.getValue(key)
                }
            }
            pendingRestores[index] = FakeRestore(camera, mergedSaved, mergedApplied)
            applied = mergedApplied
        } else {
            pendingRestores += FakeRestore(camera, saved, applied)
        }
        writesInFlight["turnOff"] = WriteContext(camera, connection, applied)
        return listOf(persist(), write(applied, "turnOff"))
    }

    fun chooseKeepOn(): List<JSONObject> {
        if (!isArmed) return emptyList()
        stabilizationWarning = true
        return emptyList()
    }

    fun writeFinished(purpose: String, succeeded: Boolean): List<JSONObject> {
        val context = writesInFlight[purpose] ?: return emptyList()
        var inputs = latest ?: return emptyList()
        if (context.connection != connection) return emptyList()
        writesInFlight.remove(purpose)
        val effects = mutableListOf<JSONObject>()
        if (purpose == "turnOff") {
            if (succeeded) {
                stabilizationWarning = false
                inputs = inputs.copy(values = (inputs.values ?: emptyMap()) + context.applied)
            } else {
                if (isArmed) stabilizationWarning = true
                effects += notice("turnOffFailed")
            }
        } else {
            if (succeeded) {
                // Mirrors the Swift machine: the camera now holds the restored values.
                inputs = inputs.copy(values = (inputs.values ?: emptyMap()) + context.applied)
                pendingRestores.removeAll { it.cameraID == context.cameraID }
                effects += persist()
            } else {
                effects += notice("restoreFailed")
                if (inputs.cameraID == context.cameraID) restoreBlocked = true
            }
        }
        latest = inputs
        reconcile(inputs, effects)
        return effects
    }

    fun reply(effects: List<JSONObject>): String =
        JSONObject()
            .put("effects", JSONArray(effects))
            .put("isArmed", isArmed)
            .put("stabilizationWarning", stabilizationWarning)
            .toString()

    private fun reconcile(inputs: FakeInputs, effects: MutableList<JSONObject>) {
        val eligible = inputs.toggleOn && inputs.cameraID != null && inputs.hostEligible &&
            inputs.videoMode == true
        if (isArmed && !eligible) {
            isArmed = false
            deferredSetup = false
            stabilizationWarning = false
            effects += kind("sessionEnded")
        }
        if (writesInFlight.isNotEmpty()) return
        if (isArmed) {
            if (deferredSetup && inputs.recording == false) {
                deferredSetup = false
                val steps = steps(inputs)
                if (steps.length() > 0) effects += kind("presentSetup").put("steps", steps)
            }
            return
        }
        val cameraID = inputs.cameraID ?: return
        val index = pendingRestores.indexOfFirst { it.cameraID == cameraID }
        if (!restoreBlocked && index >= 0) {
            val values = inputs.values
            if (values == null || inputs.recording == true) return
            val pending = pendingRestores[index]
            val restore = pending.applied.filter { (key, applied) -> values[key] == applied && pending.saved[key] != null }
                .mapValues { (key, _) -> pending.saved.getValue(key) }
            if (restore.isEmpty()) {
                pendingRestores.removeAt(index)
                effects += persist()
            } else {
                writesInFlight["restore"] = WriteContext(cameraID, connection, restore)
                effects += write(restore, "restore")
                return
            }
        }
        if (eligible) {
            isArmed = true
            effects += kind("sessionStarted")
            val steps = steps(inputs)
            if (steps.length() > 0) {
                if (inputs.recording == true) deferredSetup = true
                else effects += kind("presentSetup").put("steps", steps)
            }
        }
    }

    private fun steps(inputs: FakeInputs): JSONArray {
        val steps = JSONArray()
        if (inputs.settings.isNotEmpty() && inputs.isOff() == false) {
            steps.put(
                JSONObject().put("kind", "stabilization")
                    .put("lensHasVRSwitch", inputs.lensHasVRSwitch ?: JSONObject.NULL),
            )
        }
        if (inputs.providesLevel) {
            steps.put(
                JSONObject().put("kind", "calibration")
                    .put("hasSavedCalibration", inputs.hasSavedCalibration),
            )
        }
        return steps
    }

    private fun kind(name: String): JSONObject = JSONObject().put("kind", name)

    private fun notice(name: String): JSONObject = kind("notice").put("notice", name)

    private fun write(values: Map<String, String>, purpose: String): JSONObject =
        kind("writeStabilization").put("purpose", purpose).put("values", JSONObject(values))

    private fun persist(): JSONObject =
        kind("persistPendingRestores").put(
            "restores",
            JSONArray(
                pendingRestores.map {
                    JSONObject().put("cameraID", it.cameraID)
                        .put("saved", JSONObject(it.saved)).put("applied", JSONObject(it.applied))
                },
            ),
        )
}

private fun decodeRestores(json: String): List<FakeRestore> =
    runCatching {
        val array = JSONArray(json)
        (0 until array.length()).map { index ->
            val restore = array.getJSONObject(index)
            FakeRestore(
                restore.getString("cameraID"),
                restore.getJSONObject("saved").toMap(),
                restore.getJSONObject("applied").toMap(),
            )
        }
    }.getOrDefault(emptyList())

private fun decodeInputs(json: String): FakeInputs {
    val inputs = JSONObject(json)
    val stabilization = inputs.optJSONObject("stabilization")
    val settings = inputs.getJSONArray("settings")
    return FakeInputs(
        toggleOn = inputs.getBoolean("toggleOn"),
        cameraID = inputs.optJSONObject("camera")?.getString("id"),
        hostEligible = inputs.getBoolean("hostEligible"),
        videoMode = if (inputs.isNull("videoMode")) null else inputs.getBoolean("videoMode"),
        recording = if (inputs.isNull("recording")) null else inputs.getBoolean("recording"),
        values = stabilization?.getJSONObject("values")?.toMap(),
        lensHasVRSwitch = stabilization?.let { if (it.isNull("lensHasVRSwitch")) null else it.getBoolean("lensHasVRSwitch") },
        settings = (0 until settings.length()).map {
            val setting = settings.getJSONObject(it)
            setting.getString("key") to setting.getString("offValue")
        },
        providesLevel = inputs.getBoolean("providesLevel"),
        hasSavedCalibration = inputs.getBoolean("hasSavedCalibration"),
    )
}

private fun JSONObject.toMap(): Map<String, String> =
    buildMap { keys().forEach { put(it, getString(it)) } }
