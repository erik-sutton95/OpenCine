package com.opencapture.opencine.appkitnative

import com.opencapture.opencine.cameracontrols.PortraitFeedAspect

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.SurfaceTexture
import android.view.Surface
import android.view.TextureView
import android.view.View
import android.view.ViewGroup
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.opencapture.monitorui.MonitorJoystickSize
import com.opencapture.opencine.appkit.MonitorAssistState
import com.opencapture.opencine.decoder.HevcDecoder
import com.opencapture.opencine.media.FeedEffectsRenderPlan
import com.opencapture.opencine.media.ScopeClipProfile
import com.opencapture.opencine.runtime.GlesPresentationOptions
import com.opencapture.opencine.runtime.InspectorPreviewPipeline
import com.opencapture.opencine.runtime.NativeGlBackend
import com.opencapture.opencine.runtime.ScopeSampleBus
import com.opencapture.opencine.runtime.VulkanCrashGuard
import com.opencapture.opencine.vocabulary.ConnectionPhase
import com.opencapture.opencine.vocabulary.SessionRecoveryUi
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicInteger
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNotSame
import kotlin.test.assertTrue
import kotlinx.coroutines.flow.MutableStateFlow
import org.junit.After
import org.junit.Test
import org.junit.runner.RunWith

/**
 * The shared live host on the GLES path with a fake camera session and a real decoder object that
 * never decodes: the test draws pictures straight into the surface the host hands the decoder.
 */
@RunWith(AndroidJUnit4::class)
class MonitorLiveFeedHostTest {
    private class FakeSource : MonitorLiveFeedSource<String> {
        override val decoder = HevcDecoder()
        override val pictureIdentity = Any()
        override val cameraName = "Test camera"
        override val connection = ConnectionPhase.LIVE
        override val recoveryState = MutableStateFlow<SessionRecoveryUi>(SessionRecoveryUi.Idle)
        override val isFeedRecovering = false
        override val isFocusResetAvailable = false
        override val wantsFaceDetect = MutableStateFlow(false)
        val surfaces = CopyOnWriteArrayList<Surface?>()
        val textureEvents = CopyOnWriteArrayList<String>()
        val liveFrames = AtomicInteger(0)
        override fun attachSurface(surface: Surface?) { surfaces += surface }
        override fun noteLiveFrame() { liveFrames.incrementAndGet() }
        override fun retrySessionRecovery() = Unit
        override fun wantsFaceFrame() = false
        override fun faceFrame(bitmap: Bitmap) = "bitmap".also { bitmap.recycle() }
        override fun faceFrame(nv21: ByteArray, width: Int, height: Int) = "nv21"
        override fun considerFaceFrame(frame: String) = Unit
        val decoderSurface: Surface? get() = surfaces.lastOrNull()
    }

    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val context: Context = instrumentation.targetContext
    private var scenario: ActivityScenario<ComponentActivity>? = null

    @After fun close() { scenario?.close() }

    /** Two crashed import windows in a row: this device runs the GLES picture. */
    private fun trippedGuard(): VulkanCrashGuard {
        val name = "monitor-live-feed-host-test"
        context.getSharedPreferences(name, Context.MODE_PRIVATE).edit().clear().commit()
        repeat(VulkanCrashGuard.STRIKES_TO_DISABLE) { VulkanCrashGuard(name, 1).arm(context) }
        return VulkanCrashGuard(name, 1).also { assertTrue(it.isTripped(context)) }
    }

    private fun launch(source: FakeSource, glBackend: (Context) -> NativeGlBackend = NativeGlBackend::create) {
        val feed = MonitorLiveFeedIntegration(ScopeClipProfile(), trippedGuard(), journal = { _, _, _, message -> source.textureEvents += message },
            presentation = { GlesPresentationOptions() }, glBackend = glBackend)
        val scopeBus = ScopeSampleBus()
        val preview = InspectorPreviewPipeline(scopeBus, { NativeGlBackend.create(it) })
        scenario = ActivityScenario.launch(ComponentActivity::class.java).onActivity { activity ->
            activity.setContent {
                MonitorLiveFeedHost(feed, source,
                    owners = MonitorLiveFeedOwners(MonitorAssistState(), scopeBus, preview),
                    display = MonitorLiveFeedDisplay(FeedEffectsRenderPlan.IDENTITY, false, { true },
                        PortraitFeedAspect.FIT_16X9, MonitorJoystickSize.entries.first(), false),
                    cover = null, onOperatorMenu = {}) {
                    Box(modifier.fillMaxSize()) { picture() }
                }
            }
        }
    }

    private fun textureView(): TextureView {
        var found: TextureView? = null
        scenario!!.onActivity { found = find(it.window.decorView) }
        return assertNotNull(found, "the host shows a picture TextureView")
    }

    private fun find(view: View): TextureView? = when (view) {
        is TextureView -> view
        is ViewGroup -> (0 until view.childCount).firstNotNullOfOrNull { find(view.getChildAt(it)) }
        else -> null
    }

    /** One picture into what the decoder would write; a dead surface draws nothing. */
    private fun draw(surface: Surface, color: Int) {
        runCatching {
            val canvas = surface.lockHardwareCanvas()
            canvas.drawColor(color)
            surface.unlockCanvasAndPost(canvas)
        }
    }

    private fun await(what: String, predicate: () -> Boolean) {
        val deadline = System.nanoTime() + 10_000_000_000L
        while (System.nanoTime() < deadline) {
            instrumentation.waitForIdleSync()
            if (predicate()) return
            Thread.sleep(25)
        }
        assertTrue(predicate(), what)
    }

    /** Keeps drawing until the host presents a new picture, as a decoder keeps producing. */
    private fun presents(source: FakeSource, surface: Surface, color: Int): Boolean {
        val before = source.liveFrames.get()
        val deadline = System.nanoTime() + 5_000_000_000L
        while (System.nanoTime() < deadline) {
            draw(surface, color)
            instrumentation.waitForIdleSync()
            if (source.liveFrames.get() > before) return true
            Thread.sleep(50)
        }
        return false
    }

    @Test fun pictureSurfaceSurvivesDestroyAndRecreate() {
        val source = FakeSource()
        launch(source)
        await("the GLES feed hands the decoder its surface") { source.decoderSurface != null }
        val first = checkNotNull(source.decoderSurface)
        assertTrue(presents(source, first, Color.RED), "the first picture presents")
        await("a presented picture reaches the decoder clock") { source.decoder.hasPicture.value }
        // The window detaches the picture view and attaches it again: the texture is destroyed
        // and re-created under the same feed session.
        val view = textureView()
        val parent = view.parent as ViewGroup
        val destroyedBefore = source.textureEvents.count { it == "feed: gles surface destroyed" }
        instrumentation.runOnMainSync { parent.removeView(view) }
        await("the host acknowledges the actual removed texture: ${source.textureEvents}") {
            source.textureEvents.count { it == "feed: gles surface destroyed" } > destroyedBefore
                && !view.isAvailable
        }
        instrumentation.runOnMainSync { parent.addView(view) }
        await("the re-created texture gets a new decoder surface") {
            source.decoderSurface.let { it != null && it !== first }
        }
        val second = checkNotNull(source.decoderSurface)
        assertNotSame(first, second)
        assertTrue(presents(source, second, Color.GREEN), "pictures present again after re-create")
    }

    /** A3-12: a late destroy for an old texture must not tear down the program on its replacement. */
    @Test fun staleTextureDestroyCannotDetachTheLiveProgram() {
        val source = FakeSource()
        launch(source)
        await("the GLES feed hands the decoder its surface") { source.decoderSurface != null }
        val surface = checkNotNull(source.decoderSurface)
        assertTrue(presents(source, surface, Color.RED), "the first picture presents")
        val view = textureView()
        val stale = SurfaceTexture(false)
        try {
            instrumentation.runOnMainSync { view.surfaceTextureListener!!.onSurfaceTextureDestroyed(stale) }
        } finally {
            stale.release()
        }
        assertTrue(presents(source, surface, Color.BLUE), "the live program keeps presenting")
        assertEquals(1, source.surfaces.count { it != null }, "the decoder kept its surface")
    }

    @Test fun gpuFailureFallsBackToTheDecoderTexture() {
        val source = FakeSource()
        launch(source, glBackend = { error("no GL program on this device") })
        await("the fallback hands the decoder the texture surface") { source.decoderSurface != null }
        val direct = checkNotNull(source.decoderSurface)
        assertTrue(presents(source, direct, Color.RED), "the decoder texture presents directly")
        await("the direct picture reaches the decoder clock") { source.decoder.hasPicture.value }
    }
}
