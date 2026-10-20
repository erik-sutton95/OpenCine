package com.opencapture.opencine.runtime

import android.content.Context
import android.graphics.SurfaceTexture
import android.opengl.EGL14
import android.opengl.EGLConfig
import android.opengl.EGLContext
import android.opengl.EGLDisplay
import android.opengl.EGLSurface
import android.opengl.GLES11Ext
import android.opengl.GLES20
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.util.Log
import android.view.Surface
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import com.opencapture.opencine.media.FeedEffectsRenderPlan
import com.opencapture.opencine.media.FeedPresentPolicy
import com.opencapture.opencine.media.MonitorTransfer
import com.opencapture.opencine.media.ScopeAssistBundle
import com.opencapture.opencine.media.ScopeClipProfile
import com.opencapture.opencine.media.ScopeExposureCeiling
import com.opencapture.opencine.media.ScopeSampler
import com.opencapture.opencine.media.ScopeTapPolicy


private const val DEFAULT_SOURCE_WIDTH = 1280
private const val DEFAULT_SOURCE_HEIGHT = 720

/**
 * HEVC → `GL_TEXTURE_EXTERNAL_OES` → 2D FBO → cube at that raster → present
 * Rec.709 (bilinear / Fast Catmull-Rom) → TextureView. iOS bakeSize then fit.
 *
 * The decoder never owns the TextureView surface. The GPU path stays mounted so
 * toggling LUT / PEAK / FALSE / ZEBRA does not swap the decoder output surface.
 *
 * [letterboxSource] is the live cinema well. Playback already aspect-fits the
 * TextureView, so it passes false and fills the view.
 * [notifySurfaceOnMain] posts [onDecoderSurface] to the app thread (ExoPlayer).
 */
class NativeGlesFeedSession(
    context: Context,
    private val scopeBus: ScopeSampleBus,
    private val preview: InspectorPreviewPipeline,
    private val glFactory: (Context) -> NativeGlBackend,
    private val clipProfile: ScopeClipProfile = ScopeClipProfile(),
    private val inferTransfer: ((Int, Int, MonitorTransfer) -> MonitorTransfer)? = null,
    private val options: () -> GlesPresentationOptions = { GlesPresentationOptions() },
    private val logTag: String = "OpenCineFeedFx",
    private val onDecoderSurface: (Surface) -> Unit,
    private val onGpuFailed: () -> Unit,
    private val onFirstFrame: () -> Unit = {},
    private val letterboxSource: Boolean = true,
    private val notifySurfaceOnMain: Boolean = false,
    private val onFramePresented: (Long?) -> Unit = {},
    private val playback: Boolean = false,
    private val backdrop: NativeBackdropFeed? = null,
) {
    /** This feed's clip ceiling; never shared with another feed or playback. */
    private class Samples(val source: ScopeSampleBus.Source?, profile: ScopeClipProfile) {
        val ceiling = ScopeExposureCeiling(profile)
        var previous = ScopeAssistBundle.EMPTY
    }
    @Volatile private var samples = Samples(null, clipProfile)
    private val scopeHz = ScopeTapHzLog()

    @Volatile private var stretchToRect = false

    /** Only the final presentation changes; the OES source and grading raster stay native. */
    fun setStretchToRect(enabled: Boolean) {
        stretchToRect = enabled
        requestRender()
    }

    private val appContext = context.applicationContext
    private val mainHandler = Handler(Looper.getMainLooper())

    private val plan = AtomicReference(FeedEffectsRenderPlan.IDENTITY)
    private val running = AtomicBoolean(false)
    private val lifecycle = NativeRenderLifetime()
    @Volatile private var closed = false
    @Volatile private var presentationOptions = GlesPresentationOptions()
    private val frameLock = java.lang.Object()
    @Volatile private var frameAvailable = false
    @Volatile private var oesFramePending = false
    @Volatile private var redrawRequested = false
    @Volatile private var planDirty = true
    @Volatile private var displayTexture: SurfaceTexture? = null
    @Volatile private var displayWidth = 0
    @Volatile private var displayHeight = 0
    @Volatile private var sourceWidth = DEFAULT_SOURCE_WIDTH
    @Volatile private var sourceHeight = DEFAULT_SOURCE_HEIGHT
    private var renderThread: Thread? = null
    private val sampleExecutor =
        Executors.newSingleThreadExecutor { runnable ->
            Thread(runnable, "opc.scope.tap").apply { isDaemon = true }
        }
    private val sampleBusy = AtomicBoolean(false)
    private val previewSource = InspectorPreviewSource()
    private val sourceAdmission = java.util.concurrent.atomic.AtomicReference<((Any) -> Boolean)?>(null)
    /** Optional per-source publication policy. Existing callers retain their exact default path. */
    fun setSourceAdmission(admission: ((Any) -> Boolean)?) { sourceAdmission.set(admission) }
    private fun sourceCurrent(epoch: Long?): Boolean = previewSource.isCurrent(epoch, sourceAdmission.get())

    private val scopeLifetime = ScopeSourceLifetime(scopeBus,
        if (playback) ScopeSampleBus.Role.PLAYBACK
        else ScopeSampleBus.Role.LIVE)
    @Volatile private var scopeActive = false
    @Volatile private var nextScopeAtNs = 0L
    @Volatile private var lastScopeWorkNs = 0L

    /** This session as a [MonitorTexturePictureHost] program. */
    val pictureProgram: MonitorTexturePictureProgram =
        object : MonitorTexturePictureProgram {
            override fun attach(texture: SurfaceTexture, width: Int, height: Int) = attachDisplay(texture, width, height)
            override fun resize(width: Int, height: Int) = this@NativeGlesFeedSession.resize(width, height)
            override fun detach() = detachDisplay()
        }

    fun attachDisplay(surfaceTexture: SurfaceTexture, width: Int, height: Int) {
        if (closed) return
        detachDisplay()
        setScopeAttached(true)
        preview.sourceChanged(scopeLifetime.ownedSource)
        backdrop?.attach(this)
        displayTexture = surfaceTexture
        displayWidth = width.coerceAtLeast(1)
        displayHeight = height.coerceAtLeast(1)
        running.set(true)
        val generation = lifecycle.start()
        renderThread =
            Thread({ runGl(generation) }, "opc.feed.gl").apply {
                isDaemon = true
                start()
            }
    }

    fun resize(width: Int, height: Int) {
        displayWidth = width.coerceAtLeast(1)
        displayHeight = height.coerceAtLeast(1)
        requestRender()
    }

    fun updatePlan(next: FeedEffectsRenderPlan) {
        backdrop?.updatePlan(this, next)
        plan.set(next)
        planDirty = true
        requestRender()
    }

    fun setSourceSize(width: Int, height: Int) {
        val w = width.coerceAtLeast(16)
        val h = height.coerceAtLeast(16)
        if (w == sourceWidth && h == sourceHeight) return
        previewSource.invalidate()
        resetScopeSource()
        preview.sourceChanged(scopeLifetime.ownedSource)
        backdrop?.invalidate(this)
        sourceWidth = w
        sourceHeight = h
        requestRender()
    }

    @Synchronized fun configurePreviewSource(identity: Any, ready: Boolean, active: Boolean = true) {
        val changed = previewSource.configure(identity, ready && active)
        if (changed || scopeActive != active) {
            scopeActive = active
            resetScopeSource()
            preview.sourceChanged(scopeLifetime.ownedSource)
            backdrop?.invalidate(this)
        }
    }

    fun detachDisplay() {
        lifecycle.stop()
        preview.sourceChanged(scopeLifetime.ownedSource)
        setScopeAttached(false)
        previewSource.invalidate()
        backdrop?.invalidate(this)
        running.set(false)
        synchronized(frameLock) { frameLock.notifyAll() }
        renderThread?.join(800)
        renderThread = null
        displayTexture = null
        samples = Samples(scopeLifetime.source, clipProfile)
        nextScopeAtNs = 0L
        lastScopeWorkNs = 0L
    }

    fun close() {
        closed = true
        detachDisplay()
        sampleExecutor.shutdown()
    }

    @Synchronized private fun setScopeAttached(attached: Boolean) {
        if (attached) scopeLifetime.attach() else scopeLifetime.detach()
        samples = Samples(scopeLifetime.source, clipProfile)
    }

    @Synchronized private fun resetScopeSource() {
        scopeLifetime.invalidate(scopeActive)
        samples = Samples(scopeLifetime.source, clipProfile)
    }

    private fun requestRender() {
        synchronized(frameLock) {
            redrawRequested = true
            frameAvailable = true
            frameLock.notifyAll()
        }
    }

    /**
     * After present. Downsample the OES frame to the iOS tap size, walk it off
     * the GL thread at 25 Hz (10 Hz with three or more scopes).
     */
    private fun maybeTapScopes(
        generation: Long,
        policy: ScopeTapPolicy,
        currentPlan: FeedEffectsRenderPlan,
        oesCopy: OesCopyGlProgram,
        oesTexture: Int,
        texMatrix: FloatArray,
        tapTarget: SourceTarget?,
        tapPixels: ByteBuffer?,
        tapScratch: ByteArray?,
    ) {
        if (!lifecycle.isCurrent(generation)) return
        if ((!policy.needsTap && backdrop?.hasDemand(this) != true) || tapTarget == null || tapPixels == null || tapScratch == null) return
        val now = System.nanoTime()
        if (now < nextScopeAtNs) return
        val sourceEpoch = previewSource.captureEpoch() ?: return
        if (!sourceCurrent(sourceEpoch)) return
        val currentSamples = samples
        val scopeOwner = currentSamples.source
        if (!scopeBus.isCurrent(scopeOwner)) return
        if (!sampleBusy.compareAndSet(false, true)) return
        val previewTicket = preview.acquire(policy.previewOwner, playback, now, scopeOwner)?.takeIf {
            if (sourceCurrent(sourceEpoch)) true
            else { preview.cancel(it); false }
        }
        val thermal =
            runCatching {
                val pm = appContext.getSystemService(Context.POWER_SERVICE) as PowerManager
                ScopeSampler.thermalMultiplier(pm.currentThermalStatus)
            }.getOrDefault(1.0)
        val backdropTicket = if (sourceCurrent(sourceEpoch)) {
            backdrop?.acquire(this, now)
        } else null
        val scopeDue = policy.scopeWorkDue(now, lastScopeWorkNs, thermal)
        if (!scopeDue && previewTicket == null && backdropTicket == null) {
            sampleBusy.set(false)
            return
        }
        if (scopeDue) lastScopeWorkNs = now
        nextScopeAtNs = now + policy.tapIntervalNs(
            thermal, backdropTicket != null || backdrop?.hasDemand(this) == true)
        var handedOff = false
        try {
            GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, tapTarget.framebufferId)
            GLES20.glViewport(0, 0, tapTarget.width, tapTarget.height)
            oesCopy.draw(oesTexture, texMatrix)
            tapPixels.clear()
            GLES20.glReadPixels(
                0,
                0,
                tapTarget.width,
                tapTarget.height,
                GLES20.GL_RGBA,
                GLES20.GL_UNSIGNED_BYTE,
                tapPixels,
            )
            GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, 0)
            tapPixels.rewind()
            tapPixels.get(tapScratch)
            val packed = tapScratch.copyOf()
            val width = tapTarget.width
            val height = tapTarget.height
            val look = policy.vectorLut
            val previous = currentSamples.previous
            sampleExecutor.execute {
                var previewSubmitted = false
                var backdropSubmitted = false
                try {
                    if (backdropTicket != null && sourceCurrent(sourceEpoch)) {
                        backdrop?.submit(backdropTicket,
                            InspectorPreviewFrame.fromTap(packed, width, height, bottomUp = true), currentPlan,
                            admission = { lifecycle.isCurrent(generation) && sourceCurrent(sourceEpoch) })
                        backdropSubmitted = true
                    }
                    if (previewTicket != null && sourceCurrent(sourceEpoch)) {
                        preview.submit(previewTicket,
                            InspectorPreviewFrame.fromTap(packed, width, height, bottomUp = true),
                            admission = { lifecycle.isCurrent(generation) && sourceCurrent(sourceEpoch) })
                        previewSubmitted = true
                    }
                    if (!scopeDue || !sourceCurrent(sourceEpoch) ||
                        !scopeBus.isCurrent(scopeOwner)) return@execute
                    var transfer = policy.transfer
                    // An absent ISO is an unreported one: the source profile decides (Swift twin).
                    currentSamples.ceiling.syncISO(policy.iso)
                    val (minC, maxC) = ScopeSampler.minMaxRGB(packed)
                    if (policy.allowsTransferInference) {
                        transfer = inferTransfer?.invoke(minC, maxC, transfer) ?: transfer
                    }
                    currentSamples.ceiling.observeTapMax(maxC, transfer)
                    val sampled =
                        ScopeSampler.sample(
                            bytes = packed,
                            width = width,
                            height = height,
                            bytesPerRow = width * 4,
                            transfer = transfer,
                            includePoints = policy.includePoints,
                            includeVectorPoints = policy.includeVectorPoints,
                            look = if (policy.includeVectorPoints) look else null,
                            trafficThreshold = policy.trafficThreshold,
                            previous = previous,
                            ceiling = currentSamples.ceiling,
                        )
                    mainHandler.post {
                        if (sourceCurrent(sourceEpoch) && scopeBus.publish(scopeOwner, sampled)) {
                            currentSamples.previous = sampled
                        }
                    }
                    scopeHz.note(
                        logTag,
                        scopes = policy.activeScopeCount,
                        intervalNs = policy.minIntervalNs(thermal),
                    )
                } catch (error: Exception) {
                    if (!previewSubmitted) preview.cancel(previewTicket)
                    Log.w(logTag, "scope tap failed", error)
                } finally {
                    if (!previewSubmitted) preview.cancel(previewTicket)
                    if (!backdropSubmitted) backdrop?.cancel(backdropTicket)
                    sampleBusy.set(false)
                }
            }
            handedOff = true
        } finally {
            if (!handedOff) {
                backdrop?.cancel(backdropTicket)
                preview.cancel(previewTicket)
                sampleBusy.set(false)
            }
        }
    }

    private fun runGl(generation: Long) {
        val window = displayTexture ?: return
        var eglDisplay: EGLDisplay? = null
        var eglContext: EGLContext? = null
        var eglSurface: EGLSurface? = null
        var oesCopy: OesCopyGlProgram? = null
        var effects: FeedEffectsGlProgram? = null
        var oesTexture = 0
        var oesSurfaceTexture: SurfaceTexture? = null
        var decoderSurface: Surface? = null
        var sourceTarget: SourceTarget? = null
        var gradedTarget: SourceTarget? = null
        var tapTarget: SourceTarget? = null
        var tapPixels: ByteBuffer? = null
        var tapScratch: ByteArray? = null
        var activePlan: FeedEffectsRenderPlan? = null
        val texMatrix = FloatArray(16)
        var srcW = sourceWidth
        var srcH = sourceHeight
        val tapSize = ScopeSampler.tapSize(srcW, srcH)
        try {
            val egl = eglSetup(window)
            eglDisplay = egl.display
            eglContext = egl.context
            eglSurface = egl.surface
            val gl = glFactory(appContext)
            oesCopy = OesCopyGlProgram(appContext)
            oesTexture = createOesTexture()
            oesSurfaceTexture =
                SurfaceTexture(oesTexture).apply {
                    setDefaultBufferSize(srcW, srcH)
                    setOnFrameAvailableListener(
                        {
                            synchronized(frameLock) {
                                if (!lifecycle.isCurrent(generation)) return@setOnFrameAvailableListener
                                oesFramePending = true
                                frameAvailable = true
                                frameLock.notifyAll()
                            }
                        },
                        mainHandler,
                    )
                }
            decoderSurface = Surface(oesSurfaceTexture)
            if (running.get() && lifecycle.isCurrent(generation)) {
                if (notifySurfaceOnMain) {
                    mainHandler.post { if (lifecycle.isCurrent(generation)) onDecoderSurface(checkNotNull(decoderSurface)) }
                } else {
                    onDecoderSurface(decoderSurface)
                }
            }
            // Decode stays native; looks run on the FeedPresentPolicy working raster.
            val work = FeedPresentPolicy.workingSize(srcW, srcH)
            sourceTarget = SourceTarget.create(gl, work.first, work.second)
            gradedTarget = SourceTarget.create(gl, work.first, work.second)
            tapTarget = SourceTarget.create(gl, tapSize.first, tapSize.second)
            val tapBytes = tapSize.first * tapSize.second * 4
            tapPixels = ByteBuffer.allocateDirect(tapBytes).order(ByteOrder.nativeOrder())
            tapScratch = ByteArray(tapBytes)
            GLES20.glClearColor(0f, 0f, 0f, 1f)
            var hasOesFrame = false
            var signaledFirstFrame = false
            var lastOesTimestampNs = 0L
            // A held (paused, stalled) source is not redrawn: the 100 ms wake below only
            // retries tap consumers. New pictures, looks, sizes and upscaler changes present.
            var needsPresent = false
            var presentedUpscaler: MonitorGlesUpscaler? = null
            var presentedWidth = 0
            var presentedHeight = 0
            while (running.get() && lifecycle.isCurrent(generation)) {
                val pullOes: Boolean
                synchronized(frameLock) {
                    if (running.get() && !frameAvailable && !planDirty) {
                        frameLock.wait(100)
                    }
                    pullOes = oesFramePending
                    oesFramePending = false
                    frameAvailable = false
                    if (redrawRequested) needsPresent = true
                    redrawRequested = false
                }
                if (!running.get() || !lifecycle.isCurrent(generation)) break
                val nextPlan = plan.get()
                if (nextPlan !== activePlan || effects == null) {
                    if (effects?.adopt(nextPlan) != true) {
                        effects?.release()
                        effects = FeedEffectsGlProgram(gl, nextPlan, flipInputVertically = false,
                            reconstructToDisplay = { sw, sh, dw, dh ->
                                presentationOptions.upscaler == MonitorGlesUpscaler.FAST &&
                                    MonitorGlesUpscaler.shouldReconstructToDisplay(sw, sh, dw, dh)
                            })
                    }
                    activePlan = nextPlan
                    planDirty = false
                    needsPresent = true
                }
                presentationOptions = options()
                if (presentationOptions.upscaler != presentedUpscaler) needsPresent = true
                if (sourceWidth != srcW || sourceHeight != srcH) {
                    srcW = sourceWidth
                    srcH = sourceHeight
                    oesSurfaceTexture.setDefaultBufferSize(srcW, srcH)
                    val work = FeedPresentPolicy.workingSize(srcW, srcH)
                    sourceTarget?.release()
                    sourceTarget = SourceTarget.create(gl, work.first, work.second)
                    gradedTarget?.release()
                    gradedTarget = SourceTarget.create(gl, work.first, work.second)
                    val nextTap = ScopeSampler.tapSize(srcW, srcH)
                    tapTarget?.release()
                    tapTarget = SourceTarget.create(gl, nextTap.first, nextTap.second)
                    val tapBytes = nextTap.first * nextTap.second * 4
                    tapPixels = ByteBuffer.allocateDirect(tapBytes).order(ByteOrder.nativeOrder())
                    tapScratch = ByteArray(tapBytes)
                }
                var skipDuplicate = false
                if (pullOes) {
                    val previewLatch = previewSource.beginLatch()
                    oesSurfaceTexture.updateTexImage()
                    if (!lifecycle.isCurrent(generation)) break
                    val timestampNs = oesSurfaceTexture.timestamp
                    if (FeedPresentPolicy.isDuplicateFrameTime(timestampNs, lastOesTimestampNs)) {
                        skipDuplicate = true
                    } else {
                        lastOesTimestampNs = timestampNs
                        oesSurfaceTexture.getTransformMatrix(texMatrix)
                        hasOesFrame = true
                        needsPresent = true
                        previewSource.didLatch(previewLatch)
                    }
                }
                if (!hasOesFrame) continue
                if (skipDuplicate && !needsPresent) continue
                val width = displayWidth
                val height = displayHeight
                if (
                    !FeedPresentPolicy.shouldRender(
                        attached = true,
                        enabled = running.get(),
                        hidden = false,
                        hasDrawable = width > 1 && height > 1,
                    )
                ) {
                    continue
                }
                val copy = oesCopy ?: continue
                if (needsPresent) {
                    val source = checkNotNull(sourceTarget)
                    GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, source.framebufferId)
                    GLES20.glViewport(0, 0, source.width, source.height)
                    val spread = FeedPresentPolicy.downsampleSpread(srcW, source.width)
                    copy.draw(oesTexture, texMatrix, spread / source.width, spread / source.height)
                    val content =
                        if (letterboxSource && !stretchToRect) {
                            nativeFeedContentRect(
                                width.toFloat(),
                                height.toFloat(),
                                source.width,
                                source.height,
                            )
                        } else {
                            null
                        }
                    val presentWidth = content?.width ?: width
                    val presentHeight = content?.height ?: height
                    GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, 0)
                    GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT)
                    if (content != null) {
                        GLES20.glViewport(content.left, content.top, content.width, content.height)
                    } else {
                        GLES20.glViewport(0, 0, width, height)
                    }
                    // First picture is a bilinear blit of 720p RGB. Cube then stretch
                    // on that submit missed the enable IDR (WAITING FOR LIVE VIEW).
                    if (!signaledFirstFrame) {
                        effects.draw(
                            source.textureId,
                            source.width.toFloat(),
                            source.height.toFloat(),
                            presentWidth.toFloat(),
                            presentHeight.toFloat(),
                            look = false,
                            upscale = false,
                        )
                    } else if (!nextPlan.hasPlaybackLook) {
                        // No cube or assist: the grade pass would be an exact copy.
                        effects.draw(
                            source.textureId,
                            source.width.toFloat(),
                            source.height.toFloat(),
                            presentWidth.toFloat(),
                            presentHeight.toFloat(),
                            look = false,
                        )
                    } else {
                        val graded = checkNotNull(gradedTarget)
                        GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, graded.framebufferId)
                        GLES20.glViewport(0, 0, graded.width, graded.height)
                        effects.draw(
                            source.textureId,
                            source.width.toFloat(),
                            source.height.toFloat(),
                            presentWidth.toFloat(),
                            presentHeight.toFloat(),
                            look = true,
                        )
                        GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, 0)
                        GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT)
                        if (content != null) {
                            GLES20.glViewport(content.left, content.top, content.width, content.height)
                        } else {
                            GLES20.glViewport(0, 0, width, height)
                        }
                        effects.draw(
                            graded.textureId,
                            source.width.toFloat(),
                            source.height.toFloat(),
                            presentWidth.toFloat(),
                            presentHeight.toFloat(),
                            look = false,
                        )
                    }
                    if (!previewSource.present(sourceAdmission.get()) {
                            if (lifecycle.isCurrent(generation)) {
                                check(EGL14.eglSwapBuffers(eglDisplay, eglSurface)) { "live present failed" }
                            }
                        }) continue
                    if (lifecycle.isCurrent(generation) && previewSource.admits(sourceAdmission.get())) {
                        onFramePresented(lastOesTimestampNs.takeIf { it > 0 })
                    }
                    val presentedSourceEpoch = previewSource.captureEpoch()
                    presentedUpscaler = presentationOptions.upscaler
                    // EGL may already hold its next buffer at the old window size, and a held
                    // (paused) source sends no new frame to replace it: present a resize twice.
                    val resized = width != presentedWidth || height != presentedHeight
                    presentedWidth = width
                    presentedHeight = height
                    // The first present is the look-free blit; the graded one follows.
                    needsPresent = !signaledFirstFrame || resized
                    if (!signaledFirstFrame) {
                        signaledFirstFrame = true
                        mainHandler.post {
                            if (lifecycle.isCurrent(generation) &&
                                (sourceAdmission.get() == null || sourceCurrent(presentedSourceEpoch))) onFirstFrame()
                        }
                    }
                }
                maybeTapScopes(
                    generation = generation,
                    policy = nextPlan.scopeTap,
                    currentPlan = nextPlan,
                    oesCopy = copy,
                    oesTexture = oesTexture,
                    texMatrix = texMatrix,
                    tapTarget = tapTarget,
                    tapPixels = tapPixels,
                    tapScratch = tapScratch,
                )
            }
        } catch (error: Exception) {
            Log.e(logTag, "live GPU feed failed; falling back to the identity surface", error)
            mainHandler.post { if (lifecycle.isCurrent(generation)) onGpuFailed() }
        } finally {
            runCatching { effects?.release() }
            runCatching { oesCopy?.release() }
            sourceTarget?.release()
            gradedTarget?.release()
            tapTarget?.release()
            decoderSurface?.release()
            oesSurfaceTexture?.release()
            if (oesTexture != 0) {
                GLES20.glDeleteTextures(1, intArrayOf(oesTexture), 0)
            }
            val display = eglDisplay
            if (display != null) {
                EGL14.eglMakeCurrent(
                    display,
                    EGL14.EGL_NO_SURFACE,
                    EGL14.EGL_NO_SURFACE,
                    EGL14.EGL_NO_CONTEXT,
                )
                eglSurface?.let { EGL14.eglDestroySurface(display, it) }
                eglContext?.let { EGL14.eglDestroyContext(display, it) }
                EGL14.eglTerminate(display)
            }
        }
    }

    private data class EglHandles(
        val display: EGLDisplay,
        val context: EGLContext,
        val surface: EGLSurface,
    )

    private fun eglSetup(window: SurfaceTexture): EglHandles {
        val display = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY)
        check(display != EGL14.EGL_NO_DISPLAY) { "no EGL display" }
        val version = IntArray(2)
        check(EGL14.eglInitialize(display, version, 0, version, 1)) { "eglInitialize failed" }
        val attribs =
            intArrayOf(
                EGL14.EGL_RENDERABLE_TYPE,
                EGL14.EGL_OPENGL_ES2_BIT,
                EGL14.EGL_RED_SIZE,
                8,
                EGL14.EGL_GREEN_SIZE,
                8,
                EGL14.EGL_BLUE_SIZE,
                8,
                EGL14.EGL_ALPHA_SIZE,
                8,
                EGL14.EGL_NONE,
            )
        val configs = arrayOfNulls<EGLConfig>(1)
        val num = IntArray(1)
        check(
            EGL14.eglChooseConfig(display, attribs, 0, configs, 0, 1, num, 0) && num[0] > 0,
        ) { "no EGL config" }
        val config = checkNotNull(configs[0])
        val context =
            EGL14.eglCreateContext(
                display,
                config,
                EGL14.EGL_NO_CONTEXT,
                intArrayOf(EGL14.EGL_CONTEXT_CLIENT_VERSION, 2, EGL14.EGL_NONE),
                0,
            )
        check(context != null && context != EGL14.EGL_NO_CONTEXT) { "eglCreateContext failed" }
        val surface =
            EGL14.eglCreateWindowSurface(display, config, window, intArrayOf(EGL14.EGL_NONE), 0)
        check(surface != null && surface != EGL14.EGL_NO_SURFACE) { "eglCreateWindowSurface failed" }
        check(EGL14.eglMakeCurrent(display, surface, surface, context)) { "eglMakeCurrent failed" }
        return EglHandles(display, context, surface)
    }

    private fun createOesTexture(): Int {
        val textures = IntArray(1)
        GLES20.glGenTextures(1, textures, 0)
        val texture = textures[0]
        check(texture != 0) { "no OES texture" }
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, texture)
        // A 4:2:0 source uses chroma subsampling. samplerExternalOES converts YUV→RGB in
        // this fetch - NEAREST snaps chroma to 2×2 blocks (blotchy colour).
        GLES20.glTexParameteri(
            GLES11Ext.GL_TEXTURE_EXTERNAL_OES,
            GLES20.GL_TEXTURE_MIN_FILTER,
            GLES20.GL_LINEAR,
        )
        GLES20.glTexParameteri(
            GLES11Ext.GL_TEXTURE_EXTERNAL_OES,
            GLES20.GL_TEXTURE_MAG_FILTER,
            GLES20.GL_LINEAR,
        )
        GLES20.glTexParameteri(
            GLES11Ext.GL_TEXTURE_EXTERNAL_OES,
            GLES20.GL_TEXTURE_WRAP_S,
            GLES20.GL_CLAMP_TO_EDGE,
        )
        GLES20.glTexParameteri(
            GLES11Ext.GL_TEXTURE_EXTERNAL_OES,
            GLES20.GL_TEXTURE_WRAP_T,
            GLES20.GL_CLAMP_TO_EDGE,
        )
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, 0)
        return texture
    }
}

private class SourceTarget(
    private val gl: NativeGlBackend,
    val textureId: Int,
    val framebufferId: Int,
    val width: Int,
    val height: Int,
) {
    fun release() {
        gl.deleteFramebuffer(framebufferId)
        gl.deleteTexture(textureId)
    }

    companion object {
        fun create(gl: NativeGlBackend, width: Int, height: Int): SourceTarget {
            val textureId =
                gl.createTexture(width, height)
            val framebufferId = gl.createFramebuffer(textureId)
            return SourceTarget(gl, textureId, framebufferId, width, height)
        }
    }
}
