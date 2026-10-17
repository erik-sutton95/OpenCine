package com.opencapture.opencine.nikon

import android.util.Log

/**
 * JNI facade for the Nikon session: the PTP-IP / USB PTP session layer, media browse and
 * transfer, link health and session recovery, and camera Wi-Fi credential parsing. The natives
 * are implemented in Swift by OpenCine's OpenCineNikonAndroid target, which an app's Swift
 * Android library links and exports as `Java_com_opencapture_opencine_nikon_NikonNative_<name>`,
 * so this class name and package are part of the native contract: never rename or move them
 * (consumer-rules.pro keeps them in minified apps). Coarse boundary: strings, byte arrays and
 * primitives only.
 *
 * Every session-scoped call names its connection owner: multicam holds one native session per
 * owner, and an unknown owner answers NoSession (owner-keyed registry in Swift).
 *
 * The app calls [load] with its library name once, before any Nikon session code runs.
 */
object NikonNative {
    /** True once [load] has loaded the library that implements these natives. */
    @Volatile
    var isAvailable: Boolean = false
        private set

    /**
     * Loads the app's JNI library ([library] without `lib` and `.so`). Returns whether it is
     * loaded; a failure is logged once per call and the Nikon code degrades quietly.
     */
    @Synchronized
    fun load(library: String): Boolean {
        if (isAvailable) return true
        isAvailable =
            try {
                System.loadLibrary(library)
                true
            } catch (e: UnsatisfiedLinkError) {
                // JVM unit tests have no `.so` to load and no `android.util.Log` to log with.
                runCatching { Log.e("NikonNative", "lib$library.so did not load", e) }
                false
            }
        return isAvailable
    }

    /**
     * Derives the camera access-point SSID from a PTP friendly name
     * (`ZR_6001234` → `NIKON_ZR_01234`), or null when the name is not a ZR.
     */
    external fun deriveAccessPointSSID(cameraName: String): String?

    /**
     * Sends one ephemeral on-device OCR transcript through Swift's shared
     * `CameraWiFiScreenParser` policy. Returns `SSID<unit-separator>key` only
     * when both Nikon Connection-wizard fields validate; this bridge never
     * stores or logs recognized text. Kotlin only decodes the two-field wire
     * result and must not recreate the camera-specific correction policy.
     */
    external fun parseCameraWifiScreen(transcript: String): String?

    /**
     * Validates credentials the operator typed off the camera's Connection
     * wizard when on-device OCR is unavailable. Returns the same
     * `SSID<unit-separator>key` wire as [parseCameraWifiScreen], or null when
     * either field fails the shared contract. Callers must never log or persist
     * the arguments; the key is the camera's Wi-Fi passphrase.
     */
    external fun manualCameraWifiCredentials(ssid: String, key: String): String?

    /** Operator-facing device title for a raw PTP name (`ZR_6001234` → `Nikon ZR`). */
    external fun resolveDisplayName(rawName: String): String

    /**
     * Scores current Android link observations through `CameraLinkHealthScorer`
     * and the shared `LinkSignalBars` hysteresis filter. Optional floating
     * values use an explicit presence flag, so an unavailable transport
     * measurement is never fabricated as zero. Returns
     * `score<TAB>bars<TAB>detail`, or null for an invalid phase.
     */
    external fun linkHealthSnapshot(
        connectionOwner: Long,
        phase: Int,
        roundTripMilliseconds: Double,
        hasRoundTrip: Boolean,
        liveViewFps: Double,
        hasLiveViewFps: Boolean,
        targetLiveViewFps: Double,
        secondsSinceLastGoodFrame: Double,
        hasLastGoodFrame: Boolean,
        consecutiveBadFrames: Int,
        recentCommandFailures: Int,
        isRecoveringStream: Boolean,
        isUsbTransport: Boolean,
        resetSignalBars: Boolean,
        throughputMegabitsPerSecond: Double,
        hasThroughput: Boolean,
    ): String?

    /**
     * The shared monitor reconnect schedule from `SessionRecoveryPolicy`.
     * Returns the milliseconds to wait before the next attempt after [failures]
     * consecutive failures, or a negative value once the automatic budget is
     * spent. [jitter] is a `0.0..1.0` sample drawn by the caller so the
     * schedule stays pure. Kotlin owns no retry math of its own.
     */
    external fun sessionRetryDelayMillis(failures: Int, jitter: Double): Long

    /** The shared automatic-attempt budget, for a truthful "attempt N of M". */
    external fun sessionMaxAutomaticAttempts(): Int

    /**
     * Records one session drop in the shared drop-storm ledger. `true` means
     * automatic recovery must pause for the operator: reconnects that keep
     * succeeding and dying young are churning the body's PTP stack toward its
     * battery-pull wedge, and only a cross-run drop count can catch that.
     */
    external fun sessionNoteSessionDrop(): Boolean

    /** Drops inside the storm window, for the operator-facing count. */
    external fun sessionDropsInStormWindow(): Int

    /** Operator action (retry, disconnect, fresh connect) starts a fresh ledger. */
    external fun sessionResetDropStormGuard()

    // ── Camera session (PTP-IP protocol/session layer in the Swift core) ──
    //
    // Every session-scoped entry point takes the `connectionOwner` its
    // `SwiftCoreCameraSession` passed to [sessionConnect]. Multicam holds one
    // native session per owner; an unknown owner answers NoSession and never
    // falls back to another camera. There is no unowned "current session" call.

    /** Receives session lifecycle callbacks pushed from Swift (non-main thread). */
    interface SessionListener {
        /**
         * Progress update. [phase] is a stable machine-readable name mirroring
         * the core's `CameraConnectionPhase` (`handshaking`, `pairing`,
         * `confirmOnCamera`, `connected`); [detail] carries the pairing PIN on
         * `confirmOnCamera` and the display name on `connected`.
         */
        fun onPhase(phase: String, detail: String)

        /** Terminal success: the PTP session is open and the camera identified. */
        fun onConnected(name: String, model: String, serialNumber: String)

        /**
         * Terminal failure: [failure] is the Swift `AndroidConnectFailure` wire code (read it with
         * [CameraConnectionFailure.fromWire]) and [message] the operator-facing message.
         */
        fun onFailed(failure: Int, message: String)
    }

    /** Receives raw camera-pushed PTP events from the active event socket. */
    interface SessionEventListener {
        /**
         * One parsed PTP event. [rawEventCode] is `0..0xFFFF`,
         * [transactionId] and every [rawParameters] element are lossless
         * non-negative representations of wire UINT32 values. Unknown Nikon
         * codes remain raw rather than receiving speculative labels.
         */
        fun onEvent(rawEventCode: Int, transactionId: Long, rawParameters: LongArray)

        /**
         * The native event reader ended. `null` means normal local teardown;
         * a non-null message describes an unexpected event-channel failure.
         */
        fun onEnded(message: String?)
    }

    /** MTP BatteryLevel (0x5001); UINT8 percentage. */
    const val PROP_BATTERY_LEVEL: Int = 0x5001

    /** Nikon MovieRecProhibitionCondition (0xD0A4); 0 means recording is allowed. */
    const val PROP_MOVIE_REC_PROHIBITION: Int = 0xD0A4

    /** Bounded first readback burst after a camera session connects. */
    const val PROPERTY_REFRESH_BOOTSTRAP: Int = 0

    /** One low-rate round-robin property read. */
    const val PROPERTY_REFRESH_NEXT: Int = 1

    /** One debounced read requested by a camera `DevicePropChanged` event. */
    const val PROPERTY_REFRESH_EVENT: Int = 2

    /**
     * One fast EV-meter needle read while the tool is visible: the exposure
     * indicator only, never a round-robin monitor property.
     */
    const val PROPERTY_REFRESH_EV_INDICATOR: Int = 3

    /**
     * One fast read of the photo/video capture selector only, so the chrome
     * swaps within ~1s of the body's lever (iOS polls it off the frame loop).
     * Never advances the round-robin; the heavy set keeps its slow cadence.
     */
    const val PROPERTY_REFRESH_SELECTOR: Int = 4

    /**
     * One rotating camera-owned auto-exposure readout (working ISO / shutter /
     * iris) while P/A/S/Auto or Auto ISO owns those values. Never advances the
     * round-robin. A no-op in the core when the operator owns every exposure
     * value.
     */
    const val PROPERTY_REFRESH_AUTO_EXPOSURE: Int = 5

    /** `sessionSetRecording` completed and the camera accepted the command. */
    const val RECORDING_COMMAND_ACCEPTED: Int = 0

    /** No facade session existed for the owner when `sessionSetRecording` ran. */
    const val RECORDING_COMMAND_NO_SESSION: Int = 1

    /** Camera media owns the command channel, so recording cannot change. */
    const val RECORDING_COMMAND_MEDIA_BUSY: Int = 2

    /** The camera sent a non-OK response to the Nikon recording operation. */
    const val RECORDING_COMMAND_REJECTED: Int = 3

    /** The command channel failed before the recording operation completed. */
    const val RECORDING_COMMAND_TRANSPORT_FAILED: Int = 4

    /** `sessionApplyControl` completed and the camera accepted every write. */
    const val CONTROL_COMMAND_ACCEPTED: Int = 0

    /** No facade session existed for the owner when `sessionApplyControl` ran. */
    const val CONTROL_COMMAND_NO_SESSION: Int = 1

    /** Camera media owns the command channel, so a control cannot change. */
    const val CONTROL_COMMAND_MEDIA_BUSY: Int = 2

    /** The typed control selector or its human-readable label was unsupported. */
    const val CONTROL_COMMAND_UNSUPPORTED: Int = 3

    /** The camera sent a non-OK response to a property write. */
    const val CONTROL_COMMAND_REJECTED: Int = 4

    /** The command channel failed before every requested write completed. */
    const val CONTROL_COMMAND_TRANSPORT_FAILED: Int = 5

    /** The write response was OK, but authoritative property readback did not match. */
    const val CONTROL_COMMAND_READBACK_MISMATCH: Int = 6

    /** A focus command completed and the camera accepted its operation sequence. */
    const val FOCUS_COMMAND_ACCEPTED: Int = 0

    /** No facade session existed for the owner when the focus command ran. */
    const val FOCUS_COMMAND_NO_SESSION: Int = 1

    /** Camera media owns the command channel, so the focus point cannot change. */
    const val FOCUS_COMMAND_MEDIA_BUSY: Int = 2

    /** Authoritative camera focus dimensions, header state, or modes are unavailable. */
    const val FOCUS_COMMAND_UNAVAILABLE: Int = 3

    /** The camera sent a non-OK response to the focus operation sequence. */
    const val FOCUS_COMMAND_REJECTED: Int = 4

    /** The command channel failed before the focus operation sequence completed. */
    const val FOCUS_COMMAND_TRANSPORT_FAILED: Int = 5

    /**
     * Connects to the camera at [host] (numeric IPv4, port 15740): PTP-IP Init
     * handshake on both channels, then the Nikon sequence selected by
     * [connectionStrategy], all inside the Swift core's session layer.
     * [initiatorGuid] is the stable, exactly 16-byte identity paired to this
     * Android installation; it is never logged. Returns immediately; progress
     * and the terminal result arrive on [listener] from a background thread.
     * [connectionOwner] is an opaque, per-attempt token used only to ensure a
     * stale cancellation cannot tear down a newer session.
     */
    external fun sessionConnect(
        host: String,
        connectionOwner: Long,
        connectionStrategy: Int,
        initiatorGuid: ByteArray,
        listener: SessionListener,
    )

    /**
     * Connects over a claimed Android USB PTP interface. Kotlin supplies only
     * raw bulk/interrupt bytes through [transport]; Swift owns PTP container
     * framing, session open/pair/identify strategy, and all camera operations.
     * [connectionStrategy] uses the same stable ordinal as the Wi-Fi path;
     * USB has no PTP-IP initiator GUID.
     * Progress and the terminal result arrive on [listener] from a background
     * thread, just like [sessionConnect]. [connectionOwner] scopes later
     * teardown to this exact connection attempt.
     */
    external fun sessionConnectUsb(
        transport: UsbPtpTransport,
        host: String,
        cameraNameHint: String,
        connectionOwner: Long,
        connectionStrategy: Int,
        listener: SessionListener,
    )

    /**
     * Starts draining the connected camera's dedicated PTP-IP event channel.
     * Returns after the Swift-owned reader starts; callbacks arrive from that
     * background thread until disconnect or an event-channel failure. Call
     * once for each successful [sessionConnect].
     */
    external fun sessionStartEventStream(connectionOwner: Long, listener: SessionEventListener)

    /**
     * Reads one camera property through the owner's session, decoded by the
     * Swift core (battery → percent string, others → raw hex). Null when no
     * session is active or the camera rejected the read. Blocking; call from
     * a background dispatcher.
     */
    external fun sessionReadProperty(connectionOwner: Long, code: Int): String?

    /**
     * Latest successful serialized PTP command round-trip duration. Native
     * returns NaN before a transaction and after disconnect; callers expose
     * that sentinel as null rather than fabricating latency.
     */
    external fun sessionLatestRoundTripMilliseconds(connectionOwner: Long): Double

    /**
     * Refreshes semantic Android camera state through the Swift core and
     * returns a flat semantic record consumed by `SwiftCoreCameraSession`. [request]
     * must be one of [PROPERTY_REFRESH_BOOTSTRAP], [PROPERTY_REFRESH_NEXT],
     * [PROPERTY_REFRESH_EVENT], [PROPERTY_REFRESH_EV_INDICATOR],
     * [PROPERTY_REFRESH_SELECTOR], or [PROPERTY_REFRESH_AUTO_EXPOSURE].
     * [recording] informs the core's shared
     * low-rate poll policy. [propertyCode] is only a raw value forwarded from
     * an existing `DevicePropChanged` event; Kotlin never creates or decodes a
     * Nikon property identifier. Null is reserved for an unavailable native
     * bridge; non-null results always include a typed semantic status.
     *
     * Blocking; call from a background dispatcher.
     */
    external fun sessionRefreshPropertySnapshot(
        connectionOwner: Long,
        request: Int,
        recording: Boolean,
        propertyCode: Long,
    ): String?

    /**
     * Configures the next Android live-view run with a Swift-policy-approved
     * preview request. It writes only Nikon live-view JPEG properties and the
     * preview-pull cadence; it cannot change recording settings. Call before
     * [sessionStartLiveView] on an IO dispatcher. Returns false when no active
     * session accepts the request.
     */
    external fun sessionConfigureLiveView(
        connectionOwner: Long,
        imageSize: Int,
        compression: Int,
        frameIntervalNanoseconds: Long,
    ): Boolean

    /**
     * Starts (`true`) or stops (`false`) movie recording on [connectionOwner]'s
     * session only. The Swift facade sends Nikon `StartMovieRecInCard` / `EndMovieRec`
     * through its transaction serializer, so a live-view frame read cannot race
     * the command. Blocking; call from a background dispatcher.
     *
     * Returns one of [RECORDING_COMMAND_ACCEPTED],
     * [RECORDING_COMMAND_NO_SESSION], [RECORDING_COMMAND_MEDIA_BUSY],
     * [RECORDING_COMMAND_REJECTED], or [RECORDING_COMMAND_TRANSPORT_FAILED].
     */
    external fun sessionSetRecording(connectionOwner: Long, recording: Boolean): Int

    /**
     * Fires one still release on the owner's session (photo mode). Returns a
     * `RECORDING_COMMAND_*` result; completion lands via [sessionPollStillRelease].
     */
    external fun sessionInitiateStillCapture(connectionOwner: Long, preserveFocus: Boolean): Int

    /**
     * One readiness poll while a still release is in flight: 0 complete,
     * 1 in progress, 2 bulb/time open shutter, 3 failed, negatives for
     * session/transport faults.
     */
    external fun sessionPollStillRelease(connectionOwner: Long): Int

    /** Ends a bulb/time exposure or stops a running burst (frames kept). */
    external fun sessionTerminateStillCapture(connectionOwner: Long): Int

    /** Opens/closes the continuous-burst remote-mode bracket. */
    external fun sessionSetStillBurstBracket(connectionOwner: Long, active: Boolean): Int

    /**
     * One relative manual-focus drive with its classified outcome: 0 complete,
     * 1 end of travel, 2 amount too small, -1 no session, or
     * `0x10000 or responseCode` for a body refusal. Blocking; call from IO.
     */
    external fun sessionMFDrive(connectionOwner: Long, towardNear: Boolean, pulses: Int): Int

    /** Snapshots the card's handle sets as the instant-review diff baseline. */
    external fun sessionSeedStillReviewBaseline(connectionOwner: Long): Int

    /**
     * The just-captured JPEG/HEIF handle from the post-capture baseline diff,
     * or 0 while the card hasn't listed it yet (caller retries).
     */
    external fun sessionResolveNewestStillHandle(connectionOwner: Long): Int

    /**
     * The full captured image, streamed in chunks between live-view frames.
     * Long-running and blocking; call from IO; cancel via
     * [sessionCancelStillImage].
     */
    external fun sessionStillImage(connectionOwner: Long, handle: Int): ByteArray?

    /** Aborts an in-flight [sessionStillImage] at its next chunk boundary. */
    external fun sessionCancelStillImage(connectionOwner: Long)

    /**
     * Applies one typed camera control selection on the owner's session. [control]
     * is a stable semantic selector owned by [CameraControl]; [label] is the
     * operator-facing selection such as `"5600K"` or `"AF-C"`. Swift owns all
     * Nikon property identifiers, payload bytes, Kelvin multi-write behavior,
     * and standard-versus-extended PTP operation selection. Blocking; call
     * from a background dispatcher.
     *
     * Returns one of [CONTROL_COMMAND_ACCEPTED],
     * [CONTROL_COMMAND_NO_SESSION], [CONTROL_COMMAND_MEDIA_BUSY],
     * [CONTROL_COMMAND_UNSUPPORTED], [CONTROL_COMMAND_REJECTED], or
     * [CONTROL_COMMAND_TRANSPORT_FAILED].
     */
    external fun sessionApplyControl(connectionOwner: Long, control: Int, label: String): Int

    /**
     * Moves the AF area to semantic camera-space [x]/[y] coordinates. Swift
     * owns the Nikon operation, its two UINT32 parameters, transaction ID, and
     * PTP-IP/USB framing. Blocking; call from an IO dispatcher.
     */
    external fun sessionChangeAfArea(connectionOwner: Long, x: Int, y: Int): Int

    /**
     * Recentres the AF area from current camera headers and focus properties,
     * including the shared subject-tracking release/restore policy. Blocking;
     * call from an IO dispatcher.
     */
    external fun sessionResetFocusPoint(connectionOwner: Long): Int

    /**
     * Gracefully tears down the owner's session: best-effort `CloseSession` so
     * the camera frees its connection slot, then both sockets. Blocking
     * (bounded ~2 s); call from a background dispatcher. A running live-view
     * pump is stopped first (`EndLiveView` before `CloseSession`). The opaque
     * [connectionOwner] means an old cancelled attempt cannot disconnect a
     * newer retry. Safe when idle or when the owner is no longer active.
     */
    external fun sessionDisconnect(connectionOwner: Long)

    /** Receives live-view frames pushed from Swift (the facade's pump thread). */
    interface LiveFrameListener {
        /**
         * One live-view JPEG, freshly pulled from the camera. [timestampNanos]
         * is `CLOCK_MONOTONIC` at delivery; the same clock as
         * `System.nanoTime()`. [isRecording] is the camera-authoritative
         * record flag decoded from the same live-view header. The four dBFS
         * values are resolved by the shared Swift core from that header's
         * sound indicator; [hasAudioLevels] is false when the body omitted it.
         */
        fun onFrame(
            jpeg: ByteArray,
            timestampNanos: Long,
            isRecording: Boolean,
            leftLevelDb: Double = -60.0,
            leftPeakDb: Double = -60.0,
            rightLevelDb: Double = -60.0,
            rightPeakDb: Double = -60.0,
            hasAudioLevels: Boolean = false,
        )

        /**
         * Validity of the optional camera angles in the immediately following frame.
         * The native pump serializes this call with its frame callback. Older native
         * libraries omit it, so calibration consumers must default to unavailable.
         */
        fun onLevelValidity(hasPitch: Boolean, hasYaw: Boolean) {}

        /**
         * Additive rich live-frame callback. The Swift facade prefers this
         * descriptor when it exists, while retaining [onFrame]'s established
         * descriptor as a safe fallback for older listeners.
         *
         * Focus coordinates and virtual-horizon angles were parsed and
         * normalized by the Swift core. [focusBoxes] is a flat sequence of
         * `[centerX, centerY, width, height]`; [hasFocus] and [hasLevel]
         * distinguish unavailable camera metadata from a valid zero value.
         */
        fun onFrameWithMetadata(
            jpeg: ByteArray,
            timestampNanos: Long,
            isRecording: Boolean,
            leftLevelDb: Double,
            leftPeakDb: Double,
            rightLevelDb: Double,
            rightPeakDb: Double,
            hasAudioLevels: Boolean,
            hasFocus: Boolean,
            focusCoordinateWidth: Int,
            focusCoordinateHeight: Int,
            focusResult: Int,
            subjectDetectionActive: Boolean,
            trackingAFActive: Boolean,
            selectedBoxIndex: Int,
            focusBoxes: IntArray,
            hasLevel: Boolean,
            levelRollDegrees: Double,
            levelPitchDegrees: Double,
            levelYawDegrees: Double,
        ) {
            onFrame(
                jpeg = jpeg,
                timestampNanos = timestampNanos,
                isRecording = isRecording,
                leftLevelDb = leftLevelDb,
                leftPeakDb = leftPeakDb,
                rightLevelDb = rightLevelDb,
                rightPeakDb = rightPeakDb,
                hasAudioLevels = hasAudioLevels,
            )
        }

        /**
         * Newest additive live-frame callback. Camera timecode is decoded by
         * Swift from the same header as image/focus/level metadata. The
         * facade falls back to [onFrameWithMetadata] or [onFrame] when this
         * descriptor is absent, preserving the established JNI boundary.
         */
        fun onFrameWithFullMetadata(
            jpeg: ByteArray,
            timestampNanos: Long,
            isRecording: Boolean,
            leftLevelDb: Double,
            leftPeakDb: Double,
            rightLevelDb: Double,
            rightPeakDb: Double,
            hasAudioLevels: Boolean,
            hasFocus: Boolean,
            focusCoordinateWidth: Int,
            focusCoordinateHeight: Int,
            focusResult: Int,
            subjectDetectionActive: Boolean,
            trackingAFActive: Boolean,
            selectedBoxIndex: Int,
            focusBoxes: IntArray,
            hasLevel: Boolean,
            levelRollDegrees: Double,
            levelPitchDegrees: Double,
            levelYawDegrees: Double,
            timecodeOn: Boolean,
            timecodeHour: Int,
            timecodeMinute: Int,
            timecodeSecond: Int,
            timecodeFrame: Int,
        ) {
            onFrameWithMetadata(
                jpeg = jpeg,
                timestampNanos = timestampNanos,
                isRecording = isRecording,
                leftLevelDb = leftLevelDb,
                leftPeakDb = leftPeakDb,
                rightLevelDb = rightLevelDb,
                rightPeakDb = rightPeakDb,
                hasAudioLevels = hasAudioLevels,
                hasFocus = hasFocus,
                focusCoordinateWidth = focusCoordinateWidth,
                focusCoordinateHeight = focusCoordinateHeight,
                focusResult = focusResult,
                subjectDetectionActive = subjectDetectionActive,
                trackingAFActive = trackingAFActive,
                selectedBoxIndex = selectedBoxIndex,
                focusBoxes = focusBoxes,
                hasLevel = hasLevel,
                levelRollDegrees = levelRollDegrees,
                levelPitchDegrees = levelPitchDegrees,
                levelYawDegrees = levelYawDegrees,
            )
        }

        /**
         * Newest additive live-frame callback: full metadata plus the body
         * rotation from the live-view header (0 landscape, 1 portrait grip
         * up, 2 portrait grip down, 3 upside down; vertical mode). The
         * facade falls back to [onFrameWithFullMetadata] and older
         * descriptors when this one is absent.
         */
        fun onFrameWithRotation(
            jpeg: ByteArray,
            timestampNanos: Long,
            isRecording: Boolean,
            leftLevelDb: Double,
            leftPeakDb: Double,
            rightLevelDb: Double,
            rightPeakDb: Double,
            hasAudioLevels: Boolean,
            hasFocus: Boolean,
            focusCoordinateWidth: Int,
            focusCoordinateHeight: Int,
            focusResult: Int,
            subjectDetectionActive: Boolean,
            trackingAFActive: Boolean,
            selectedBoxIndex: Int,
            focusBoxes: IntArray,
            hasLevel: Boolean,
            levelRollDegrees: Double,
            levelPitchDegrees: Double,
            levelYawDegrees: Double,
            timecodeOn: Boolean,
            timecodeHour: Int,
            timecodeMinute: Int,
            timecodeSecond: Int,
            timecodeFrame: Int,
            rotation: Int,
        ) {
            onFrameWithFullMetadata(
                jpeg = jpeg,
                timestampNanos = timestampNanos,
                isRecording = isRecording,
                leftLevelDb = leftLevelDb,
                leftPeakDb = leftPeakDb,
                rightLevelDb = rightLevelDb,
                rightPeakDb = rightPeakDb,
                hasAudioLevels = hasAudioLevels,
                hasFocus = hasFocus,
                focusCoordinateWidth = focusCoordinateWidth,
                focusCoordinateHeight = focusCoordinateHeight,
                focusResult = focusResult,
                subjectDetectionActive = subjectDetectionActive,
                trackingAFActive = trackingAFActive,
                selectedBoxIndex = selectedBoxIndex,
                focusBoxes = focusBoxes,
                hasLevel = hasLevel,
                levelRollDegrees = levelRollDegrees,
                levelPitchDegrees = levelPitchDegrees,
                levelYawDegrees = levelYawDegrees,
                timecodeOn = timecodeOn,
                timecodeHour = timecodeHour,
                timecodeMinute = timecodeMinute,
                timecodeSecond = timecodeSecond,
                timecodeFrame = timecodeFrame,
            )
        }

        /**
         * The stream ended; stop, disconnect, a transport error, or an
         * immediately-failed start. Called exactly once per
         * [sessionStartLiveView].
         */
        fun onEnded()
    }

    /**
     * Starts live view on the owner's session (blocking `StartLiveView` +
     * readiness poll; call from a background dispatcher) and pumps JPEG
     * frames to [listener] from a Swift background thread. Backpressure is
     * latest-wins: frames are pulled one at a time, so a slow consumer skips
     * camera frames instead of queueing latency.
     */
    external fun sessionStartLiveView(connectionOwner: Long, listener: LiveFrameListener)

    /**
     * Stops the live-view pump and blocks until the camera got its
     * `EndLiveView` (never leave the body streaming; the heat-audit rule).
     * Call from a background dispatcher. Safe when idle.
     */
    external fun sessionStopLiveView(connectionOwner: Long)

    // ── Media browse (OPE-34) ──

    /**
     * Refreshes card capacity before claiming media ownership, snapshots object
     * handles across every usable camera card, and returns one versioned
     * cursor/readback record. A newer call invalidates the prior cursor before
     * taking its snapshot. Null means no session is active or the snapshot
     * failed. Blocking; call from a background dispatcher.
     */
    external fun sessionBeginMediaBrowse(connectionOwner: Long): String?

    /**
     * Advances [cursor] by at most [maxObjects] ObjectInfo transactions and
     * returns one versioned `MediaBrowsePageWire`, or null when invalidated,
     * cancelled, or failed. Blocking; call from a background dispatcher.
     */
    external fun sessionNextMediaBrowsePage(cursor: Long, maxObjects: Int): String?

    /** Cancels one opaque media cursor. Safe after its final page. */
    external fun sessionCancelMediaBrowse(cursor: Long)

    /**
     * The camera's embedded thumbnail JPEG for one object handle, or null
     * when disconnected or the object has no thumbnail. Blocking; call from
     * a background dispatcher.
     */
    external fun sessionThumbnail(connectionOwner: Long, handle: Int): ByteArray?

    /**
     * Deletes one object from the camera card; false when disconnected or the
     * body refuses (protected objects). Blocking; call from IO.
     */
    external fun sessionDeleteObject(connectionOwner: Long, handle: Int): Boolean

    /**
     * One object's camera star rating as 0–5, or -1 when unreadable (RAW
     * stills don't carry the property). Blocking; call from IO.
     */
    external fun sessionObjectRating(connectionOwner: Long, handle: Int): Int

    /**
     * Writes a 0–5 star rating and returns the camera-confirmed star count
     * after readback (`>= 0`); `-1` when the write can't be attempted or fails
     * without a response; or the NEGATED raw PTP response code (e.g. `-0x2013`
     * for a state-based Access Denied) when the body refuses, so the caller can
     * name the refusal. See `ratingWriteResult`. Blocking; call from IO.
     */
    external fun sessionSetObjectRating(connectionOwner: Long, handle: Int, stars: Int): Int

    /**
     * Releases exclusive camera-media ownership. This stops any progressive
     * transfer first, then allows monitor live view to resume. Blocking and
     * safe when idle; call from a background dispatcher.
     */
    external fun sessionExitMediaMode(connectionOwner: Long)

    /**
     * Resolves the authoritative 64-bit object size through the shared core,
     * or -1 when disconnected/rejected. Blocking; call from IO.
     */
    external fun sessionResolveMediaSize(
        connectionOwner: Long,
        handle: Int,
        reportedSize: Long,
    ): Long

    /** Receives one progressive camera-object transfer from Swift. */
    interface MediaTransferListener {
        /** The core-resolved 64-bit size before the first chunk. */
        fun onStarted(totalBytes: Long)

        /** One ordered cache write at [offset]. */
        fun onChunk(offset: Long, bytes: ByteArray): Boolean

        /** The complete object is now cached. */
        fun onCompleted(totalBytes: Long)

        /** A requested stop completed after [cachedBytes] were delivered. */
        fun onStopped(cachedBytes: Long)

        /** Terminal transfer failure with operator-facing copy from Swift. */
        fun onFailed(message: String)
    }

    /**
     * Starts the shared core's object-transfer pump. Kotlin supplies identity
     * and cache resume state only; Swift owns operation selection, 64-bit
     * offset math, and chunk policy. Blocking setup, then callbacks arrive on
     * one Swift-owned thread.
     */
    external fun sessionStartMediaTransfer(
        connectionOwner: Long,
        handle: Int,
        reportedSize: Long,
        resumeOffset: Long,
        listener: MediaTransferListener,
    )

    /** Stops and joins the active transfer. Blocking and safe when idle. */
    external fun sessionStopMediaTransfer(connectionOwner: Long)
}
