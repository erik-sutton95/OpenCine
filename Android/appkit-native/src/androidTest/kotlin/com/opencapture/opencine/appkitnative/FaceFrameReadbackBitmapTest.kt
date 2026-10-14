package com.opencapture.opencine.appkitnative

import com.opencapture.opencine.core.CameraSessionID
import com.opencapture.opencine.core.ControlEpoch
import com.opencapture.opencine.core.StreamGeneration

import android.graphics.Bitmap
import android.graphics.Color
import android.view.PixelCopy
import android.view.Surface
import android.view.SurfaceHolder
import android.view.SurfaceView
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.test.core.app.ActivityScenario
import com.opencapture.monitorui.MonitorRect
import com.opencapture.opencine.decoder.HevcDecoder
import com.opencapture.opencine.media.ScopeClipProfile
import com.opencapture.opencine.runtime.GlesPresentationOptions
import com.opencapture.opencine.runtime.VulkanCrashGuard
import com.opencapture.opencine.vocabulary.ConnectionPhase
import com.opencapture.opencine.vocabulary.SessionRecoveryUi
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.flow.MutableStateFlow
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * SIMULATED sources: four direct bitmap-owner cases plus real SurfaceView/PixelCopy production-pump cases.
 * Real-copy cases hold the actual native completion before delivery; ML adapter tests run in each app.
 */
@RunWith(AndroidJUnit4::class)
class FaceFrameReadbackBitmapTest {
    private class Source(var identity: Any = Any()) {
        var epoch: MonitorFaceReadbackEpoch? = MonitorFaceReadbackEpoch(CameraSessionID(), ControlEpoch(1))
        var made = 0
        var discards = 0
        val submitted = mutableListOf<Frame>()
    }

    private class Frame(val bitmap: Bitmap) {
        var releases = 0
        fun release() {
            assertFalse(bitmap.isRecycled)
            releases++
            bitmap.recycle()
        }
    }

    private class Host {
        val first = Source()
        var current = first
        val owner = FaceFrameReadbackOwner({ current }, { it.identity }, { it.epoch })
        var lifetime = assertNotNull(owner.activate())
        var rawReleases = 0
        var duringFactory: () -> Unit = {}

        fun replace(source: Source) {
            owner.retire(lifetime)
            current = source
            lifetime = assertNotNull(owner.activate())
        }

        fun hold(): Pair<Bitmap, () -> Unit> {
            val request = assertNotNull(owner.begin { true })
            val bitmap = Bitmap.createBitmap(320, 180, Bitmap.Config.ARGB_8888)
            val callback = {
                owner.complete(request, copied = true,
                    release = {
                        assertFalse(bitmap.isRecycled)
                        rawReleases++
                        bitmap.recycle()
                    },
                    construct = { source, _ ->
                        source.made++
                        Frame(bitmap).also { duringFactory() }
                    },
                    discard = { source, frame -> source.discards++; frame.release() },
                    consume = { source, frame -> source.submitted += frame })
            }
            return bitmap to callback
        }
    }

    private fun onMain(block: () -> Unit) = InstrumentationRegistry.getInstrumentation().runOnMainSync { block() }

    @Test fun activeSuccessorRejectsHeldSuccessAndNativeDestinationLivesUntilCompletion() = onMain {
        val host = Host()
        val (oldBitmap, oldCallback) = host.hold()
        val successor = Source()
        host.replace(successor)
        assertFalse(oldBitmap.isRecycled)
        assertNull(host.owner.begin { true })
        oldCallback()
        assertTrue(oldBitmap.isRecycled)
        assertEquals(1, host.rawReleases)
        assertEquals(0, host.first.made)
        assertEquals(0, successor.made)
        val (newBitmap, newCallback) = host.hold()
        oldCallback()
        assertFalse(newBitmap.isRecycled)
        newCallback()
        successor.submitted.single().release()
        assertTrue(newBitmap.isRecycled)
        assertEquals(1, successor.submitted.single().releases)
        host.owner.close()
    }

    @Test fun disposedHostRejectsHeldSuccessAndRecyclesExactlyOnce() = onMain {
        val host = Host()
        val (bitmap, callback) = host.hold()
        host.owner.close()
        assertFalse(bitmap.isRecycled)
        callback()
        callback()
        assertTrue(bitmap.isRecycled)
        assertEquals(1, host.rawReleases)
        assertEquals(0, host.first.made)
        assertNull(host.owner.activate())
    }

    @Test fun validSameSourceKeepsPixelsUntilDetectorCompletion() = onMain {
        val host = Host()
        val (bitmap, callback) = host.hold()
        callback()
        callback()
        assertFalse(bitmap.isRecycled)
        assertEquals(1, host.first.submitted.size)
        assertEquals(0, host.rawReleases)
        host.first.submitted.single().release()
        assertTrue(bitmap.isRecycled)
        assertEquals(1, host.first.submitted.single().releases)
        host.owner.close()
    }

    @Test fun factoryRetirementDiscardsThroughItsOriginalFrameOwner() = onMain {
        val host = Host()
        val (bitmap, callback) = host.hold()
        val successor = Source()
        host.duringFactory = { host.replace(successor) }
        callback()
        assertTrue(bitmap.isRecycled)
        assertEquals(1, host.first.discards)
        assertEquals(0, host.rawReleases, "a made frame owns disposal")
        assertEquals(0, host.first.submitted.size)
        assertEquals(0, successor.submitted.size)
        callback()
        assertEquals(1, host.first.discards)
        host.owner.close()
    }

    private class ProducerSource : MonitorLiveFeedSource<Frame> {
        override val decoder = HevcDecoder()
        override val pictureIdentity = Any()
        override var faceReadbackEpoch: MonitorFaceReadbackEpoch? =
            MonitorFaceReadbackEpoch(CameraSessionID(), ControlEpoch(1))
        override val cameraName = "SIMULATED source"
        override val connection = ConnectionPhase.LIVE
        override val recoveryState = MutableStateFlow<SessionRecoveryUi>(SessionRecoveryUi.Idle)
        override val isFeedRecovering = false
        override val isFocusResetAvailable = false
        override val wantsFaceDetect = MutableStateFlow(true)
        val demandObserved = CountDownLatch(1)
        var requestsAllowed = false
        var made = 0
        var discarded = 0
        val submitted = mutableListOf<Frame>()
        var afterConstruction: () -> Unit = {}
        override fun attachSurface(surface: Surface?) = Unit
        override fun noteLiveFrame() = Unit
        override fun retrySessionRecovery() = Unit
        override fun wantsFaceFrame(): Boolean {
            if (requestsAllowed) demandObserved.countDown()
            return requestsAllowed
        }
        override fun faceFrame(bitmap: Bitmap): Frame {
            made++
            return Frame(bitmap).also { afterConstruction() }
        }
        override fun discardUnsubmittedFaceFrame(frame: Frame, bitmap: Bitmap) {
            discarded++
            frame.release()
        }
        override fun faceFrame(nv21: ByteArray, width: Int, height: Int): Frame = error("SurfaceView fixture must use PixelCopy")
        override fun considerFaceFrame(frame: Frame) { submitted += frame }
    }

    private class HeldResult(val bitmap: Bitmap, val status: Int, private val completion: () -> Unit) {
        var deliveries = 0
        fun deliver() { deliveries++; completion() }
    }

    /** Real production FaceFramePump, real window/surface, real copy; only completed delivery is held. */
    private class RealCopyFixture : AutoCloseable {
        val first = ProducerSource()
        val allSources = mutableListOf(first)
        var current by mutableStateOf(first)
        var mounted by mutableStateOf(true)
        private val created = CountDownLatch(1)
        private val copied = CountDownLatch(1)
        private val disposed = CountDownLatch(1)
        private var surfaceView: SurfaceView? = null
        private val held = mutableListOf<HeldResult>()
        private var closing = false
        private val instrumentation = InstrumentationRegistry.getInstrumentation()
        private val scenario = ActivityScenario.launch(ComponentActivity::class.java)

        init {
            try {
                scenario.onActivity { activity ->
                    val feed = MonitorLiveFeedIntegration(ScopeClipProfile(), VulkanCrashGuard("f11-face-readback", 1),
                        journal = { _, _, _, _ -> }, presentation = { GlesPresentationOptions() })
                    feed.faceReadbackDelivery = { bitmap, result, deliver ->
                        if (closing || result != PixelCopy.SUCCESS) {
                            deliver()
                        } else {
                            current.requestsAllowed = false
                            held += HeldResult(bitmap, result, deliver)
                            copied.countDown()
                        }
                    }
                    activity.setContent {
                        var view by remember { mutableStateOf<SurfaceView?>(null) }
                        Box(Modifier.size(320.dp, 180.dp)) {
                            AndroidView(factory = { context ->
                                SurfaceView(context).also { native ->
                                    surfaceView = native
                                    view = native
                                    native.holder.addCallback(object : SurfaceHolder.Callback {
                                        override fun surfaceCreated(holder: SurfaceHolder) { created.countDown() }
                                        override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) = Unit
                                        override fun surfaceDestroyed(holder: SurfaceHolder) = Unit
                                    })
                                }
                            }, modifier = Modifier.fillMaxSize())
                            if (mounted) {
                                DisposableEffect(Unit) {
                                    onDispose { disposed.countDown() }
                                }
                                FaceFramePump(current, feed, view, textureView = null, vulkan = null,
                                    feedRect = MonitorRect(0f, 0f, 320f, 180f), enabled = true)
                            }
                        }
                    }
                }
                assertTrue(created.await(10, TimeUnit.SECONDS), "a real SurfaceView surface is created")
            } catch (failure: Throwable) {
                scenario.close()
                throw failure
            }
        }

        fun copy(color: Int = Color.GREEN): HeldResult {
            scenario.onActivity {
                val native = checkNotNull(surfaceView)
                val canvas = checkNotNull(native.holder.lockCanvas()) { "the created surface has a writable canvas" }
                try { canvas.drawColor(color) } finally { native.holder.unlockCanvasAndPost(canvas) }
                first.requestsAllowed = true
            }
            assertTrue(copied.await(10, TimeUnit.SECONDS), "the actual PixelCopy completion reaches its delivery hook")
            var result: HeldResult? = null
            scenario.onActivity { result = held.single() }
            return assertNotNull(result).also {
                assertEquals(PixelCopy.SUCCESS, it.status)
                assertFalse(it.bitmap.isRecycled, "completed native pixels remain alive while delivery is held")
                assertEquals(color, it.bitmap.getPixel(it.bitmap.width / 2, it.bitmap.height / 2), "the actual surface raster was copied")
            }
        }

        fun activeSuccessor(): ProducerSource {
            val successor = ProducerSource()
            scenario.onActivity {
                allSources += successor
                current = successor
                successor.requestsAllowed = true
            }
            assertTrue(successor.demandObserved.await(10, TimeUnit.SECONDS), "the actual production loop observes active successor demand")
            scenario.onActivity { successor.requestsAllowed = false }
            return successor
        }

        fun onMain(action: () -> Unit) { scenario.onActivity { action() } }

        fun disposePump() {
            scenario.onActivity { mounted = false; allSources.forEach { it.requestsAllowed = false } }
            assertTrue(disposed.await(10, TimeUnit.SECONDS), "the production pump leaves the actual composition")
            instrumentation.waitForIdleSync()
        }

        override fun close() {
            disposePump()
            scenario.onActivity {
                closing = true
                held.filter { it.deliveries == 0 }.forEach { it.deliver() }
                allSources.forEach { source ->
                    source.submitted.filter { !it.bitmap.isRecycled }.forEach(Frame::release)
                    source.decoder.reset()
                }
            }
            scenario.close()
        }
    }

    @Test fun realPixelCopyDelayedSuccessCannotReachAnActiveSuccessor() {
        RealCopyFixture().use { fixture ->
            val old = fixture.copy()
            val successor = fixture.activeSuccessor()
            fixture.onMain {
                old.deliver()
                assertEquals(0, fixture.first.made)
                assertEquals(0, successor.made)
                assertEquals(0, fixture.first.submitted.size)
                assertEquals(0, successor.submitted.size)
                assertTrue(old.bitmap.isRecycled)
            }
        }
    }

    @Test fun realPixelCopySameCameraReconnectWithoutRecompositionRejectsOldEpoch() {
        RealCopyFixture().use { fixture ->
            val old = fixture.copy()
            fixture.onMain {
                fixture.first.faceReadbackEpoch = MonitorFaceReadbackEpoch(CameraSessionID(), ControlEpoch(1))
                old.deliver()
                assertEquals(0, fixture.first.made)
                assertEquals(0, fixture.first.submitted.size)
                assertTrue(old.bitmap.isRecycled)
            }
        }
    }

    @Test fun realPixelCopyDisposedProducerCannotAdmitDelayedSuccess() {
        RealCopyFixture().use { fixture ->
            val old = fixture.copy()
            fixture.disposePump()
            fixture.onMain {
                old.deliver()
                assertEquals(0, fixture.first.made)
                assertEquals(0, fixture.first.submitted.size)
                assertTrue(old.bitmap.isRecycled)
            }
        }
    }

    @Test fun realPixelCopyValidSameCameraOwnsRealPixelsUntilFrameRelease() {
        RealCopyFixture().use { fixture ->
            val valid = fixture.copy(Color.RED)
            fixture.onMain {
                valid.deliver()
                assertEquals(1, fixture.first.made)
                val frame = fixture.first.submitted.single()
                assertFalse(valid.bitmap.isRecycled)
                assertEquals(Color.RED, frame.bitmap.getPixel(frame.bitmap.width / 2, frame.bitmap.height / 2))
                frame.release()
                assertTrue(valid.bitmap.isRecycled)
                assertEquals(1, frame.releases)
            }
        }
    }

    @Test fun realPixelCopyUnknownEpochAfterCopyRefusesAdmission() {
        RealCopyFixture().use { fixture ->
            val old = fixture.copy()
            fixture.onMain {
                fixture.first.faceReadbackEpoch = null
                old.deliver()
                assertEquals(0, fixture.first.made)
                assertTrue(old.bitmap.isRecycled)
            }
        }
    }

    @Test fun realPixelCopyEpochRetiredDuringFactoryReleasesTheMadeFrameOnce() {
        RealCopyFixture().use { fixture ->
            val copy = fixture.copy()
            fixture.onMain {
                fixture.first.afterConstruction = { fixture.first.faceReadbackEpoch = null }
                copy.deliver()
                assertEquals(1, fixture.first.made)
                assertEquals(1, fixture.first.discarded)
                assertEquals(0, fixture.first.submitted.size)
                assertTrue(copy.bitmap.isRecycled)
            }
        }
    }

    @Test fun realPixelCopyRetainedControlSessionRejectsNewNativeStreamWithoutRecomposition() {
        RealCopyFixture().use { fixture ->
            val control = assertNotNull(fixture.first.faceReadbackEpoch)
            fixture.onMain { fixture.first.faceReadbackEpoch = control.copy(stream = StreamGeneration(1)) }
            val old = fixture.copy()
            fixture.onMain {
                fixture.first.faceReadbackEpoch = control.copy(stream = StreamGeneration(2))
                old.deliver()
                assertEquals(0, fixture.first.made)
                assertEquals(0, fixture.first.submitted.size)
                assertTrue(old.bitmap.isRecycled)
            }
        }
    }
}
