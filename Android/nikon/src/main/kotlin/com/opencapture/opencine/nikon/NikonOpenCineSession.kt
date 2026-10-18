package com.opencapture.opencine.nikon

import com.opencapture.opencine.core.Availability
import com.opencapture.opencine.core.CameraCommand
import com.opencapture.opencine.core.CameraCommandIntent
import com.opencapture.opencine.core.CameraDeviceID
import com.opencapture.opencine.core.CameraSessionID
import com.opencapture.opencine.core.CameraSnapshot
import com.opencapture.opencine.core.CapabilitySnapshot
import com.opencapture.opencine.core.CaptureMode
import com.opencapture.opencine.core.CommandFailure
import com.opencapture.opencine.core.CommandPreconditions
import com.opencapture.opencine.core.CommandReceipt
import com.opencapture.opencine.core.CommandRejection
import com.opencapture.opencine.core.CommandStage
import com.opencapture.opencine.core.ConnectionAttemptID
import com.opencapture.opencine.core.ConnectionPhase
import com.opencapture.opencine.core.ConnectionState
import com.opencapture.opencine.core.ControlAuthority
import com.opencapture.opencine.core.ControlEpoch
import com.opencapture.opencine.core.ISOValue
import com.opencapture.opencine.core.IntegrationID
import com.opencapture.opencine.core.MonotonicInstant
import com.opencapture.opencine.core.ObservedValue
import com.opencapture.opencine.core.ObservationOrigin
import com.opencapture.opencine.core.StorageVolume
import com.opencapture.opencine.core.ObservationPrecision
import com.opencapture.opencine.core.OperationID
import com.opencapture.opencine.core.Rational
import com.opencapture.opencine.core.RecordingState
import com.opencapture.opencine.core.SessionCloseReason
import com.opencapture.opencine.core.SettingAccess
import com.opencapture.opencine.core.SettingDescriptor
import com.opencapture.opencine.core.SettingDomain
import com.opencapture.opencine.core.SettingKey
import com.opencapture.opencine.core.SettingSemantics
import com.opencapture.opencine.core.SettingValue
import com.opencapture.opencine.core.TimecodeCapability
import com.opencapture.opencine.core.TimecodePrecision
import com.opencapture.opencine.core.UnavailableReason
import com.opencapture.opencine.core.WhiteBalanceValue
import com.opencapture.opencine.core.rejection
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlin.time.Duration
import kotlin.time.Duration.Companion.seconds
import com.opencapture.opencine.core.CameraSession as OpenCineCameraSession

/**
 * CORE-02 (OpenCine plan 13): the monitor's Nikon control [session] as an OpenCine
 * [OpenCineCameraSession] for movie ISO, white balance and explicit record start/stop. Same slice
 * and rules as the iOS `NikonCameraSession`.
 *
 * An adapter only. [session] keeps the one command path: its mutex-serialized writes, the Swift
 * core's encoding and its readback (`confirmAndroidControlWrites`). This class adds admission
 * against the Swift-authorized domains, receipts by [OperationID], camera-reported recording that
 * stays unknown until the camera says, and idempotent start/stop. Nothing here depends on a
 * picture source.
 */
class NikonOpenCineSession(
    private val session: CameraSession,
    private val scope: CoroutineScope,
    private val recordObservationTimeout: Duration = 5.seconds,
    /** The shared host clock (MULTI-03 F1); tests inject their own. */
    private val clock: () -> MonotonicInstant = { MonotonicInstant.now() },
    /** Owned monitor teardown. Borrowed shells release their owner instead of calling close. */
    private val onClose: (SessionCloseReason) -> Unit = {},
) : OpenCineCameraSession {
    override val id: CameraSessionID = CameraSessionID()
    private val lock = Any()
    private val attempt = ConnectionAttemptID()
    private val _snapshots =
        MutableStateFlow(
            CameraSnapshot(
                session = id,
                epoch = ControlEpoch(1),
                device = CameraDeviceID.provisional(INTEGRATION),
            ),
        )
    override val snapshots: StateFlow<CameraSnapshot> = _snapshots.asStateFlow()

    private var commandAuthorityRevision = Any()
    /** Captures source/authority publication lifetime, independent of ordinary property reports. */
    public fun captureCommandAuthority(): () -> Boolean {
        val captured = synchronized(lock) { commandAuthorityRevision }
        return { synchronized(lock) { !closed && commandAuthorityRevision === captured } }
    }
    private val receipts = HashMap<OperationID, MutableStateFlow<CommandReceipt>>()

    /** Record targets in flight: not finished, so a newer press must follow, never be skipped. */
    private val recordTargets = HashMap<OperationID, Boolean>()
    private var wasReady = false
    private var everReady = false
    private var closed = false
    private var holdsControl = true
    private val feed: Job

    init {
        refresh()
        feed =
            scope.launch {
                combine(
                    session.state, session.reportedCameraProperties, session.reportedRecording, session.liveTimecode,
                ) { _, _, _, _ -> }
                    .collect { refresh() }
            }
    }

    private fun now(): MonotonicInstant = clock()

    override suspend fun submit(command: CameraCommand): CommandReceipt = submitAdmitted(command, null)

    /** One operation's source receipt reaches the existing mutex and native first-send checks. */
    public suspend fun submit(command: CameraCommand, admission: CameraCommandAdmission): CommandReceipt =
        submitAdmitted(command, admission)

    private suspend fun submitAdmitted(command: CameraCommand, admission: CameraCommandAdmission?): CommandReceipt {
        val operation = command.operation
        val start: Boolean?
        val controlWrite: Pair<CameraControl, String>?
        synchronized(lock) {
            receipts[operation]?.let { return it.value }
            val snapshot = refreshLocked()
            receipts[operation] =
                MutableStateFlow(
                    CommandReceipt(
                        operation,
                        id,
                        command.intent,
                        confirmation =
                            snapshot.capabilities[command.intent.key]?.semantics?.confirmation
                                ?: SettingSemantics.Confirmation.READBACK,
                    ),
                )
            if (admission != null && !admission.admits(session)) {
                return transition(operation, CommandStage.Rejected(CommandRejection.AuthorityExpired))
            }
            snapshot.rejection(command, now())?.let {
                return transition(operation, CommandStage.Rejected(it))
            }
            transition(operation, CommandStage.Admitted)
            when (val intent = command.intent) {
                is CameraCommandIntent.Set -> {
                    controlWrite = writeLabel(intent.value, session.reportedCameraProperties.value)
                        ?: return transition(operation, CommandStage.Failed(CommandFailure.NOT_SENT))
                    start = null
                }
                CameraCommandIntent.StartRecording, CameraCommandIntent.StopRecording -> {
                    val target = intent == CameraCommandIntent.StartRecording
                    // Idempotent: a target the camera already reports is confirmed without a
                    // command, so a confirmed or retried press can never undo itself.
                    if (
                        recordTargets.isEmpty() &&
                        snapshot.recording.value == (if (target) RecordingState.RECORDING else RecordingState.IDLE)
                    ) {
                        return transition(operation, CommandStage.Confirmed)
                    }
                    recordTargets[operation] = target
                    controlWrite = null
                    start = target
                }
                // Not advertised, so admission already rejected it as unknown support.
                is CameraCommandIntent.FocusPoint ->
                    return transition(operation, CommandStage.Failed(CommandFailure.NOT_SENT))
            }
            transition(operation, CommandStage.Sent)
        }
        return if (controlWrite != null) {
            write(operation, controlWrite.first, controlWrite.second, admission)
        } else {
            record(operation, start == true, admission)
        }
    }

    override suspend fun outcome(operation: OperationID): CommandReceipt? {
        val receipt = synchronized(lock) { receipts[operation] } ?: return null
        return receipt.first { it.isFinished }
    }

    override fun receipt(operation: OperationID): CommandReceipt? = synchronized(lock) { receipts[operation]?.value }

    override suspend fun close(reason: SessionCloseReason): Unit = closeNow(reason)

    /** Retires this common lifetime; an optional owned teardown hook runs once. */
    override fun closeNow(reason: SessionCloseReason) {
        synchronized(lock) {
            if (closed) return
            closed = true
            for (receipt in receipts.values) {
                val stage = receipt.value.stage
                if (!receipt.value.isFinished) {
                    receipt.value =
                        receipt.value.copy(
                            stage =
                                if (stage == CommandStage.Admitted) {
                                    CommandStage.Failed(CommandFailure.NOT_SENT)
                                } else {
                                    CommandStage.OutcomeUnknown
                                },
                        )
                }
            }
            recordTargets.clear()
            val current = _snapshots.value
            _snapshots.value =
                current.copy(
                    revision = current.revision.next(),
                    connection = ConnectionState.Disconnected(reason),
                    authority = ControlAuthority.Unavailable(UnavailableReason.Link),
                )
        }
        feed.cancel()
        onClose(reason)
    }

    /** The app reports its actual relay-control ownership; it never changes camera observations. */
    fun setHoldsControl(holdsControl: Boolean) {
        synchronized(lock) {
            if (this.holdsControl == holdsControl || closed) return
            this.holdsControl = holdsControl
            refreshLocked()
        }
    }

    /** The operator acting on what the camera reports right now. */
    suspend fun request(intent: CameraCommandIntent): CommandReceipt =
        submit(CameraCommand(intent, CommandPreconditions(refresh())))

    /** The monitor's ISO or white-balance write, failing exactly like [CameraSession.applyControl]. */
    suspend fun applyControl(control: CameraControl, label: String) {
        val value = settingValue(control, label) ?: throw CameraControlException.UnsupportedSelection
        request(CameraCommandIntent.Set(value)).stage.controlFailure()?.let { throw it }
    }

    /** An explicit record start or stop, failing exactly like [CameraSession.setRecording]. */
    suspend fun setRecording(recording: Boolean) {
        val intent = if (recording) CameraCommandIntent.StartRecording else CameraCommandIntent.StopRecording
        request(intent).stage.recordingFailure()?.let { throw it }
    }

    /** Re-reads the camera facts, publishes a changed snapshot, and confirms reported records. */
    fun refresh(): CameraSnapshot = synchronized(lock) { refreshLocked() }

    private suspend fun write(
        operation: OperationID, control: CameraControl, label: String, admission: CameraCommandAdmission?,
    ): CommandReceipt {
        val stage =
            try {
                if (admission == null) session.applyControl(control, label)
                else session.applyControl(control, label, admission)
                // The Swift core read every write back before returning.
                CommandStage.Confirmed
            } catch (error: CameraControlException) {
                error.toStage()
            } catch (cancelled: CancellationException) {
                finish(operation, CommandStage.OutcomeUnknown)
                throw cancelled
            }
        return finish(operation, stage)
    }

    private suspend fun record(operation: OperationID, start: Boolean, admission: CameraCommandAdmission?): CommandReceipt {
        try {
            if (admission == null) session.setRecording(start) else session.setRecording(start, admission)
        } catch (error: CameraRecordingException) {
            return finish(operation, error.toStage())
        } catch (cancelled: CancellationException) {
            finish(operation, CommandStage.OutcomeUnknown)
            throw cancelled
        }
        synchronized(lock) {
            val receipt = receipts.getValue(operation)
            if (receipt.value.isFinished) return receipt.value
            // Accepted is not confirmed: wait for the camera to report the target.
            transition(operation, CommandStage.Accepted)
            transition(operation, CommandStage.AwaitingObservation)
            refreshLocked()
        }
        scope.launch {
            delay(recordObservationTimeout)
            synchronized(lock) {
                if (receipts[operation]?.value?.stage == CommandStage.AwaitingObservation) {
                    finishLocked(operation, CommandStage.TimedOut)
                }
            }
        }
        return synchronized(lock) { receipts.getValue(operation).value }
    }

    private fun finish(operation: OperationID, stage: CommandStage): CommandReceipt =
        synchronized(lock) { finishLocked(operation, stage) }

    private fun finishLocked(operation: OperationID, stage: CommandStage): CommandReceipt {
        recordTargets.remove(operation)
        val receipt = receipts.getValue(operation)
        // Close may have finished it already; its answer stands.
        if (receipt.value.isFinished) return receipt.value
        return transition(operation, stage)
    }

    private fun transition(operation: OperationID, stage: CommandStage): CommandReceipt {
        val receipt = receipts.getValue(operation)
        receipt.value = receipt.value.copy(stage = stage)
        return receipt.value
    }

    private fun refreshLocked(): CameraSnapshot {
        val current = _snapshots.value
        if (closed) return current
        val state = session.state.value
        val properties = session.reportedCameraProperties.value
        val reported = session.reportedRecording.value
        val at = now()
        val ready = state is CameraSessionState.Connected
        // A replacement link is a new control epoch for the same owned session.
        val epoch = if (ready && !wasReady && everReady) current.epoch.next() else current.epoch
        wasReady = ready
        everReady = everReady || ready
        val descriptors = descriptors(properties, reported)
        val timecode = timecodeCapability(properties)
        val capabilities =
            if (CapabilitySnapshot(timecodeCapability = timecode, revision = current.capabilities.revision, descriptors = descriptors) == current.capabilities) {
                current.capabilities
            } else {
                CapabilitySnapshot(timecodeCapability = timecode, revision = current.capabilities.revision.next(), descriptors = descriptors)
            }
        val serial = (state as? CameraSessionState.Connected)?.identity?.serialNumber.orEmpty()
        val photography = properties.captureSelector.equals("photo", ignoreCase = true)
        var next =
            current.copy(
                epoch = epoch,
                device = if (serial.isEmpty()) current.device else CameraDeviceID.durable(serial, INTEGRATION),
                connection =
                    when {
                        ready -> ConnectionState.Ready
                        everReady -> ConnectionState.Recovering(attempt)
                        else -> ConnectionState.Connecting(attempt, ConnectionPhase.LINK)
                    },
                authority = when {
                    !ready -> ControlAuthority.Unavailable(UnavailableReason.Link)
                    holdsControl -> ControlAuthority.Owner
                    else -> ControlAuthority.Unavailable(UnavailableReason.Authority)
                },
                capabilities = capabilities,
                // The header counter is the runtime's own observation; unknown off the link (A5-04).
                timecode = current.timecode.observe(if (ready) session.liveTimecode.value else null, at),
                mode = current.mode.observe(properties.captureSelector?.let { captureMode(photography) }, at),
                recording =
                    current.recording.observe(
                        reported?.let { if (it) RecordingState.RECORDING else RecordingState.IDLE },
                        at,
                    ),
                power =
                    current.power.copy(
                        battery =
                            current.power.battery.observe(
                                properties.batteryPercent?.let(::batteryFraction),
                                at,
                                // Nikon BatteryLevel is a five-step gauge (A5-01), not a percent.
                                BATTERY_PRECISION,
                            ),
                        exhausted = current.power.exhausted.observe(
                            properties.batteryPercent?.let { NikonCameraBatteryGauge.gauge(it).exhaustion }, at,
                        ),
                        externalPower = current.power.externalPower.observe(properties.externalPower, at),
                    ),
                exposureProgram = current.exposureProgram.observe(exposureProgram(properties.exposureMode), at),
                recordingFormat = current.recordingFormat.copy(
                    dimensions = current.recordingFormat.dimensions.observe(recordingDimensions(properties.resolution), at),
                    codec = current.recordingFormat.codec.observe(properties.codec?.trim()?.takeIf { it.isNotEmpty() }, at),
                    profile = current.recordingFormat.profile.observe(properties.tone?.trim()?.takeIf { it.isNotEmpty() }, at,
                        origin = ObservationOrigin.PROTOCOL_DERIVED),
                ),
                storage = current.storage.observe(storageVolumes(properties, current.storage.value, at), at),
                settings =
                    reportedSettings(properties, photography)
                        .mapValues { (key, value) -> current.value(key).observe(value, at) }
                        .filterValues { it.isKnown },
            )
        if (next != current) {
            if (next.session != current.session || next.epoch != current.epoch ||
                next.connection != current.connection || next.authority != current.authority) {
                commandAuthorityRevision = Any()
            }
            next = next.copy(revision = current.revision.next())
            _snapshots.value = next
        }
        for ((operation, target) in recordTargets.toMap()) {
            if (receipts[operation]?.value?.stage == CommandStage.AwaitingObservation &&
                next.recording.value == (if (target) RecordingState.RECORDING else RecordingState.IDLE)
            ) {
                finishLocked(operation, CommandStage.Confirmed)
            }
        }
        return next
    }

    companion object {
        val INTEGRATION: IntegrationID = IntegrationID("org.opencapture.nikon-ptp")

        /** The body's battery gauge steps: five bars, so a reading is never finer than a fifth. */
        val BATTERY_PRECISION: ObservationPrecision = ObservationPrecision.Quantized(1.0 / NikonCameraBatteryGauge.BAR_COUNT)

        /** The bars the body shows, as a fraction on [BATTERY_PRECISION]'s steps; no reading stays unknown. */
        fun batteryFraction(rawBatteryLevel: Int): Double? = NikonCameraBatteryGauge.gauge(rawBatteryLevel)
            .takeIf { it != NikonCameraBatteryGauge.Unknown }
            ?.let { it.filledBars.toDouble() / NikonCameraBatteryGauge.BAR_COUNT }

        /**
         * Every Z body's live-view header carries a frame-counting timecode at the movie rate the body
         * reports. Whether it runs is the observation, not the capability (Swift `timecodeCapability`).
         */
        fun timecodeCapability(properties: CameraPropertySnapshot): TimecodeCapability =
            TimecodeCapability.supported(frameRate(properties)?.let { TimecodePrecision.Frames(it) })

        /**
         * The movie rate as the screen-size token reports it, in whole frames per second. Whether a
         * body's "24p" token records 24000/1001 is unverified on hardware, so none is assumed.
         */
        private fun exposureProgram(label: String?): com.opencapture.opencine.core.CameraExposureProgram? = when (label) {
            "M" -> com.opencapture.opencine.core.CameraExposureProgram.MANUAL
            "P" -> com.opencapture.opencine.core.CameraExposureProgram.PROGRAM
            "A" -> com.opencapture.opencine.core.CameraExposureProgram.APERTURE_PRIORITY
            "S" -> com.opencapture.opencine.core.CameraExposureProgram.SHUTTER_PRIORITY
            "Auto" -> com.opencapture.opencine.core.CameraExposureProgram.AUTOMATIC
            else -> null
        }

        private fun recordingDimensions(value: String?): com.opencapture.opencine.core.CameraRecordingFormat.Dimensions? {
            val parts = value?.split('x') ?: return null
            if (parts.size != 2) return null
            val width = parts[0].toIntOrNull() ?: return null
            val height = parts[1].toIntOrNull() ?: return null
            return com.opencapture.opencine.core.CameraRecordingFormat.Dimensions.measured(width, height)
        }

        fun frameRate(properties: CameraPropertySnapshot): Rational? = properties.frameRate?.takeIf { it > 0 }?.let { Rational(it) }

        /** Movie controls offered through the common seam; stills retain their typed adapter. */
        val CONTROLS: Set<CameraControl> =
            setOf(CameraControl.ISO, CameraControl.WHITE_BALANCE, CameraControl.SHUTTER, CameraControl.IRIS)

        /**
         * Movie exposure, white balance and record, admitting exactly what the Swift core's
         * `androidControlWrites` encodes and the monitor offers:
         * - ISO: the Swift-authorized ladder, the picker ladder (offered before descriptors land),
         *   and the camera's current value (Auto can park off the ladder, e.g. 51200).
         * - White balance: advertised presets (the picker's list while none are advertised) and
         *   the documented Kelvin range in 10 K steps whenever the body offers Kelvin.
         * - Shutter/aperture: actual advertised values only, with known movie-mode admission.
         */
        fun descriptors(properties: CameraPropertySnapshot, reportedRecording: Boolean?): List<SettingDescriptor> {
            val codec = codec(properties)
            val isoLabels =
                properties.controlCapabilities.isoValues + IsoPickerPolicy.unifiedOptions +
                    listOfNotNull(properties.iso?.toString())
            val iso = isoLabels.distinct().mapNotNull { label -> settingValue(CameraControl.ISO, label) }
            val advertised = properties.controlCapabilities.whiteBalanceValues
            val kelvinOpen = advertised.isEmpty() || advertised.any(WbPickerPolicy::isKelvinLabel)
            val presets = if (advertised.isEmpty()) WbPickerPolicy.presetOptions else advertised
            val whiteBalance =
                SettingDomain(
                    choices = presets.mapNotNull { label -> settingValue(CameraControl.WHITE_BALANCE, label) },
                    range =
                        if (kelvinOpen) {
                            WbPickerPolicy.MINIMUM_KELVIN.toDouble()..WbPickerPolicy.MAXIMUM_KELVIN.toDouble()
                        } else {
                            null
                        },
                    step = if (kelvinOpen) WbPickerPolicy.FINE_STEP_KELVIN.toDouble() else null,
                )
            val isoAvailability =
                when {
                    // Photo chrome edits the stills ISO, a separate camera setting outside this slice.
                    properties.captureSelector.equals("photo", ignoreCase = true) ->
                        Availability.Unavailable(UnavailableReason.Mode)
                    !IsoPickerPolicy.allowsManualISO(codec, properties.exposureMode) ->
                        Availability.Unavailable(UnavailableReason.Mode)
                    IsoPickerPolicy.blocksISOChangeWhileRecording(codec, reportedRecording == true) ->
                        Availability.Unavailable(UnavailableReason.RecordingActive)
                    else -> Availability.Available
                }
            return listOf(
                SettingDescriptor(SettingKey.ISO, domain = SettingDomain(iso), availability = isoAvailability),
                SettingDescriptor(SettingKey.WHITE_BALANCE, domain = whiteBalance),
                SettingDescriptor(SettingKey.RECORDING),
                // The movie rate is a common read-only observation; the format picker stays native.
                SettingDescriptor(SettingKey.FRAME_RATE, access = SettingAccess.READ_ONLY),
            ) + NikonExposureSettings.descriptors(properties)
        }

        /** The common value for a monitor label, or `null` outside this slice. */
        fun settingValue(control: CameraControl, label: String): SettingValue? =
            when (control) {
                CameraControl.ISO -> label.trim().toIntOrNull()?.let { SettingValue.Iso(ISOValue.Manual(it)) }
                CameraControl.WHITE_BALANCE -> SettingValue.WhiteBalance(whiteBalance(label))
                CameraControl.SHUTTER -> NikonExposureSettings.shutter(label)
                CameraControl.IRIS -> NikonExposureSettings.aperture(label)
                else -> null
            }

        /** The control and label the Swift core takes for a common value. */
        fun writeLabel(value: SettingValue, properties: CameraPropertySnapshot? = null): Pair<CameraControl, String>? =
            when (value) {
                is SettingValue.Iso -> (value.value as? ISOValue.Manual)?.let { CameraControl.ISO to it.iso.toString() }
                is SettingValue.WhiteBalance ->
                    CameraControl.WHITE_BALANCE to
                        when (val balance = value.value) {
                            WhiteBalanceValue.Auto -> "Auto"
                            is WhiteBalanceValue.Preset -> balance.id
                            is WhiteBalanceValue.Kelvin -> "${balance.kelvin}K"
                        }
                is SettingValue.Shutter -> NikonExposureSettings.label(value, properties?.controlCapabilities?.shutterValues.orEmpty())
                    ?.let { CameraControl.SHUTTER to it }
                is SettingValue.Aperture -> NikonExposureSettings.label(value, properties?.controlCapabilities?.advertisedIrisValues.orEmpty())
                    ?.let { CameraControl.IRIS to it }
                else -> null
            }

        private fun whiteBalance(label: String): WhiteBalanceValue {
            val trimmed = label.trim()
            val kelvin = trimmed.removeSuffix("K").takeIf { it != trimmed }?.toIntOrNull()
            if (kelvin != null) return WhiteBalanceValue.Kelvin(kelvin)
            return if (trimmed == "Auto") WhiteBalanceValue.Auto else WhiteBalanceValue.Preset(trimmed)
        }

        private fun codec(properties: CameraPropertySnapshot): String =
            // The monitor's "no value" placeholder (U+2014), as in MonitorScreen.
            (properties.codecSelection ?: properties.codec)?.takeIf { it != "\u2014" }.orEmpty()

        private fun reportedSettings(
            properties: CameraPropertySnapshot,
            photography: Boolean,
        ): Map<SettingKey, SettingValue?> {
            val iso =
                when {
                    // Photo chrome reports the stills ISO, not this slice's movie ISO.
                    photography -> null
                    IsoPickerPolicy.isAutoISOActive(properties.isoAuto, codec(properties)) ->
                        SettingValue.Iso(ISOValue.Auto)
                    else -> properties.iso?.let { SettingValue.Iso(ISOValue.Manual(it.toInt())) }
                }
            val mode = properties.activeWhiteBalanceMode(photography)
            val whiteBalance =
                if (mode == "Color temp") {
                    properties.whiteBalanceKelvin?.let { SettingValue.WhiteBalance(WhiteBalanceValue.Kelvin(it)) }
                } else {
                    mode?.let { SettingValue.WhiteBalance(whiteBalance(it)) }
                }
            return mapOf(
                SettingKey.ISO to iso,
                SettingKey.WHITE_BALANCE to whiteBalance,
                SettingKey.FRAME_RATE to frameRate(properties)?.let { SettingValue.FrameRate(it) },
            ) + NikonExposureSettings.reported(properties)
        }

        private fun captureMode(photography: Boolean): CaptureMode =
            if (photography) {
                CaptureMode(CaptureMode.Role.PHOTO, "${INTEGRATION.rawValue}.photo", "Photo")
            } else {
                CaptureMode(CaptureMode.Role.VIDEO, "${INTEGRATION.rawValue}.movie", "Movie")
            }

        /** Exact bytes and a separately marked estimate; unknown format has no duration. */
        internal fun storageVolumes(
            properties: CameraPropertySnapshot, previous: List<StorageVolume>? = null, at: MonotonicInstant? = null,
        ): List<StorageVolume>? {
            val storage = properties.storage?.takeIf { it.readout != null } ?: return null
            val old = previous?.firstOrNull { it.id == "active" }
            fun <T : Any> observation(value: T?, previous: ObservedValue<T>?, origin: ObservationOrigin): ObservedValue<T> = when {
                value == null -> ObservedValue.unknown
                previous != null && previous.value == value && previous.origin == origin -> previous
                else -> ObservedValue(value, origin, at)
            }
            val minutes = if (properties.captureSelector == "video") {
                RecordDurationEstimator.estimateMinutes(properties.codec, properties.resolution, properties.frameRate, storage.freeSpaceBytes)
            } else null
            return listOf(StorageVolume(
                id = "active",
                freeBytes = observation(storage.freeSpaceBytes, old?.freeBytes, ObservationOrigin.CAMERA_REPORTED),
                totalBytes = observation(storage.totalCapacityBytes.takeIf { it > 0 }, old?.totalBytes, ObservationOrigin.CAMERA_REPORTED),
                remainingRecordingTime = observation(minutes?.let { (it.toLong() * 60).seconds }, old?.remainingRecordingTime, ObservationOrigin.ESTIMATED),
            ))
        }

        /** Keeps an unchanged observation and its timestamp; a new value is camera-reported now. */
        private fun <T : Any> ObservedValue<T>.observe(
            value: T?,
            at: MonotonicInstant,
            precision: ObservationPrecision? = null,
            origin: ObservationOrigin = ObservationOrigin.CAMERA_REPORTED,
        ): ObservedValue<T> =
            when {
                this.value == value -> this
                value == null -> ObservedValue.unknown
                else -> ObservedValue(value, origin, at, precision = precision)
            }

        private fun CameraControlException.toStage(): CommandStage =
            when (this) {
                CameraControlException.NotConnected -> CommandStage.Rejected(CommandRejection.NotConnected)
                CameraControlException.MediaBusy ->
                    CommandStage.Rejected(CommandRejection.Unavailable(UnavailableReason.Busy))
                CameraControlException.CommandRejected -> CommandStage.Rejected(CommandRejection.CameraRefused)
                CameraControlException.ReadbackMismatch -> CommandStage.Failed(CommandFailure.NOT_APPLIED)
                // The write may have reached the camera; never success.
                CameraControlException.TransportFailed -> CommandStage.OutcomeUnknown
                CameraControlException.CoreUnavailable, CameraControlException.UnsupportedSelection ->
                    CommandStage.Failed(CommandFailure.NOT_SENT)
            }

        private fun CameraRecordingException.toStage(): CommandStage =
            when (this) {
                CameraRecordingException.NotConnected -> CommandStage.Rejected(CommandRejection.NotConnected)
                CameraRecordingException.MediaBusy ->
                    CommandStage.Rejected(CommandRejection.Unavailable(UnavailableReason.Busy))
                CameraRecordingException.CommandRejected -> CommandStage.Rejected(CommandRejection.CameraRefused)
                CameraRecordingException.TransportFailed -> CommandStage.OutcomeUnknown
                CameraRecordingException.CoreUnavailable, CameraRecordingException.Unsupported ->
                    CommandStage.Failed(CommandFailure.NOT_SENT)
            }

        private fun CommandStage.controlFailure(): CameraControlException? =
            when (this) {
                is CommandStage.Rejected ->
                    when (rejection) {
                        CommandRejection.CameraRefused -> CameraControlException.CommandRejected
                        CommandRejection.NotConnected, CommandRejection.SessionClosed ->
                            CameraControlException.NotConnected
                        CommandRejection.Unavailable(UnavailableReason.Busy) -> CameraControlException.MediaBusy
                        else -> CameraControlException.UnsupportedSelection
                    }
                CommandStage.Failed(CommandFailure.NOT_APPLIED) -> CameraControlException.ReadbackMismatch
                is CommandStage.Failed -> CameraControlException.UnsupportedSelection
                CommandStage.OutcomeUnknown, CommandStage.TimedOut -> CameraControlException.TransportFailed
                else -> null
            }

        private fun CommandStage.recordingFailure(): CameraRecordingException? =
            when (this) {
                is CommandStage.Rejected ->
                    when (rejection) {
                        CommandRejection.CameraRefused -> CameraRecordingException.CommandRejected
                        CommandRejection.NotConnected, CommandRejection.SessionClosed ->
                            CameraRecordingException.NotConnected
                        CommandRejection.Unavailable(UnavailableReason.Busy) -> CameraRecordingException.MediaBusy
                        else -> CameraRecordingException.Unsupported
                    }
                is CommandStage.Failed -> CameraRecordingException.Unsupported
                CommandStage.OutcomeUnknown, CommandStage.TimedOut -> CameraRecordingException.TransportFailed
                else -> null
            }
    }
}
