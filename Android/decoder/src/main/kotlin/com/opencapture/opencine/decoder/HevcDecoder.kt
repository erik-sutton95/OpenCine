package com.opencapture.opencine.decoder

import android.media.MediaCodec
import android.media.MediaFormat
import android.os.Build
import android.os.SystemClock
import android.util.Log
import android.view.Surface
import java.nio.ByteBuffer
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import com.opencapture.opencine.media.CodecFailureAction
import com.opencapture.opencine.media.CodecFailurePolicy
import com.opencapture.opencine.media.DecoderErrorLifetime
import com.opencapture.opencine.media.DecoderErrorCall
import com.opencapture.opencine.media.DecoderErrorOrigin
import com.opencapture.opencine.media.DecoderErrorRecord
import com.opencapture.opencine.media.DecoderInputOwnership
import com.opencapture.opencine.media.DecoderRandomAccessHold
import com.opencapture.opencine.media.EncoderPresentPath
import com.opencapture.opencine.media.LiveAccessUnit
import com.opencapture.opencine.media.LiveDecoderTuning
import com.opencapture.opencine.media.LiveHevcCodec
import com.opencapture.opencine.media.LivePictureSps
import com.opencapture.opencine.media.LivePipelineCadence
import com.opencapture.opencine.media.LiveVideo
import com.opencapture.opencine.media.LiveVideoCodec
import com.opencapture.opencine.media.LiveViewPresentTiming
import com.opencapture.opencine.media.PresentedFrameClock

/** The native input boundary; its identity remains the configured codec's identity. */
internal interface HevcInputCodec {
    fun dequeueInputBuffer(waitUs: Long): Int
    fun getInputBuffer(index: Int): ByteBuffer?
    fun queueInputBuffer(index: Int, size: Int, ptsUs: Long, flags: Int)
    fun failure(error: Exception): HevcInputFailure?
}

internal data class HevcInputFailure(val errorCode: Int, val isTransient: Boolean, val isRecoverable: Boolean)

private class NativeHevcInputCodec(private val native: MediaCodec) : HevcInputCodec {
    override fun dequeueInputBuffer(waitUs: Long) = native.dequeueInputBuffer(waitUs)
    override fun getInputBuffer(index: Int) = native.getInputBuffer(index)
    override fun queueInputBuffer(index: Int, size: Int, ptsUs: Long, flags: Int) =
        native.queueInputBuffer(index, 0, size, ptsUs, flags)
    override fun failure(error: Exception) = (error as? MediaCodec.CodecException)?.let {
        HevcInputFailure(it.errorCode, it.isTransient, it.isRecoverable)
    }
}

/**
 * Best-effort live-view decode via MediaCodec. Access units arrive as Annex-B (the integration
 * strips any vendor marker first). HEVC and AVC; OpenCineMedia `LiveVideo` and `LiveAccessUnit`
 * classify both. [errorJournal] receives each journalable decoder error (first per generation and
 * repeats past the lifetime limit); the app routes it to its diagnostics.
 */
class HevcDecoder(
    private val cadence: LivePipelineCadence = LivePipelineCadence(),
    private val lock: Any = Any(),
    private val errorJournal: (DecoderErrorRecord) -> Unit = {},
) {
    private val inputOwnership = DecoderInputOwnership(lock)
    @Volatile private var codec: MediaCodec? = null
    private var inputCodec: HevcInputCodec? = null
    private val inputErrors = ArrayList<DecoderErrorRecord>()
    private var inputElapsedMs: () -> Long = { SystemClock.elapsedRealtime() }
    private var inputElapsedNanos: () -> Long = { SystemClock.elapsedRealtimeNanos() }

    /** SIMULATED native boundary for queue/feed lifetime regressions, never a product codec. */
    internal fun adoptInputCodecForTest(input: HevcInputCodec) = synchronized(lock) {
        check(codec == null)
        inputCodec = input
        configured = true
        liveCodec = LiveVideoCodec.HEVC
        decodeLogLeft = 0
        inputElapsedMs = { 1L }
        inputElapsedNanos = { 1_000_000L }
    }
    private var surface: Surface? = null
    private var configured = false
    private var liveCodec: LiveVideoCodec? = null
    private var outputThread: Thread? = null
    private var pendingCsd: ByteArray? = null
    private var pendingTypes: String = ""
    private var pendingIdr: ByteArray? = null
    private var ptsUs = 0L
    private var decodeLogLeft = 6
    @Volatile private var running = false
    @Volatile var hasFormat = false
        private set
    val randomAccess = DecoderRandomAccessHold()
    val awaitingIdr: Boolean get() = randomAccess.awaitingIdr
    val isConfigured: Boolean get() = configured
    val hasDecodableReferences: Boolean get() = randomAccess.hasDecodableReferences
    val referenceRecoveryNeeded: Boolean get() = synchronized(lock) { randomAccess.referenceRecoveryNeeded }
    var nalTypesSeen = ""
        private set
    var lastKeyframeAt: Long? = null
        private set
    /** ElapsedRealtime of the last presented picture. Watchdog stall signal. */
    private val presentedClock = PresentedFrameClock()
    val lastPresentedAt: Long? get() = presentedClock.lastPresentedAt
    /** Native MediaCodec output callback clock, not GLES present. */
    @Volatile var lastDecoderOutputAt: Long? = null
        private set
    /** Successful synchronous MediaCodec input admission, before any output callback. */
    @Volatile var lastDecoderAcceptedAt: Long? = null
        private set
    /** Last accepted IRAP. Tells the watchdog an enable was already answered. */
    @Volatile var lastIrapAt: Long? = null
        private set

    private fun acceptIrap() {
        randomAccess.onIrapAccepted()
        lastIrapAt = SystemClock.elapsedRealtime()
    }
    @Volatile private var hasSeenNativeOutput = false
    val decoderOutputExpected: Boolean get() = hasSeenNativeOutput
    val isPresentationReady: Boolean
        get() = surface?.isValid == true
    private val _hasPicture = MutableStateFlow(false)
    val hasPicture: StateFlow<Boolean> = _hasPicture.asStateFlow()
    val decoderErrors = AtomicInteger(0)
    val errorLifetime = DecoderErrorLifetime()
    val failedThisGeneration: Boolean get() = errorLifetime.failedThisGeneration
    val framesEnqueued = AtomicInteger(0)
    val framesPresented = AtomicInteger(0)
    @Volatile var pictureWidth = LIVE_WIDTH
        private set
    @Volatile var pictureHeight = LIVE_HEIGHT
        private set
    private val _isVerticalPicture = MutableStateFlow(false)
    val isVerticalPicture: StateFlow<Boolean> = _isVerticalPicture.asStateFlow()
    val pictureAspect: Double
        get() =
            EncoderPresentPath.feedAspect(
                pictureWidth,
                pictureHeight,
                fallback = if (_isVerticalPicture.value) 9.0 / 16.0 else 16.0 / 9.0,
            )
    /** Pocket screen flip: request a new GOP when this AU did not already carry the IDR. */
    var onParameterSetsChanged: (() -> Unit)? = null
    /** Coded raster changed: recreate the ImageReader / OES buffer. */
    var onOutputSizeChanged: ((Int, Int) -> Unit)? = null
    private var builtCsd: ByteArray? = null
    private var pendingParameterChangeEnable = false
    private var configuredWidth = 0
    private var configuredHeight = 0

    /** TextureView / GLES presented a frame. C2 surface output may never
     *  surface through [dequeueOutputBuffer], which left WAITING FOR LIVE VIEW up. */
    /** Keep codec/Surface alive, but require an image produced after foreground. */
    fun beginPresentationProbe(): Long =
        presentedClock.beginProbe(System.nanoTime(), SystemClock.elapsedRealtime())

    fun notePresented(sourceTimestampNs: Long) {
        if (!presentedClock.note(sourceTimestampNs, SystemClock.elapsedRealtime())) return
        cadence.notePresented(sourceTimestampNs)
        // releaseOutputBuffer stamps the buffer with System.nanoTime(); every
        // present path (Vulkan ImageReader, GLES OES, raw TextureView) hands
        // that same stamp back. This is decoder-out to *submitted for display*:
        // the call lands as soon as the submit returns, so GPU execution, the
        // compositor and scanout are all still ahead of it.
        cadence.noteTransit(LivePipelineCadence.Leg.PRESENT, System.nanoTime() - sourceTimestampNs)
        framesPresented.incrementAndGet()
        if (!_hasPicture.value) {
            _hasPicture.value = true
            Log.i(TAG, "presented first picture")
        }
    }

    fun attachSurface(next: Surface?) {
        val errors = synchronized(lock) {
            attachSurfaceLocked(next)
            takeInputErrorsLocked()
        }
        errors.forEach(errorJournal)
    }

    private fun attachSurfaceLocked(next: Surface?) {
        if (next == null) {
            // Drop the producer without releasing the codec: LiveViewScreen
            // unmounts the ImageReader while PocketCameraSession still owns
            // HEVC. Leaving the dead Surface bound wedged MediaCodec so the
            // next connect sat on WAITING FOR LIVE VIEW until process death.
            surface = null
            return
        }
        if (surface === next) {
            if (!configured) {
                val csd = pendingCsd ?: return
                if (configure(csd, pendingTypes)) {
                    pendingIdr?.let { au ->
                        queuePictureLocked(au, keyframe = true, irap = true)
                    }
                }
            }
            return
        }
        surface = next
        if (configured) {
            val decoder = codec
            if (decoder != null) {
                val swapped = runCatching { decoder.setOutputSurface(next) }
                if (swapped.isSuccess) return
                Log.w(TAG, "setOutputSurface failed; rebuild decoder", swapped.exceptionOrNull())
                releaseCodecLocked()
                configured = false
            }
        }
        val csd = pendingCsd ?: return
        if (configure(csd, pendingTypes)) {
            pendingIdr?.let { au ->
                queuePictureLocked(au, keyframe = true, irap = true)
            }
        }
    }

    /** Drop [expected] only if it is still the output; a newer host may already own the decoder. */
    fun detachSurface(expected: Surface) {
        synchronized(lock) { if (surface === expected) surface = null }
    }

    fun claimInputOwner(): Long = inputOwnership.claim()

    fun advanceInputEpoch(inputOwner: Long, epoch: Long) = inputOwnership.advance(inputOwner, epoch)

    fun captureInputOwnership(): DecoderInputOwnership.Token = inputOwnership.capture()

    fun decode(accessUnit: ByteArray): Boolean = decodeInput(accessUnit, null, 0)

    fun decode(accessUnit: ByteArray, inputOwner: Long, epoch: Long): Boolean =
        decodeInput(accessUnit, inputOwner, epoch)

    private fun decodeInput(accessUnit: ByteArray, inputOwner: Long?, epoch: Long): Boolean {
        var size: Pair<Int, Int>? = null
        var requestEnable = false
        var input: DecoderInputOwnership.Token? = null
        var errors: List<DecoderErrorRecord> = emptyList()
        val mutation = {
            input = inputOwnership.capture()
            val result = decodeLocked(accessUnit)
            size = lastSizeCallback
            lastSizeCallback = null
            requestEnable = lastEnableCallback
            lastEnableCallback = false
            errors = takeInputErrorsLocked()
            result
        }
        val ok = if (inputOwner == null) synchronized(lock, mutation)
        else inputOwnership.withCurrent(inputOwner, epoch, false, mutation)
        // Recovery, retry and feed bookkeeping are complete before a host may reset/rebind.
        // Each immutable diagnostic still describes the generation that admitted the failure.
        errors.forEach(errorJournal)
        if (input == null || input != inputOwnership.capture()) return false
        size?.let { onOutputSizeChanged?.invoke(it.first, it.second) }
        if (input != inputOwnership.capture()) return false
        if (requestEnable) onParameterSetsChanged?.invoke()
        return ok && input == inputOwnership.capture()
    }

    private fun decodeLocked(accessUnit: ByteArray): Boolean {
        val types = LiveVideo.nalTypeSummary(accessUnit)
        if (types.isNotEmpty()) nalTypesSeen = mergeTypes(nalTypesSeen, types)
        val keyframe = LiveVideo.accessUnitCarriesKeyframe(accessUnit)
        if (keyframe) lastKeyframeAt = System.currentTimeMillis()
        val idr = LiveAccessUnit.isIdrPicture(types, accessUnit)
        val csd = LiveVideo.parameterSetAnnexB(accessUnit)
        var sizeCallback: Pair<Int, Int>? = null
        // `parameterSetAnnexB` hands back a blob for every access unit, not only parameter-set-bearing ones:
        // a 16 KB P-frame comes back carrying no VPS/SPS/PPS at all. Taking that as the new
        // baseline made the comparison alternate 30 bytes <-> 0 bytes and report a change on
        // every access unit, so a Nano rebuilt its decoder once a second, on every IDR, to the
        // same 1280x720. An access unit with no parameter sets cannot signal a parameter-set
        // change, and must not become the baseline the next keyframe is compared against.
        val nextSets = csd?.let { LiveAccessUnit.parameterSetNals(it) } ?: ByteArray(0)
        if (csd != null && nextSets.isNotEmpty() && LiveAccessUnit.detectCodec(csd, types) != null) {
            val changing =
                EncoderPresentPath.parameterSetsChanged(
                    hadFormat = configured || builtCsd != null,
                    previousCsd = builtCsd?.let { LiveAccessUnit.parameterSetNals(it) },
                    nextCsd = nextSets,
                )
            pendingCsd = csd
            pendingTypes = types
            adoptPictureSizeLocked(csd, types)?.let { parsed ->
                if (changing || parsed.first != configuredWidth || parsed.second != configuredHeight) {
                    sizeCallback = parsed
                }
            }
            val sizeChanged =
                configuredWidth > 1 &&
                    configuredHeight > 1 &&
                    (pictureWidth != configuredWidth || pictureHeight != configuredHeight)
            if (changing &&
                EncoderPresentPath.shouldRebuildDecoderAfterParameterChange(
                    pictureSizeChanged = sizeChanged,
                    accessUnitHasIDR = idr,
                )
            ) {
                handleEncoderFormatChangeLocked(idr, sizeChanged)
            } else if (changing) {
                builtCsd = csd
            }
            if (sizeCallback != null &&
                (pictureWidth != configuredWidth || pictureHeight != configuredHeight)
            ) {
                surface = null
            }
            lastSizeCallback = sizeCallback
        }
        if (idr) pendingIdr = accessUnit.copyOf()
        val notable =
            idr ||
                types.split(',').mapNotNull { it.trim().toIntOrNull() }.any {
                    it in 16..21 || it in 32..34 || it == 7
                }
        if (decodeLogLeft > 0 || notable) {
            if (decodeLogLeft > 0) decodeLogLeft -= 1
            Log.i(
                TAG,
                "au nals=$types idr=$idr await=$awaitingIdr cfg=$configured bytes=${accessUnit.size}",
            )
        }
        if (pendingParameterChangeEnable) {
            pendingParameterChangeEnable = false
            // New parameter sets with no IDR in this access unit: ask the host for a new GOP
            // through [onParameterSetsChanged] (the DJI session then applies its own UDP and
            // enable-age checks before it re-enables).
            lastEnableCallback = !idr
        }
        if (!configured) {
            val haveCsd = pendingCsd ?: return false
            val target = surface
            if (target == null || !target.isValid) return false
            if (!configure(haveCsd, pendingTypes.ifEmpty { types })) return false
            Log.i(TAG, "configured ${liveCodec?.name} nals=$nalTypesSeen")
            val idrAu = pendingIdr ?: if (idr) accessUnit else null
            if (idrAu != null) {
                return queuePictureLocked(idrAu, keyframe = true, irap = true)
            }
            return true
        }
        if (!randomAccess.shouldAccept(idr)) return false
        return queuePictureLocked(accessUnit, keyframe, irap = idr, holdOnMiss = true)
    }

    private var lastSizeCallback: Pair<Int, Int>? = null
    private var lastEnableCallback = false

    private fun adoptPictureSizeLocked(csd: ByteArray, types: String): Pair<Int, Int>? {
        val codecKind = LiveAccessUnit.detectCodec(csd, types) ?: return null
        val parsed = LivePictureSps.size(csd, codecKind) ?: return null
        pictureWidth = parsed.width
        pictureHeight = parsed.height
        _isVerticalPicture.value = EncoderPresentPath.isVertical(parsed.width, parsed.height)
        return parsed.width to parsed.height
    }

    /**
     * Pocket screen flip / vertical mode restarts the camera encoder. The old
     * MediaCodec session cannot decode the new GOP.
     */
    private fun handleEncoderFormatChangeLocked(auHasIdr: Boolean, pictureSizeChanged: Boolean) {
        Log.i(TAG, "feed: encoder parameter sets changed ${pictureWidth}x$pictureHeight")
        releaseCodecLocked()
        configured = false
        builtCsd = pendingCsd
        errorLifetime.resetLifetime()
        decoderErrors.set(0)
        pendingIdr = null
        pendingParameterChangeEnable = !auHasIdr
        if (EncoderPresentPath.shouldBeginIDRHoldAfterParameterChange(
                pictureSizeChanged = pictureSizeChanged,
                accessUnitHasIDR = auHasIdr,
            )
        ) {
            randomAccess.beginHold()
        }
    }

    private fun releaseCodecLocked() {
        running = false
        val out = outputThread
        outputThread = null
        val decoder = codec
        codec = null
        inputCodec = null
        runCatching { decoder?.stop() }
        // A codec failure caught on the output thread retires the codec from that thread.
        if (out !== Thread.currentThread()) {
            out?.interrupt()
            runCatching { out?.join(400) }
        }
        runCatching { decoder?.release() }
    }

    /** After a GOP-reset enable, ignore P-frames until the next IDR. Keeps the last picture. */
    fun beginIDRHold() {
        synchronized(lock) { randomAccess.beginHold() }
    }

    /**
     * UDP is alive and this codec already has valid references: do not wait
     * forever for an IRAP that a PLI did not cut. A new decoder without
     * random access keeps the hold.
     */
    fun endIDRHold(): Boolean = synchronized(lock) { randomAccess.endHold() }

    /** Depacketizer dropped a reference AU. Do not keep feeding dependent P-frames. */
    fun noteReferenceDiscontinuity() {
        synchronized(lock) { randomAccess.noteBrokenReferences() }
    }

    fun noteReferenceDiscontinuity(inputOwner: Long, epoch: Long) {
        inputOwnership.withCurrent(inputOwner, epoch, Unit) { randomAccess.noteBrokenReferences() }
    }

    /**
     * Watchdog decoder repair. Keeps the last picture. Requires an IRAP on the
     * replacement codec. Does not send enable.
     */
    fun rebuildPresentation(): Boolean =
        synchronized(lock) {
            releaseCodecLocked()
            configured = false
            pendingIdr = null
            randomAccess.onNewDecoder()
            errorLifetime.resetLifetime()
            decoderErrors.set(0)
            surface?.isValid == true
        }

    /** Recheck a queued loss repair atomically with codec mutation: a delivered
     * IRAP may already have restored references since the watchdog snapshot. */
    fun rebuildPresentationIfNeeded(
        referenceLossOnly: Boolean,
        input: DecoderInputOwnership.Token,
    ): Boolean =
        inputOwnership.withCurrent(input.owner, input.epoch, false) {
            if (referenceLossOnly && !randomAccess.referenceRecoveryNeeded) return@withCurrent false
            rebuildPresentation()
            true
        }

    /**
     * SoftAP / codec can stall while backgrounded. Keep the last picture.
     * Do **not** begin an IDR hold here: that dropped every P-frame after
     * Control Center when `0x09/0xa8` was then skipped.
     */
    fun prepareAfterForeground() {
        // Preserve the window and its last image. A dead codec must be rebuilt;
        // replaying a cached IDR from before suspension is not recovery proof.
        synchronized(lock) {
            releaseCodecLocked()
            presentedClock.beginEpoch(System.nanoTime())
            configured = false
            pendingIdr = null
            randomAccess.reset()
        }
    }

    /** Applies [CodecFailurePolicy] to one codec exception's code and action flags. */
    internal fun onCodecFailure(errorCode: Int, isTransient: Boolean, isRecoverable: Boolean) =
        synchronized(lock) { onCodecFailureLocked(errorCode, isTransient, isRecoverable) }

    private fun onCodecFailureLocked(
        errorCode: Int,
        isTransient: Boolean,
        isRecoverable: Boolean,
    ): CodecFailureAction {
        val action = CodecFailurePolicy.action(errorCode, isTransient, isRecoverable)
        if (action == CodecFailureAction.REBUILD) {
            // Mark the loss first: a rebuild alone forgets that a picture was established,
            // and only the loss makes the watchdog ask the camera for an IRAP at once.
            randomAccess.noteBrokenReferences()
            releaseCodecLocked()
            configured = false
            pendingIdr = null
            randomAccess.onNewDecoder()
        }
        return action
    }

    private fun onCodecFailureLocked(error: Throwable): CodecFailureAction =
        (error as? MediaCodec.CodecException)?.let {
            onCodecFailureLocked(it.errorCode, it.isTransient, it.isRecoverable)
        } ?: CodecFailureAction.REPORT

    /** Drop P-frames until IDR. Do not release the codec; the last frame stays on the surface. */
    fun flushForRecovery() {
        beginIDRHold()
    }

    fun reset() {
        synchronized(lock) { resetLocked() }
    }

    private fun resetLocked() {
        inputOwnership.invalidate()
        running = false
        val out = outputThread
        outputThread = null
        configured = false
        liveCodec = null
        hasFormat = false
        builtCsd = null
        pendingParameterChangeEnable = false
        pictureWidth = LIVE_WIDTH
        pictureHeight = LIVE_HEIGHT
        _isVerticalPicture.value = false
        configuredWidth = 0
        configuredHeight = 0
        randomAccess.reset()
        errorLifetime.resetLifetime()
        nalTypesSeen = ""
        lastKeyframeAt = null
        lastDecoderOutputAt = null
        lastDecoderAcceptedAt = null
        hasSeenNativeOutput = false
        presentedClock.reset(System.nanoTime())
        _hasPicture.value = false
        pendingCsd = null
        pendingTypes = ""
        pendingIdr = null
        ptsUs = 0L
        framesEnqueued.set(0)
        framesPresented.set(0)
        decoderErrors.set(0)
        val decoder = codec
        codec = null
        inputCodec = null
        surface = null
        runCatching { decoder?.stop() }
        out?.interrupt()
        runCatching { out?.join(500) }
        runCatching { decoder?.release() }
    }

    private fun configure(csd: ByteArray, nalTypes: String): Boolean {
        if (configured && codec != null) return true
        val target = surface ?: return false
        if (!target.isValid) return false
        val detected = LiveAccessUnit.detectCodec(csd, nalTypes) ?: return false
        liveCodec = detected
        var decoder: MediaCodec? = null
        // The call in flight when the block throws, for the incident (PA-1V).
        var call = DecoderErrorCall.CONFIGURE
        return try {
            val mime =
                if (detected == LiveVideoCodec.AVC) MediaFormat.MIMETYPE_VIDEO_AVC
                else MediaFormat.MIMETYPE_VIDEO_HEVC
            fun buildFormat(lowLatency: Boolean): MediaFormat {
                val format = MediaFormat.createVideoFormat(mime, pictureWidth, pictureHeight)
                format.setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 512 * 1024)
                format.setInteger(MediaFormat.KEY_FRAME_RATE, LiveViewPresentTiming.FRAME_RATE_HINT)
                format.setInteger(MediaFormat.KEY_OPERATING_RATE, LiveViewPresentTiming.OPERATING_RATE)
                format.setInteger(MediaFormat.KEY_PRIORITY, 0)
                // The version check repeats what LiveDecoderTuning already decided
                // so lint can see the guard next to the key.
                if (lowLatency && Build.VERSION.SDK_INT >= 30) {
                    format.setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
                }
                // Do not stamp KEY_COLOR_*: Pocket VUI is unspecified (transfer=255).
                // Forcing BT.709 limited made C2 apply a matrix the bitstream did not
                // ask for (posterized shadows / colour shifts vs iOS VT).
                if (detected == LiveVideoCodec.AVC) {
                    val (sps, pps) = LiveAccessUnit.splitAvcCsd(csd)
                    format.setByteBuffer("csd-0", ByteBuffer.wrap(sps))
                    if (pps != null) format.setByteBuffer("csd-1", ByteBuffer.wrap(pps))
                } else {
                    format.setByteBuffer("csd-0", ByteBuffer.wrap(csd))
                }
                return format
            }
            call = DecoderErrorCall.CREATE_CODEC
            var created = LiveHevcCodec.createDecoder(mime)
            decoder = created
            val lowLatency = LiveDecoderTuning.lowLatencyRequested(Build.VERSION.SDK_INT)
            Log.i(
                TAG,
                "decoder ${created.name} software=${LiveHevcCodec.isSoftwareName(created.name)} " +
                    "${pictureWidth}x$pictureHeight lowLatency=$lowLatency",
            )
            try {
                call = DecoderErrorCall.CONFIGURE
                created.configure(buildFormat(lowLatency), target, null, 0)
            } catch (refusal: Exception) {
                val code = (refusal as? MediaCodec.CodecException)?.errorCode
                if (!LiveDecoderTuning.retryWithoutLowLatency(lowLatency, code)) throw refusal
                // The component has no low-latency index and said so. A codec
                // that threw out of configure is spent, so the retry takes a
                // fresh one; losing low latency beats losing the picture.
                Log.w(TAG, "decoder ${created.name} refused low latency (codec:$code); retrying without it")
                runCatching { created.release() }
                call = DecoderErrorCall.CREATE_CODEC
                created = LiveHevcCodec.createDecoder(mime)
                decoder = created
                call = DecoderErrorCall.CONFIGURE
                created.configure(buildFormat(lowLatency = false), target, null, 0)
            }
            call = DecoderErrorCall.START
            created.start()
            codec = created
            inputCodec = NativeHevcInputCodec(created)
            configured = true
            hasFormat = true
            builtCsd = pendingCsd
            configuredWidth = pictureWidth
            configuredHeight = pictureHeight
            running = true
            randomAccess.onNewDecoder()
            errorLifetime.resetLifetime()
            errorLifetime.bumpFormatGeneration()
            decoderErrors.set(0)
            val started = created
            outputThread =
                Thread(
                    {
                        val info = MediaCodec.BufferInfo()
                        while (ownsOutput(started)) {
                            val index =
                                try {
                                    started.dequeueOutputBuffer(info, 10_000)
                                } catch (error: Exception) {
                                    val action = noteOutputError(
                                        started, DecoderErrorOrigin.OUTPUT, DecoderErrorCall.DEQUEUE_OUTPUT, error,
                                    )
                                    if (action != CodecFailureAction.RETRY) break
                                    // ponytail: fixed 10 ms pause so a persisting transient
                                    // error cannot spin; a backoff if field data asks for one.
                                    runCatching { Thread.sleep(TRANSIENT_RETRY_MS) }
                                    continue
                                }
                            // Stamp before ownership admission. A stamp taken before retirement
                            // is rejected by the replacement presentation probe even if release races it.
                            val stamp = System.nanoTime()
                            if (!ownsOutput(started)) break
                            when {
                                index >= 0 -> {
                                    // The same stamp comes back through notePresented.
                                    val admitted = synchronized(lock) {
                                        if (!ownsOutput(started)) false else {
                                            cadence.noteOutput(stamp)
                                            noteDecodeTransit(info)
                                            noteNativeOutput()
                                            true
                                        }
                                    }
                                    if (!admitted) break
                                    runCatching {
                                        started.releaseOutputBuffer(index, stamp)
                                    }.onFailure { error ->
                                        noteOutputError(
                                            started, DecoderErrorOrigin.OUTPUT_RELEASE,
                                            DecoderErrorCall.RELEASE_OUTPUT, error,
                                        )
                                    }
                                    // Output to an ImageReader is not a displayed image.
                                    // Vulkan/GLES/TextureView reports the actual present.
                                    synchronized(lock) { if (ownsOutput(started)) hasFormat = true }
                                }
                                index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                                    synchronized(lock) {
                                        if (ownsOutput(started)) {
                                            hasFormat = true
                                            Log.i(TAG, "output format changed")
                                        }
                                    }
                                }
                            }
                        }
                    },
                    "opc.hevc.out",
                ).also { it.isDaemon = true; it.start() }
            true
        } catch (e: Exception) {
            runCatching { decoder?.stop() }
            runCatching { decoder?.release() }
            if (codec === decoder) {
                codec = null
                inputCodec = null
                configured = false
                liveCodec = null
            }
            noteError(DecoderErrorOrigin.CONFIGURE, call, e)
            false
        }
    }

    private fun ownsInput(started: HevcInputCodec, source: DecoderInputOwnership.Token): Boolean =
        inputCodec === started && inputOwnership.capture() == source

    /** Commit reference facts only to the codec/source that attempted this picture. */
    private fun queuePictureLocked(
        accessUnit: ByteArray, keyframe: Boolean, irap: Boolean, holdOnMiss: Boolean = false,
    ): Boolean {
        val started = inputCodec ?: return false
        val source = inputOwnership.capture()
        val queued = queue(accessUnit, keyframe)
        if (!ownsInput(started, source)) return false
        if (queued && irap) acceptIrap()
        // A dropped frame is a missing reference; only this admitted source may lose it.
        if (!queued && holdOnMiss) randomAccess.noteBrokenReferences()
        return queued
    }

    private fun queue(accessUnit: ByteArray, keyframe: Boolean, retried: Boolean = false): Boolean {
        val decoder = inputCodec ?: return false
        val source = inputOwnership.capture()
        var call = DecoderErrorCall.DEQUEUE_INPUT
        return try {
            val index = decoder.dequeueInputBuffer(LiveViewPresentTiming.inputWaitUs(keyframe))
            if (!ownsInput(decoder, source)) return false
            if (index < 0) {
                cadence.inputMiss()
                Log.w(TAG, "no input buffer (nals=$nalTypesSeen)")
                return false
            }
            call = DecoderErrorCall.GET_INPUT_BUFFER
            val buffer = decoder.getInputBuffer(index) ?: return false
            if (!ownsInput(decoder, source)) return false
            call = DecoderErrorCall.FILL_INPUT
            buffer.clear()
            buffer.put(accessUnit)
            val flags = if (keyframe) MediaCodec.BUFFER_FLAG_KEY_FRAME else 0
            val pts = LiveViewPresentTiming.ptsUs(inputElapsedNanos(), ptsUs)
            ptsUs = pts
            call = DecoderErrorCall.QUEUE_INPUT
            decoder.queueInputBuffer(index, accessUnit.size, pts, flags)
            if (!ownsInput(decoder, source)) return false
            lastDecoderAcceptedAt = inputElapsedMs()
            cadence.note(LivePipelineCadence.Stage.SUBMIT)
            framesEnqueued.incrementAndGet()
            true
        } catch (e: Exception) {
            if (!ownsInput(decoder, source)) return false
            noteError(DecoderErrorOrigin.QUEUE, call, e, inputIsIrap = keyframe)
            // Callers hold the codec lock. Only the captured codec may recover or retry.
            val action = decoder.failure(e)?.let {
                onCodecFailureLocked(it.errorCode, it.isTransient, it.isRecoverable)
            } ?: CodecFailureAction.REPORT
            action == CodecFailureAction.RETRY && !retried && ownsInput(decoder, source)
                && queue(accessUnit, keyframe, retried = true)
        }
    }

    private fun takeInputErrorsLocked(): List<DecoderErrorRecord> =
        inputErrors.toList().also { inputErrors.clear() }

    /**
     * [LiveViewPresentTiming.ptsUs] stamps the submit wall clock onto the access
     * unit, so the same clock read against the PTS coming back out is how long
     * MediaCodec held this picture. A codec-config buffer carries no picture.
     */
    private fun noteDecodeTransit(info: MediaCodec.BufferInfo) {
        if (info.presentationTimeUs <= 0L) return
        if (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0) return
        val submittedUs = info.presentationTimeUs
        val nowUs = SystemClock.elapsedRealtimeNanos() / 1_000L
        cadence.noteTransit(LivePipelineCadence.Leg.DECODE, (nowUs - submittedUs) * 1_000L)
    }

    private fun ownsOutput(started: MediaCodec): Boolean = running && codec === started

    private fun noteNativeOutput() {
        hasSeenNativeOutput = true
        lastDecoderOutputAt = SystemClock.elapsedRealtime()
    }

    private fun noteOutputError(
        started: MediaCodec,
        origin: DecoderErrorOrigin,
        call: DecoderErrorCall,
        error: Throwable,
    ): CodecFailureAction {
        val (record, action) = synchronized(lock) {
            if (!ownsOutput(started)) return CodecFailureAction.REPORT
            recordError(origin, call, error) to onCodecFailureLocked(error)
        }
        // The admitted record retains its original generation. Host callbacks do not run under
        // the codec lock and cannot mutate a replacement decoder's error lifetime.
        record?.let(errorJournal)
        return action
    }

    private fun noteError(
        origin: DecoderErrorOrigin,
        call: DecoderErrorCall,
        error: Throwable,
        inputIsIrap: Boolean? = null,
    ) {
        recordError(origin, call, error, inputIsIrap)?.let(inputErrors::add)
    }

    private fun recordError(
        origin: DecoderErrorOrigin,
        call: DecoderErrorCall,
        error: Throwable,
        inputIsIrap: Boolean? = null,
    ): DecoderErrorRecord? {
        decoderErrors.incrementAndGet()
        val now = inputElapsedMs()
        val code =
            (error as? MediaCodec.CodecException)?.let { "codec:${it.errorCode}" }
                ?: error.javaClass.simpleName
        val record =
            DecoderErrorRecord(
                origin = origin,
                code = code,
                generation = errorLifetime.generation,
                formatGeneration = errorLifetime.formatGeneration,
                codec = liveCodec?.name,
                width = pictureWidth,
                height = pictureHeight,
                inputIsIrap = inputIsIrap,
                lastOutputAgeMs = lastDecoderOutputAt?.let { now - it },
                atElapsedMs = now,
                call = call,
            )
        return errorLifetime.note(record, now)
    }

    private fun mergeTypes(existing: String, incoming: String): String {
        val set = existing.split(',').filter { it.isNotBlank() }.toMutableSet()
        set.addAll(incoming.split(',').filter { it.isNotBlank() })
        return set.sorted().joinToString(",")
    }

    companion object {
        private const val TAG = "HevcDecoder"
        private const val LIVE_WIDTH = 1280
        private const val LIVE_HEIGHT = 720
        private const val TRANSIENT_RETRY_MS = 10L
    }
}
