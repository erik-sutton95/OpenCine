package com.opencapture.opencine.runtime

import android.content.Context
import android.graphics.ImageFormat
import android.media.Image
import android.hardware.HardwareBuffer
import android.media.ImageReader
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.os.PowerManager
import android.util.Log
import android.view.Surface
import com.opencapture.openpocketcine.feed.OpcVulkan
import com.opencapture.opencine.media.FeedEffectsRenderPlan
import com.opencapture.opencine.media.MonitorLUTCube
import com.opencapture.opencine.media.ScopeAssistBundle
import com.opencapture.opencine.media.ScopeClipProfile
import com.opencapture.opencine.media.ScopeClipSnapshot
import com.opencapture.opencine.media.ScopeExposureCeiling
import com.opencapture.opencine.media.ScopeSampler
import com.opencapture.opencine.media.ScopeSamples
import com.opencapture.opencine.media.ScopeTrafficLights
import com.opencapture.opencine.media.WaveformIre
import com.opencapture.opencine.media.LiveColorScience
import com.opencapture.opencine.media.feedEffectsCubeVk3d
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference

/**
 * Vulkan live path: MediaCodec writes an [ImageReader] AHB, the native renderer
 * imports it, grades on the GPU, and composites configured glass plates into
 * the SurfaceView swapchain. Scope samples are published as separate values. No `glReadPixels`, no `TextureView.getBitmap`.
 */
class NativeVulkanFeedSession(
    context: Context,
    private val scopeBus: ScopeSampleBus,
    private val clipProfile: ScopeClipProfile = ScopeClipProfile(),
    private val beforeFirstImport: () -> Unit = {},
    private val onImportedFrame: (Int) -> Unit = {},
    private val journal: (String, String, String) -> Unit = { _, _, _ -> },
    private val logTag: String = "OpenCineVulkan",
    private val preview: InspectorPreviewPipeline,
    private val onDecoderSurface: (Surface) -> Unit,
    private val onFirstFrame: () -> Unit,
    private val onFailed: () -> Unit,
    private val onFramePresented: (Long?) -> Unit = {},
    private val backdrop: NativeBackdropFeed? = null,
) {
    /**
     * This feed's clip ceiling; never shared with another feed or playback. The Vulkan path does
     * not observe the tap max, so it stays at table values (it no longer borrows another feed's).
     */
    private class Samples(val source: ScopeSampleBus.Source?, profile: ScopeClipProfile) {
        val ceiling = ScopeExposureCeiling(profile)
        var previous = ScopeAssistBundle.EMPTY
    }
    @Volatile private var samples = Samples(null, clipProfile)
    private val scopeHz = ScopeTapHzLog()

    private val appContext = context.applicationContext
    private val main = Handler(Looper.getMainLooper())
    private val imageThread = HandlerThread("opc.vk.img").apply { start() }
    private val imageHandler = Handler(imageThread.looper)
    private val gpuThread = HandlerThread("opc.vk.gpu").apply { start() }
    private val gpuHandler = Handler(gpuThread.looper)
    /** UI-thread inputs reach native only on [imageThread]; the UI never takes the renderer mutex. */
    private val rendererInputs = VulkanRendererInputs { imageHandler.post(it) }
    private val sampleExecutor =
        Executors.newSingleThreadExecutor { runnable ->
            Thread(runnable, "opc.vk.scope").apply { isDaemon = true }
        }
    private val sampleBusy = AtomicBoolean(false)
    private val scopeFrames = InspectorPreviewSource()
    private val scopeLifetime = ScopeSourceLifetime(scopeBus,
        ScopeSampleBus.Role.LIVE)
    @Volatile private var scopeActive = false
    private var scopeAttached = false
    private var scopeReleased = false
    @Volatile private var handle = 0L
    private var pendingAttach: Triple<Surface, Int, Int>? = null
    private val presentGate = VulkanPresentGate()
    private val slots = FloatArray(GpuLiveLayout.SLOT_STRIDE * 4)
    private val plates = AtomicReference(FloatArray(0))
    private val histo = IntArray(1024)
    private var reader: ImageReader? = null
    private val readerLifetime = NativeRenderLifetime()
    @Volatile private var readerGeneration = 0L
    private var held: Image? = null
    /** Frames presented from the current [reader]; drives the configured import guard. */
    @Volatile private var readerFrames = 0
    private val started = AtomicBoolean(false)
    val framesPresented = AtomicInteger(0)
    private val cubeSentinel = Any()
    private var lastLut: Any? = cubeSentinel
    private var lastPaint: Any? = cubeSentinel
    private var lastWeight: Any? = cubeSentinel
    @Volatile private var lastPlan: FeedEffectsRenderPlan? = null
    private val tapBytes = ByteArray(TAP_W * TAP_H * 4)
    private val faceWanted = AtomicBoolean(false)
    private val faceLock = Any()
    private val faceBytes = ByteArray(FACE_TAP_WIDTH * FACE_TAP_HEIGHT * 3 / 2)
    @Volatile private var faceValid = false
    private var lastSampleNs = 0L
    private var lastScopeWorkNs = 0L
    private var attachedSurface: Surface? = null
    val windowReady: Boolean
        get() = presentGate.windowReady

    val isReady: Boolean
        get() = handle != 0L

    private var feedW = SOURCE_W.toFloat()
    private var feedH = SOURCE_H.toFloat()
    private var sourceW = SOURCE_W
    private var sourceH = SOURCE_H

    init {
        backdrop?.attach(this)
        // Decoder surface on this thread, now. nativeCreate compiles on opc.vk.gpu
        // so ImageReader callbacks are not stuck behind feed.frag (5–10 s WAITING).
        ensureReader()
        gpuHandler.post {
            if (presentGate.isReleased) return@post
            if (!OpcVulkan.isAvailable) {
                main.post { if (!presentGate.isReleased) onFailed() }
                return@post
            }
            val created = OpcVulkan.nativeCreate()
            if (presentGate.isReleased) {
                if (created != 0L) OpcVulkan.nativeDestroy(created)
                return@post
            }
            if (created == 0L) {
                Log.w(logTag, "vulkan nativeCreate failed")
                main.post { if (!presentGate.isReleased) onFailed() }
                return@post
            }
            handle = created
            Log.i(logTag, "vulkan renderer ready")
            imageHandler.post { flushAttach() }
            rendererInputs.bind(RendererInputSink())
        }
    }

    fun attachWindow(surface: Surface, width: Int, height: Int) {
        if (presentGate.isReleased) return
        if (!VulkanWindowAttach.shouldCreateSwapchain(width, height)) {
            Log.w(logTag, "swapchain attach skipped ${width}x${height}")
            journal(
                "warning",
                "surface",
                "feed: swapchain attach skipped ${width}x${height}",
            )
            return
        }
        setScopeAttached(true)
        preview.sourceChanged(scopeLifetime.ownedSource)
        pendingAttach = Triple(surface, width, height)
        if (handle == 0L) {
            ensureReader()
            return
        }
        if (Looper.myLooper() == imageHandler.looper) {
            flushAttach()
        } else {
            imageHandler.post { flushAttach() }
        }
    }

    private fun flushAttach() {
        val pending = pendingAttach ?: return
        val native = handle
        if (native == 0L || presentGate.isReleased) return
        val (surface, width, height) = pending
        if (presentGate.windowReady && attachedSurface === surface) {
            OpcVulkan.nativeResize(native, width, height)
            redrawLast()
            presentHeld(native)
            return
        }
        ensureReader()
        val ok = OpcVulkan.nativeAttachWindow(native, surface, width, height)
        if (!ok) {
            Log.w(logTag, "swapchain attach failed ${width}x${height}")
            journal(
                "warning",
                "surface",
                "feed: swapchain attach failed ${width}x${height}",
            )
            if (VulkanWindowAttach.shouldFallbackToGlesOnAttachFailure()) main.post { if (!presentGate.isReleased) onFailed() }
            return
        }
        attachedSurface = surface
        presentGate.attach()
        journal(
            "info",
            "surface",
            "feed: swapchain attach ok ${width}x${height}",
        )
        presentHeld(native)
        redrawLast()
    }

    /**
     * Re-present the last imported AHB after overlay dismiss or a swapchain rebuild. Off the
     * renderer thread this only asks for it; [rendererInputs] presents on the renderer thread.
     */
    fun redrawLast() {
        if (Looper.myLooper() != imageHandler.looper) {
            if (!presentGate.isReleased) rendererInputs.requestRedraw()
            return
        }
        val native = handle
        if (native == 0L || presentGate.isReleased || !presentGate.windowReady) return
        if (!presentGate.beginSubmit()) return
        try {
            OpcVulkan.nativeRedraw(native)
        } finally {
            presentGate.endSubmit()
        }
    }

    fun resize(width: Int, height: Int) {
        val native = handle
        if (native == 0L || presentGate.isReleased || !presentGate.windowReady) return
        OpcVulkan.nativeResize(native, width, height)
    }

    /** Recreate the decoder AHB when the coded source raster changes. */
    fun setSourceSize(width: Int, height: Int) {
        if (width != sourceW || height != sourceH) backdrop?.invalidate(this)
        if (presentGate.isReleased) return
        val w = width.coerceAtLeast(2)
        val h = height.coerceAtLeast(2)
        if (w == sourceW && h == sourceH) {
            reader?.surface?.let { onDecoderSurface(it) }
            return
        }
        scopeFrames.invalidate()
        readerLifetime.stop()
        resetScopeSource()
        sourceW = w
        sourceH = h
        imageHandler.post {
            if (presentGate.isReleased) return@post
            held?.close()
            held = null
            reader?.close()
            reader = null
            ensureReader()
        }
    }

    @Synchronized fun configureScopeSource(identity: Any, ready: Boolean, active: Boolean) {
        if (scopeReleased) return
        val changed = scopeFrames.configure(identity, ready && active)
        if (changed || scopeActive != active) {
            scopeActive = active
            resetScopeSource()
        }
    }

    @Synchronized private fun setScopeAttached(attached: Boolean, released: Boolean = false) {
        if (scopeReleased) return
        scopeReleased = released
        val changed = scopeAttached != attached
        scopeAttached = attached
        if (attached) scopeLifetime.attach() else scopeLifetime.detach()
        if (changed || released) samples = Samples(scopeLifetime.source, clipProfile)
    }

    @Synchronized private fun resetScopeSource() {
        faceWanted.set(false)
        synchronized(faceLock) { faceValid = false }
        scopeLifetime.invalidate(scopeActive && !scopeReleased)
        samples = Samples(scopeLifetime.source, clipProfile)
        preview.sourceChanged(scopeLifetime.ownedSource)
        backdrop?.invalidate(this)
    }

    /** UI thread: stored whole and applied by the renderer thread before its next present. */
    fun setFeedRect(x: Float, y: Float, w: Float, h: Float, stretchToRect: Boolean = false) {
        if (presentGate.isReleased) return
        feedW = w
        feedH = h
        rendererInputs.offerFeedRect(VulkanRendererInputs.FeedRect(x, y, w, h, stretchToRect))
    }

    fun setPlates(packed: FloatArray) {
        plates.set(packed)
        if (!presentGate.isReleased) rendererInputs.offerPlates(packed)
    }

    /** UI thread: computes the renderer values here; the renderer thread uploads and presents them. */
    fun updateEffects(
        plan: FeedEffectsRenderPlan,
        uiScale: Float = 1f,
        pictureMirrored: Boolean = false,
        pictureFlippedVertically: Boolean = false,
        options: GlesPresentationOptions = GlesPresentationOptions(),
    ) {
        if (presentGate.isReleased) return
        backdrop?.updatePlan(this, plan)
        lastPlan = plan
        // Apply the plan's ISO report (or the profile's unreported assumption) before the IRE
        // table below reads the ceiling, so it never waits for the next scope tick.
        samples.ceiling.syncISO(plan.scopeTap.iso)
        val transfer = plan.scopeTap.transfer
        val ire = WaveformIre.levelTable(transfer, plan.scopeTap.iso, samples.ceiling)
        val luma = LiveColorScience.lumaWeights(transfer)
        val flags =
            floatArrayOf(
                plan.lutCube?.size?.toFloat() ?: 0f,
                if (plan.falseColorOn) 1f else 0f,
                if (plan.splitComparison) 1f else 0f,
                if (plan.splitVertical) 1f else 0f,
                if (plan.zebraHighlightOn) 1f else 0f,
                plan.zebraHighlightCode,
                if (plan.zebraMidtoneOn) 1f else 0f,
                plan.zebraMidtoneCode,
                plan.zebraMidtoneHalf,
                if (options.upscaler == MonitorGlesUpscaler.FAST &&
                    MonitorGlesUpscaler.shouldReconstructToDisplay(
                        SOURCE_W.toFloat(),
                        SOURCE_H.toFloat(),
                        feedW,
                        feedH,
                    )
                ) {
                    1f
                } else {
                    0f
                },
                if (pictureMirrored) 1f else 0f,
                if (pictureFlippedVertically) 1f else 0f,
                if (plan.peaking) 1f else 0f,
                plan.peakingRatioThreshold,
                plan.peakingNoiseGate,
                plan.peakingColor.getOrElse(0) { 1f },
                plan.peakingColor.getOrElse(1) { 72f / 255f },
                plan.peakingColor.getOrElse(2) { 64f / 255f },
            )
        rendererInputs.offerEffects(
            VulkanRendererInputs.Effects(
                uiScale = uiScale,
                lut = plan.lutCube,
                falseColorPaint = plan.falseColorPaint,
                falseColorWeight = plan.falseColorWeight,
                ire = ire,
                luma = floatArrayOf(luma.first.toFloat(), luma.second.toFloat(), luma.third.toFloat()),
                flags = flags,
            ),
        )
    }

    /** Renderer thread ([imageThread]): the only caller of the native setters below. */
    private inner class RendererInputSink : VulkanRendererInputSink {
        private fun native(): Long = handle.takeIf { it != 0L && !presentGate.isReleased } ?: 0L

        override fun applyFeedRect(rect: VulkanRendererInputs.FeedRect) {
            val native = native()
            if (native == 0L) return
            OpcVulkan.nativeSetFeedRect(native, rect.x, rect.y, rect.w, rect.h, rect.stretchToRect)
        }

        override fun applyPlates(plates: FloatArray) {
            val native = native()
            if (native != 0L) OpcVulkan.nativeSetPlates(native, plates)
        }

        override fun applyEffects(effects: VulkanRendererInputs.Effects) {
            val native = native()
            if (native == 0L) return
            OpcVulkan.nativeSetUiScale(native, effects.uiScale)
            uploadCube(0, effects.lut, lastLut) { lastLut = it }
            uploadCube(1, effects.falseColorPaint, lastPaint) { lastPaint = it }
            uploadCube(2, effects.falseColorWeight, lastWeight) { lastWeight = it }
            OpcVulkan.nativeSetIre(native, effects.ire, effects.luma[0], effects.luma[1], effects.luma[2], 8)
            val f = effects.flags
            OpcVulkan.nativeSetFeedFlags(
                native, f[0], f[1], f[2], f[3], f[4], f[5], f[6], f[7], f[8], f[9], f[10], f[11], f[12], f[13],
                f[14], f[15], f[16], f[17],
            )
            packScopeSlotsOff()
        }

        override fun redraw() = redrawLast()
    }

    /** Compose owns the plates; drag does not re-present the swapchain. */
    fun slotsMoved() {}

    private fun packScopeSlotsOff() {
        val native = handle
        if (native == 0L || presentGate.isReleased) return
        // Compose paints WAVE / PARADE / VECTOR. Keep GPU slots off so the
        // swapchain never fills a plot-sized plate (the inner cutout).
        for (index in 0 until 4) {
            GpuLiveLayout.packSlot(slots, index, false, 0f, 0f, 0f, 0f, 0, 0f)
        }
        OpcVulkan.nativeSetSlots(native, slots)
        OpcVulkan.nativeSetStack(native, intArrayOf())
    }

    /** Arm a 320×180 identity RGB copy for an optional source tracking consumer. */
    fun requestFaceTap() {
        if (!presentGate.isReleased) faceWanted.set(true)
    }

    /** The newest NV21 readback, once: a taken frame is never handed out again. */
    fun takeFaceNv21(): ByteArray? {
        synchronized(faceLock) {
            if (!faceValid || presentGate.isReleased) return null
            faceValid = false
            return faceBytes.copyOf()
        }
    }

    fun copyHistogram(): IntArray? {
        val native = handle
        if (native == 0L || presentGate.isReleased || readerFrames == 0 ||
            !readerLifetime.isCurrent(readerGeneration)) return null
        OpcVulkan.nativeCopyHisto(native, histo)
        return histo.copyOf()
    }

    private fun uploadCube(
        slot: Int,
        cube: MonitorLUTCube?,
        last: Any?,
        commit: (Any?) -> Unit,
    ) {
        val native = handle
        if (native == 0L || presentGate.isReleased) return
        if (cube === last) return
        if (cube == null) {
            OpcVulkan.nativeSetCube(native, slot, null, 0, 0, 0f)
        } else {
            val volume = feedEffectsCubeVk3d(cube)
            OpcVulkan.nativeSetCube(
                native,
                slot,
                volume,
                cube.size,
                cube.size,
                cube.size.toFloat(),
            )
        }
        commit(cube)
    }

    /** Must run from `surfaceDestroyed` before that callback returns. */
    fun detachWindow() {
        preview.sourceChanged(scopeLifetime.ownedSource)
        setScopeAttached(false)
        scopeFrames.invalidate()
        backdrop?.invalidate(this)
        pendingAttach = null
        presentGate.detach()
        attachedSurface = null
        val native = handle
        if (native != 0L) OpcVulkan.nativeDetachWindow(native)
        journal("info", "surface", "feed: swapchain detach")
    }

    fun release() {
        readerLifetime.stop()
        preview.sourceChanged(scopeLifetime.ownedSource)
        setScopeAttached(false, released = true)
        scopeFrames.invalidate()
        backdrop?.invalidate(this)
        presentGate.release()
        synchronized(faceLock) { faceValid = false }
        reader?.setOnImageAvailableListener(null, null)
        gpuHandler.removeCallbacksAndMessages(null)
        imageHandler.removeCallbacksAndMessages(null)
        gpuThread.quitSafely()
        imageThread.quitSafely()
        try {
            gpuThread.join()
            imageThread.join()
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
        }
        sampleExecutor.shutdown()
        held?.close()
        held = null
        reader?.close()
        reader = null
        val native = handle
        handle = 0L
        if (native != 0L) OpcVulkan.nativeDestroy(native)
    }

    @Synchronized
    private fun ensureReader() {
        if (reader != null || presentGate.isReleased) return
        val w = sourceW.coerceAtLeast(2)
        val h = sourceH.coerceAtLeast(2)
        // PRIVATE without usage requests usage 0. Vulkan requires GPU_SAMPLED_IMAGE
        // on an imported AHB; MediaTek gralloc SIGSEGVs without it (ANDROID-E).
        val next = ImageReader.newInstance(
            w, h, ImageFormat.PRIVATE, 5, HardwareBuffer.USAGE_GPU_SAMPLED_IMAGE,
        )
        reader = next
        val readerTicket = readerLifetime.start()
        readerGeneration = readerTicket
        readerFrames = 0
        next.setOnImageAvailableListener(
            { rdr ->
                if (!readerLifetime.isCurrent(readerTicket) || rdr !== reader || presentGate.isReleased)
                    return@setOnImageAvailableListener
                val image = rdr.acquireLatestImage() ?: return@setOnImageAvailableListener
                if (!readerLifetime.isCurrent(readerTicket)) {
                    image.close()
                    return@setOnImageAvailableListener
                }
                val native = handle
                if (native == 0L || !presentGate.beginSubmit()) {
                    holdImage(image)
                    return@setOnImageAvailableListener
                }
                try {
                    val sourceEpoch = scopeFrames.beginLatch()
                    scopeFrames.didLatch(sourceEpoch)
                    presentImage(native, image, sourceEpoch)
                } finally {
                    presentGate.endSubmit()
                }
            },
            imageHandler,
        )
        if (readerLifetime.isCurrent(readerTicket) && !presentGate.isReleased) onDecoderSurface(next.surface)
        Log.i(logTag, "decoder ImageReader ${sourceW}x$sourceH")
    }

    private fun holdImage(image: Image) {
        held?.close()
        held = image
    }

    private fun presentHeld(native: Long) {
        val image = held ?: return
        held = null
        if (!presentGate.beginSubmit()) {
            holdImage(image)
            return
        }
        try {
            presentImage(native, image)
        } finally {
            presentGate.endSubmit()
        }
    }

    private fun presentImage(native: Long, image: Image, sourceEpoch: Long? = null) {
        val readerTicket = readerGeneration
        if (!readerLifetime.isCurrent(readerTicket)) {
            image.close()
            return
        }
        val hb = image.hardwareBuffer
        if (hb == null) {
            image.close()
            main.post { if (readerLifetime.isCurrent(readerTicket) && !presentGate.isReleased) onFailed() }
            return
        }
        val currentPlan = lastPlan ?: FeedEffectsRenderPlan.IDENTITY
        val policy = currentPlan.scopeTap
        val currentSamples = samples
        val scopeOwner = currentSamples.source
        val currentSource = scopeFrames.isCurrent(sourceEpoch) && scopeBus.isCurrent(scopeOwner)
        val wantSample = currentSource && (policy.needsTap || backdrop?.hasDemand(this) == true)
        val now = System.nanoTime()
        var scopeIntervalNs = ScopeSampler.BASE_MIN_INTERVAL_NS
        var scopeDue = false
        var previewTicket: com.opencapture.opencine.runtime.InspectorPreviewAdmission.Ticket? = null
        var backdropTicket: com.opencapture.opencine.runtime.BackdropFrameAdmission.Ticket? = null
        val takeTap =
            if (wantSample && now - lastSampleNs >= ScopeSampler.BASE_MIN_INTERVAL_NS) {
                val thermal =
                    runCatching {
                        val pm =
                            appContext.getSystemService(Context.POWER_SERVICE) as PowerManager
                        ScopeSampler.thermalMultiplier(pm.currentThermalStatus)
                    }.getOrDefault(1.0)
                val intervalNs = policy.tapIntervalNs(thermal, backdrop?.hasDemand(this) == true)
                scopeIntervalNs = policy.minIntervalNs(thermal)
                if (now - lastSampleNs >= intervalNs && sampleBusy.compareAndSet(false, true)) {
                    previewTicket = preview.acquire(policy.previewOwner, playback = false, now, scopeOwner)
                    backdropTicket = backdrop?.acquire(this, now)
                    scopeDue = policy.scopeWorkDue(now, lastScopeWorkNs, thermal)
                    if (scopeDue || previewTicket != null || backdropTicket != null) true
                    else { sampleBusy.set(false); false }
                } else false
            } else {
                false
            }
        // 1280→213 blit is per-submit. Arm it only on the sample tick;
        // leaving needTap on made WAVE/PARADE/VECTOR stall every frame.
        val takeFace = faceWanted.compareAndSet(true, false)
        OpcVulkan.nativeSetNeedTap(native, takeTap)
        OpcVulkan.nativeSetNeedFace(native, takeFace)
        if (readerFrames == 0) beforeFirstImport()
        val ok = OpcVulkan.nativeSubmit(native, hb)
        hb.close()
        held?.close()
        held = image
        if (!ok) {
            if (takeTap) { sampleBusy.set(false); preview.cancel(previewTicket); backdrop?.cancel(backdropTicket) }
            if (takeFace) faceWanted.set(true)
            if (presentGate.shouldFallbackOnSubmitFailure()) main.post { if (readerLifetime.isCurrent(readerTicket) && !presentGate.isReleased) onFailed() }
            return
        }
        framesPresented.incrementAndGet()
        if (readerLifetime.isCurrent(readerTicket) && !presentGate.isReleased) {
            onImportedFrame(++readerFrames)
            onFramePresented(image.timestamp.takeIf { it > 0 })
        }
        if (!started.get()) main.post {
            if (readerLifetime.isCurrent(readerTicket) && !presentGate.isReleased &&
                started.compareAndSet(false, true)) onFirstFrame()
        }
        if (takeFace) {
            synchronized(faceLock) {
                faceValid = readerLifetime.isCurrent(readerTicket) &&
                    scopeFrames.isCurrent(sourceEpoch) && OpcVulkan.nativeCopyFace(native, faceBytes)
            }
        }
        if (!takeTap) return
        lastSampleNs = now
        if (scopeDue) lastScopeWorkNs = now
        val transfer = policy.transfer
        val includePoints = policy.includePoints
        val includeVectorPoints = policy.includeVectorPoints
        val look = policy.vectorLut
        val iso = policy.iso
        // Keep this feed's ceiling on the reported ISO (or the profile's unreported assumption)
        // so readers without an ISO argument (traffic lights) agree with the sampled clip.
        if (scopeDue) currentSamples.ceiling.syncISO(iso)
        val previous = currentSamples.previous
        val packed =
            if ((scopeDue && (includePoints || includeVectorPoints) || previewTicket != null || backdropTicket != null) &&
                OpcVulkan.nativeCopyTap(native, tapBytes)
            ) {
                tapBytes.copyOf()
            } else {
                null
            }
        val histoCopy =
            if (packed == null && scopeDue) {
                OpcVulkan.nativeCopyHisto(native, histo)
                histo.copyOf()
            } else {
                null
            }
        val scopes = policy.activeScopeCount
        val loggedIntervalNs = scopeIntervalNs
        sampleExecutor.execute {
            var previewSubmitted = false
            var backdropSubmitted = false
            try {
                backdropTicket?.let { ticket ->
                    if (packed != null) {
                        backdrop?.submit(ticket,
                            InspectorPreviewFrame.fromTap(packed, TAP_W, TAP_H, bottomUp = false), currentPlan)
                        backdropSubmitted = true
                    }
                }
                val ticket = previewTicket
                if (ticket != null) {
                    if (packed != null) {
                        preview.submit(ticket,
                            InspectorPreviewFrame.fromTap(packed, TAP_W, TAP_H, bottomUp = false))
                        previewSubmitted = true
                    } else preview.cancel(ticket)
                }
                if (!scopeDue || !scopeFrames.isCurrent(sourceEpoch) ||
                    !scopeBus.isCurrent(scopeOwner)) return@execute
                val bundle =
                    if (packed != null) {
                        ScopeSampler.sample(
                            bytes = packed,
                            width = TAP_W,
                            height = TAP_H,
                            bytesPerRow = TAP_W * 4,
                            transfer = transfer,
                            includePoints = includePoints,
                            includeVectorPoints = includeVectorPoints,
                            look = look,
                            previous = previous,
                            ceiling = currentSamples.ceiling,
                            iso = iso,
                        )
                    } else {
                        val bins = histoCopy ?: IntArray(1024)
                        val y = bins.copyOfRange(0, 256)
                        val rr = bins.copyOfRange(256, 512)
                        val gg = bins.copyOfRange(512, 768)
                        val bb = bins.copyOfRange(768, 1024)
                        val samples = ScopeSamples(y, rr, gg, bb, emptyList())
                        ScopeAssistBundle(
                            revision = previous.revision + 1,
                            samples = samples,
                            traffic =
                                ScopeTrafficLights.reading(
                                    red = rr,
                                    green = gg,
                                    blue = bb,
                                    transfer = transfer,
                                    luma = y,
                                    ceiling = currentSamples.ceiling,
                                ),
                            histogramDisplay =
                                ScopeSampler.histogramDisplay(
                                    samples,
                                    previous.histogramDisplay,
                                    transfer,
                                    iso,
                                    currentSamples.ceiling,
                                ),
                            transfer = transfer,
                            iso = iso,
                            ceiling = ScopeClipSnapshot(transfer, currentSamples.ceiling.clipByte(transfer, iso)),
                        )
                    }
                main.post {
                    if (scopeFrames.isCurrent(sourceEpoch) && scopeBus.publish(scopeOwner, bundle)) {
                        currentSamples.previous = bundle
                    }
                }
                scopeHz.note(logTag, scopes = scopes, intervalNs = loggedIntervalNs)
            } catch (error: Exception) {
                if (!previewSubmitted) preview.cancel(previewTicket)
                Log.w(logTag, "scope tap failed", error)
            } finally {
                if (!backdropSubmitted) backdrop?.cancel(backdropTicket)
                sampleBusy.set(false)
            }
        }
    }

    companion object {
        /** The renderer library loaded on this device (a session would fail over to GLES otherwise). */
        val isAvailable: Boolean get() = OpcVulkan.isAvailable
        const val FACE_TAP_WIDTH = 320
        const val FACE_TAP_HEIGHT = 180
        const val SOURCE_W = 1280
        const val SOURCE_H = 720
        val TAP_W = ScopeSampler.tapSize(SOURCE_W, SOURCE_H).first
        val TAP_H = ScopeSampler.tapSize(SOURCE_W, SOURCE_H).second
    }
}
