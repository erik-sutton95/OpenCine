package com.opencapture.opencine.gyro

import android.content.Context
import android.content.SharedPreferences
import android.os.SystemClock
import java.io.File
import java.io.IOException
import kotlin.coroutines.CoroutineContext
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.merge
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withTimeoutOrNull

/**
 * What a host app supplies to the shared gyro capture.
 *
 * @property appName writer name in every log descriptor and file name.
 * @property logRoot app-private directory for the gyro logs.
 * @property preferencesName SharedPreferences file the coordinator opens.
 * @property keys namespaced preference keys.
 * @property legacy old app-wide keys migrated once, or null for a new host.
 */
data class GyroHostConfiguration(
    val appName: String,
    val logRoot: File,
    val preferencesName: String,
    val keys: GyroPreferenceKeys,
    val legacy: GyroLegacyPreferenceKeys? = null,
)

/**
 * Everything the shared gyro screens render.
 *
 * @property enabled the saved toggle: arm whenever possible.
 * @property available the device has a gyroscope and the native wire is loaded.
 * @property pill the monitor pill.
 * @property logs every take, newest first.
 * @property notice the current problem to show, if any.
 * @property tipVisible whether the logs tip is still shown.
 * @property setupSteps the arming setup sheet; non-empty means shown, first is the current step.
 * @property ring the ring calibration screen, or null when calibration is not presented.
 * @property canCalibrate a connected camera with a level and a phone with gravity.
 * @property hasSavedCalibration a calibration is saved for the connected camera.
 * @property driftPromptPresented the post-take "mount moved" prompt is shown.
 * @property driftHapticToken increases once per confirmed mount move, for one light haptic.
 * @property isArmed an armed capture session is running for this connection.
 */
data class GyroCaptureState(
    val enabled: Boolean = false,
    val available: Boolean = false,
    val pill: GyroPillState = GyroPillState(GyroPillKind.HIDDEN, false),
    val logs: List<GyroLogEntry> = emptyList(),
    val notice: GyroNotice? = null,
    val tipVisible: Boolean = true,
    val setupSteps: List<GyroArmingStep> = emptyList(),
    val ring: GyroRingState? = null,
    val canCalibrate: Boolean = false,
    val hasSavedCalibration: Boolean = false,
    val driftPromptPresented: Boolean = false,
    val driftHapticToken: Int = 0,
    val isArmed: Boolean = false,
)

private val gyroCaptureDispatcher = Dispatchers.IO.limitedParallelism(1)

/** The coordinator's serial scope: one thread, so file writes stay ordered behind each other. */
fun gyroCaptureScope(): CoroutineScope = CoroutineScope(SupervisorJob() + gyroCaptureDispatcher)

/**
 * The Android shell of the shared gyro capture (Swift twin: OpenCineGyroApple's
 * GyroCaptureCoordinator). It owns sensors, files, preferences and the camera adapter's flows,
 * and owns no policy: take boundaries come from the logging wire, the armed session and every
 * stabilization write from the arming wire, calibration from the ring wire and mount moves from
 * the drift wire. All state changes run on the serial [scope]; sensor callbacks only enqueue.
 */
class GyroCaptureCoordinator internal constructor(
    private val host: GyroHostConfiguration,
    prefs: SharedPreferences,
    internal val native: GyroNativeApi,
    internal val sensors: GyroMotionSensors,
    internal val scope: CoroutineScope,
    internal val now: () -> Double,
    private val ingress: CoroutineContext = Dispatchers.Default,
    storeFactory: (File, GyroNativeApi) -> GyroLogStore = { root, api -> GyroLogStore(root, api) },
    private val wallClock: () -> Double = { System.currentTimeMillis() / 1_000.0 },
) {
    /**
     * Opens the host's preferences from [context]. [now] is the sensor timebase in seconds
     * (`SystemClock.elapsedRealtimeNanos`, the clock `SensorEvent.timestamp` uses).
     */
    constructor(
        context: Context,
        host: GyroHostConfiguration,
        native: GyroNativeApi = GyroNative,
        sensors: GyroMotionSensors = AndroidGyroMotionSensors(context),
        scope: CoroutineScope = gyroCaptureScope(),
        now: () -> Double = { SystemClock.elapsedRealtimeNanos() / 1e9 },
    ) : this(
        host,
        context.getSharedPreferences(host.preferencesName, Context.MODE_PRIVATE),
        native,
        sensors,
        scope,
        now,
    )

    private val nativeUsable = native !== GyroNative || GyroNative.isAvailable
    internal val preferences =
        GyroPreferences(prefs, host.keys, host.legacy.takeIf { nativeUsable }, native)
    private val mutableState = MutableStateFlow(GyroCaptureState())

    /** The current capture state; updated on the coordinator scope. */
    val state: StateFlow<GyroCaptureState> = mutableState.asStateFlow()

    // Host and camera facts.
    internal var adapter: GyroCameraAdapter? = null
    private var adapterJobs: List<Job> = emptyList()
    private var hostEligible = false
    internal var foreground = true
    private var disconnecting = false
    internal var enabled = preferences.enabled
    private var cameraId: String? = null
    private var previousRecording: Boolean? = null

    // Presentation.
    private var failed = false
    internal var notice: GyroNotice? = null
    private var logs: List<GyroLogEntry> = emptyList()
    private var tipVisible = !preferences.tipDismissed
    internal var setupSteps: List<GyroArmingStep> = emptyList()

    // Arming.
    private var armingOwner: String? = null
    private val armingMutex = Mutex()
    internal var isArmed = false
    private var stabilizationWarning = false

    // Calibration frozen into takes.
    internal var savedCalibration: String? = null
    internal var sessionUsesCalibration = true

    @Volatile private var frozenCalibration = ""

    // Logging.
    private val store: GyroLogStore? =
        if (!nativeUsable) null else runCatching { storeFactory(host.logRoot, native) }.getOrNull()
    private val storeLock = Any()
    internal var loggingOwner: String? = null
    private var tick: Job? = null
    private var gyroRunning = false
    private var hasFirstSample = false
    internal var activeTake = false
    private var gapWarning = false
    internal var mountMovedInTake = false
    private var stalled = false
    private var lastReported: Boolean? = null
    private val queueLock = Any()
    private val pending = ArrayDeque<AndroidGyroSample>()
    private val pendingObservations = ArrayDeque<RecordingObservation>()
    private var samplesOverflowed = false
    private var observationsOverflowed = false
    private var armedTimestamp: Double? = null
    private var sensorGeneration = 0L
    private var bindingGeneration = 0L

    init {
        publish()
        scope.launch {
            if (nativeUsable) {
                if (store == null) {
                    notice = GyroNotice.OPEN_FAILED
                } else {
                    try {
                        synchronized(storeLock) { store.recover() }
                    } catch (_: Exception) {
                        notice = GyroNotice.RECOVERY_INCOMPLETE
                    }
                    refreshLogs()
                }
                armingOwner = native.armingCreate(preferences.pendingRestoresJSON)
            }
            publish()
        }
    }

    /** Saves the toggle and re-evaluates the session; turning on again retries after a failure. */
    fun setEnabled(enabled: Boolean) {
        preferences.enabled = enabled
        scope.launch {
            this@GyroCaptureCoordinator.enabled = enabled
            failed = false
            reconcileArming()
            if (enabled && isArmed && loggingOwner == null) startLogging()
            publish()
        }
    }

    /** Binds the camera adapter (null when no camera integration is active). */
    fun bind(adapter: GyroCameraAdapter?) {
        scope.launch {
            if (this@GyroCaptureCoordinator.adapter === adapter) return@launch
            adapterJobs.forEach { it.cancel() }
            this@GyroCaptureCoordinator.adapter = adapter
            disconnecting = false
            val binding = synchronized(queueLock) {
                pendingObservations.clear()
                ++bindingGeneration
            }
            adapterJobs =
                if (adapter == null) {
                    emptyList()
                } else {
                    listOf(
                        // Never file IO: a REC change is stamped before the serial writer runs.
                        scope.launch(ingress) {
                            adapter.recording.collect { enqueueObservation(it, binding) }
                        },
                        scope.launch {
                            merge(
                                adapter.identity.map {},
                                adapter.recording.map {},
                                adapter.videoMode.map {},
                                adapter.stabilization.map {},
                            ).collect {
                                if (this@GyroCaptureCoordinator.adapter === adapter) onCameraChanged()
                            }
                        },
                        scope.launch {
                            adapter.level.collect {
                                if (this@GyroCaptureCoordinator.adapter === adapter) onLevel(it)
                            }
                        },
                    )
                }
            onCameraChanged()
        }
    }

    /** Monitor showing, app in front, and no multicam or relay. */
    fun setHostEligible(eligible: Boolean) {
        scope.launch {
            hostEligible = eligible
            reconcileArming()
            publish()
        }
    }

    /** False ends the session as backgrounded and invalidates a running calibration. */
    fun setForeground(active: Boolean) {
        scope.launch {
            foreground = active
            if (!active) onConnectionEnded()
            reconcileArming()
            publish()
        }
    }

    /**
     * Ends the armed session while the camera is still connected and waits for the restore
     * write, at most 3 s. Call before a clean disconnect.
     */
    suspend fun prepareForDisconnect() {
        val job = scope.launch {
            disconnecting = true
            reconcileArming()
            publish()
        }
        withTimeoutOrNull(3_000) { job.join() }
    }

    /** Setup sheet: turn stabilization off for this session. */
    fun setupTurnOffStabilization() = setupChoice { native.armingChooseTurnOff(it) }

    /** Setup sheet: keep stabilization on; the pill carries the warning mark. */
    fun setupKeepStabilization() = setupChoice { native.armingChooseKeepOn(it) }

    /** Setup sheet: skip calibration; this session logs uncalibrated takes. */
    fun setupSkipCalibration() {
        scope.launch {
            dropSetupStep<GyroArmingStep.Calibration>()
            sessionUsesCalibration = false
            refreshCalibration()
            publish()
        }
    }

    /** Deletes one finished take. */
    fun delete(entry: GyroLogEntry) {
        scope.launch {
            try {
                synchronized(storeLock) { requireNotNull(store).delete(entry) }
            } catch (_: Exception) {
                notice = GyroNotice.DELETE_FAILED
            }
            refreshLogs()
            publish()
        }
    }

    /** The finished files for [ids] in order; empty with a notice when any cannot be shared. */
    fun shareFiles(ids: List<String>): List<File> =
        try {
            synchronized(storeLock) { requireNotNull(store).shareFiles(ids) }
        } catch (_: Exception) {
            scope.launch {
                notice = GyroNotice.SHARE_FAILED
                publish()
            }
            emptyList()
        }

    /** Hides the logs tip for good. */
    fun dismissTip() {
        preferences.tipDismissed = true
        scope.launch {
            tipVisible = false
            publish()
        }
    }

    /** Clears the current notice. */
    fun clearNotice() {
        scope.launch {
            notice = null
            publish()
        }
    }

    /** Ends capture as backgrounded, releases every owner and cancels the scope. */
    fun close() {
        scope.launch {
            try {
                closeExtras()
                stopLogging("backgrounded")
                synchronized(storeLock) { store?.close() }
                armingOwner?.let(native::armingClose)
                armingOwner = null
            } finally {
                scope.cancel()
            }
        }
    }

    // Arming

    private fun setupChoice(choose: (String) -> String?) {
        scope.launch {
            dropSetupStep<GyroArmingStep.Stabilization>()
            publish()
            val owner = armingOwner ?: return@launch
            guarded { armingMutex.withLock { applyArming(owner, choose(owner)) } }
            publish()
        }
    }

    internal inline fun <reified T : GyroArmingStep> dropSetupStep() {
        setupSteps = setupSteps.filterNot { it is T }
    }

    internal suspend fun reconcileArming() {
        val owner = armingOwner ?: return
        guarded {
            armingMutex.withLock {
                applyArming(owner, native.armingUpdate(owner, encodeArmingInputs(armingInputs())))
            }
        }
    }

    private fun armingInputs(): GyroArmingInputs {
        val adapter = adapter
        return GyroArmingInputs(
            toggleOn = enabled,
            camera = adapter?.identity?.value,
            hostEligible = hostEligible && foreground && !disconnecting,
            videoMode = adapter?.videoMode?.value,
            recording = adapter?.recording?.value,
            stabilization = adapter?.stabilization?.value,
            settings = adapter?.stabilizationSettings.orEmpty(),
            providesLevel = adapter?.providesLevel == true,
            hasSavedCalibration = savedCalibration != null,
        )
    }

    /** Applies one reply's effects strictly in order; a write's own reply is applied in place. */
    private suspend fun applyArming(owner: String, json: String?) {
        val reply = decodeArmingReply(json ?: return)
        isArmed = reply.isArmed
        stabilizationWarning = reply.stabilizationWarning
        for (effect in reply.effects) {
            when (effect) {
                is GyroArmingEffect.PersistPendingRestores ->
                    preferences.pendingRestoresJSON = effect.json
                is GyroArmingEffect.WriteStabilization -> {
                    publish()
                    val succeeded =
                        try {
                            adapter?.writeStabilization(effect.values) == true
                        } catch (error: CancellationException) {
                            throw error
                        } catch (_: Exception) {
                            false
                        }
                    applyArming(
                        owner,
                        native.armingWriteFinished(owner, effect.purpose.wire, succeeded),
                    )
                }
                is GyroArmingEffect.PresentSetup -> setupSteps = effect.steps
                GyroArmingEffect.SessionStarted -> {
                    onSessionStarted()
                    startLogging()
                }
                GyroArmingEffect.SessionEnded -> {
                    setupSteps = emptyList()
                    stopLogging(
                        when {
                            !enabled -> "disabled"
                            !foreground -> "backgrounded"
                            else -> "disconnected"
                        },
                    )
                    onSessionEnded()
                }
                is GyroArmingEffect.Notice ->
                    notice =
                        when (effect.notice) {
                            GyroArmingNotice.TURN_OFF_FAILED -> GyroNotice.TURN_OFF_FAILED
                            GyroArmingNotice.RESTORE_FAILED -> GyroNotice.RESTORE_FAILED
                        }
            }
        }
        publish()
    }

    // Camera observations

    private suspend fun onCameraChanged() {
        val adapter = adapter
        val id = adapter?.identity?.value?.id
        if (id != cameraId) {
            val previous = cameraId
            cameraId = id
            savedCalibration = id?.let(::calibrationFor)
            refreshCalibration()
            onCameraIdentityChanged(previous, id)
        }
        val recording = adapter?.recording?.value
        if (recording != previousRecording) {
            val was = previousRecording
            previousRecording = recording
            onRecordingChanged(was, recording)
        }
        reconcileArming()
        publish()
    }

    internal fun calibrationFor(cameraId: String): String? =
        if (!nativeUsable) null else runCatching { preferences.calibrationJSON(cameraId) }.getOrNull()

    /** Recomputes the calibration a REC observation freezes into the next take. */
    internal fun refreshCalibration() {
        frozenCalibration = if (sessionUsesCalibration) savedCalibration.orEmpty() else ""
    }

    // Hooks for calibration and drift (Task 4 fills them).

    private fun onSessionStarted() {
        sessionUsesCalibration = true
        refreshCalibration()
    }

    private fun onSessionEnded() = Unit

    private fun onCameraIdentityChanged(previous: String?, current: String?) = Unit

    private fun onRecordingChanged(was: Boolean?, current: Boolean?) = Unit

    private fun onConnectionEnded() = Unit

    private fun onLevel(level: GyroCameraLevel) = Unit

    private fun closeExtras() = Unit

    // Logging

    private fun startLogging() {
        if (loggingOwner != null || failed) return
        if (!nativeUsable || !sensors.hasGyroscope) return fail(GyroNotice.SENSOR_UNAVAILABLE)
        if (store == null) return fail(GyroNotice.OPEN_FAILED)
        try {
            val owner = native.loggingCreate(host.appName)
            loggingOwner = owner
            resetTakeFacts()
            stalled = false
            val generation = synchronized(queueLock) {
                armedTimestamp = now()
                pending.clear()
                pendingObservations.clear()
                samplesOverflowed = false
                observationsOverflowed = false
                ++sensorGeneration
            }
            if (!sensors.startGyro { onSample(it, generation) }) {
                native.loggingClose(owner)
                loggingOwner = null
                synchronized(queueLock) { armedTimestamp = null }
                return fail(GyroNotice.SENSOR_UNAVAILABLE)
            }
            gyroRunning = true
            applyLog(native.loggingPoll(owner, now()))
            adapter?.recording?.value?.let { recording ->
                lastReported = recording
                applyLog(
                    native.loggingObserve(
                        owner, recording, now(), wallClock(), cameraLabel(), frozenCalibration,
                    ),
                )
            }
            tick = scope.launch {
                while (isActive && loggingOwner != null) {
                    delay(100)
                    drainAndPoll()
                }
            }
        } catch (error: CancellationException) {
            throw error
        } catch (_: Exception) {
            failCapture()
        }
    }

    private fun onSample(sample: AndroidGyroSample, generation: Long) {
        synchronized(queueLock) {
            if (generation != sensorGeneration) return
            if (pending.size >= 512) {
                samplesOverflowed = true
                return
            }
            pending.addLast(sample)
        }
    }

    private fun enqueueObservation(recording: Boolean?, binding: Long) {
        val timestamp = now()
        val date = wallClock()
        synchronized(queueLock) {
            if (binding != bindingGeneration) return
            val armed = armedTimestamp ?: return
            if (timestamp < armed) return
            if (pendingObservations.size >= 64) {
                observationsOverflowed = true
                return
            }
            pendingObservations.addLast(
                RecordingObservation(recording, timestamp, date, calibrationJSON = frozenCalibration),
            )
        }
    }

    private fun drainAndPoll() {
        if (loggingOwner == null) return
        try {
            val (samples, observations) =
                synchronized(queueLock) { samplesOverflowed to observationsOverflowed }
            if (samples || observations) {
                stopLogging("bufferOverflow")
                fail(if (samples) GyroNotice.SAMPLES_LOST else GyroNotice.RECORDING_EVENTS_LOST)
                return
            }
            drain()
            loggingOwner?.let { applyLog(native.loggingPoll(it, now())) }
            synchronized(storeLock) { store?.flush((now() * 1_000).toLong()) }
            if (stalled) {
                stopLogging("sensorStalled")
                fail(GyroNotice.SENSOR_STALLED)
                return
            }
        } catch (error: CancellationException) {
            throw error
        } catch (_: Exception) {
            failCapture()
        }
        publish()
    }

    /** Interleaves queued samples with REC observations at their timestamps. */
    internal fun drain() {
        if (loggingOwner == null) return
        val (samples, observations) = synchronized(queueLock) {
            (pending.toList() to pendingObservations.toList()).also {
                pending.clear()
                pendingObservations.clear()
            }
        }
        replayGyroIngress(samples, observations, ::ingest) { observation ->
            val active = loggingOwner ?: return@replayGyroIngress
            var owner = active
            if (observation.interrupted || observation.recording == null && lastReported != null) {
                applyLog(native.loggingFinish(active, "interrupted"))
                native.loggingClose(active)
                owner = native.loggingCreate(host.appName)
                loggingOwner = owner
                applyLog(native.loggingPoll(owner, observation.timestamp))
            }
            lastReported = observation.recording
            observation.recording?.let { recording ->
                applyLog(
                    native.loggingObserve(
                        owner, recording, observation.timestamp, observation.date, cameraLabel(),
                        observation.calibrationJSON,
                    ),
                )
            }
        }
    }

    private fun ingest(samples: List<AndroidGyroSample>) {
        if (samples.isNotEmpty()) {
            loggingOwner?.let { applyLog(native.loggingIngest(it, encodeGyroBatch(samples))) }
        }
    }

    /** Applies one logging reply through the store and takes over its take facts. */
    internal fun applyLog(json: String?) {
        val reply = decodeLogReply(json ?: throw IOException("The gyro wire refused the operation."))
        if (reply.updates.any { it is GyroLogUpdate.Opened }) mountMovedInTake = false
        synchronized(storeLock) {
            (store ?: throw IOException("Gyro storage is unavailable.")).apply(reply.updates)
        }
        activeTake = reply.active
        gapWarning = reply.gapWarning
        hasFirstSample = reply.hasSamples
        if (reply.termination == "sensorStalled") stalled = true
        if (reply.updates.any { it is GyroLogUpdate.Opened || it is GyroLogUpdate.Finished }) {
            refreshLogs()
        }
    }

    private fun stopSensors() {
        tick?.cancel()
        tick = null
        synchronized(queueLock) {
            armedTimestamp = null
            ++sensorGeneration
        }
        if (gyroRunning) sensors.stopGyro()
        gyroRunning = false
    }

    private fun stopLogging(reason: String) {
        stopSensors()
        val owner = loggingOwner ?: return
        var failure = false
        try {
            val overflow = synchronized(queueLock) { samplesOverflowed || observationsOverflowed }
            if (!overflow) drain()
            loggingOwner?.let { applyLog(native.loggingFinish(it, if (overflow) "bufferOverflow" else reason)) }
        } catch (error: CancellationException) {
            throw error
        } catch (_: Exception) {
            failure = true
        }
        native.loggingClose(loggingOwner ?: owner)
        loggingOwner = null
        resetTakeFacts()
        if (failure) {
            abortStore()
            fail(GyroNotice.SAVE_FAILED)
        } else {
            synchronized(storeLock) { store?.close() }
        }
    }

    /** A write or wire failure while logging: drop file ownership and recover what is on disk. */
    private fun failCapture() {
        stopSensors()
        loggingOwner?.let(native::loggingClose)
        loggingOwner = null
        resetTakeFacts()
        abortStore()
        fail(GyroNotice.SAVE_FAILED)
    }

    private fun abortStore() {
        try {
            synchronized(storeLock) { store?.abort() }
        } catch (_: Exception) {
            notice = GyroNotice.RECOVERY_INCOMPLETE
        }
        refreshLogs()
    }

    private fun resetTakeFacts() {
        activeTake = false
        gapWarning = false
        hasFirstSample = false
        mountMovedInTake = false
        lastReported = null
    }

    private fun fail(notice: GyroNotice) {
        failed = true
        this.notice = notice
        publish()
    }

    private fun refreshLogs() {
        logs =
            try {
                synchronized(storeLock) { store?.entries() }.orEmpty()
            } catch (_: Exception) {
                notice = GyroNotice.OPEN_FAILED
                logs
            }
    }

    private fun cameraLabel(): String = adapter?.identity?.value?.name ?: "Camera"

    /** Runs [operation], keeping the app alive on a malformed wire reply. */
    internal inline fun guarded(operation: () -> Unit) {
        try {
            operation()
        } catch (error: CancellationException) {
            throw error
        } catch (_: Exception) {
            // A refused or malformed arming reply leaves the last applied state in place.
        }
    }

    /** Publishes the current facts as one [GyroCaptureState]. */
    internal fun publish() {
        val adapter = adapter
        mutableState.value =
            GyroCaptureState(
                enabled = enabled,
                available = nativeUsable && sensors.hasGyroscope,
                pill =
                    resolveGyroPill(
                        enabled = enabled,
                        failed = failed,
                        armed = isArmed,
                        motionRunning = gyroRunning,
                        hasFirstSample = hasFirstSample,
                        activeTake = activeTake,
                        cameraRecording = adapter?.recording?.value,
                        gapWarning = gapWarning,
                        mountMoved = mountMovedInTake,
                        stabilizationWarning = stabilizationWarning,
                    ),
                logs = logs,
                notice = notice,
                tipVisible = tipVisible,
                setupSteps = setupSteps,
                hasSavedCalibration = savedCalibration != null,
                isArmed = isArmed,
            )
    }
}
