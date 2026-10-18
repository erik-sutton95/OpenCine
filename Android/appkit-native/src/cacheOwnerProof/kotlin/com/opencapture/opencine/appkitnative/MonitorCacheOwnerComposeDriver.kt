package com.opencapture.opencine.appkitnative

import android.app.Instrumentation
import android.content.Context
import android.content.pm.ActivityInfo
import android.graphics.Color
import android.view.Surface
import android.view.TextureView
import android.view.ViewGroup
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalWindowInfo
import androidx.compose.ui.viewinterop.AndroidView
import androidx.test.core.app.ActivityScenario
import com.opencapture.monitorui.MonitorLayoutPolicy
import com.opencapture.opencine.appkit.MonitorControlModel
import com.opencapture.opencine.appkit.MonitorScreen
import com.opencapture.opencine.appkit.MonitorScreenPresentation
import com.opencapture.opencine.media.FeedEffectsRenderPlan
import com.opencapture.opencine.runtime.InspectorPreviewPipeline
import com.opencapture.opencine.runtime.NativeGlBackend
import com.opencapture.opencine.runtime.NativeGlesFeedSession
import com.opencapture.opencine.runtime.MonitorTexturePictureHost
import com.opencapture.opencine.runtime.ScopeSampleBus
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Semaphore
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * SIMULATED source pictures in the real shared Compose screen and native picture host.
 * This adapter supplies window operations; the one neutral cache proof owns all cache assertions.
 * It adds no app, packer, cache algorithm or shipping module dependency.
 */
class MonitorCacheOwnerComposeDriver(
    private val instrumentation: Instrumentation,
    private val rememberOwner: @Composable (Context, Any) -> Pair<Any, () -> FeedEffectsRenderPlan>,
) : AutoCloseable {
    private val firstToken = Any()
    private val secondToken = Any()
    private val tokens = mutableStateOf(listOf(firstToken, secondToken))
    private val covered = mutableStateOf(false)
    private val events = Semaphore(0)
    private val records = ConcurrentHashMap<Any, Record>()
    @Volatile private var renderedCover = false
    @Volatile private var renderedOrientation = 0
    private var scenario: ActivityScenario<ComponentActivity>? = null

    private inner class Record(val token: Any, val owner: Any, val readPlan: () -> FeedEffectsRenderPlan) {
        val input = AtomicReference<Surface?>(null)
        val presented = AtomicInteger(0)
        val detaches = AtomicInteger(0)
        @Volatile var plan = FeedEffectsRenderPlan.IDENTITY
        @Volatile var ready = false
        @Volatile var disposed = false
        @Volatile var failed: String? = null
        @Volatile var view: TextureView? = null
    }

    fun start(): MonitorCacheOwnerComposeDriver {
        try {
            scenario = ActivityScenario.launch(ComponentActivity::class.java)
            requireNotNull(scenario).onActivity { activity -> activity.setContent { Content(activity) } }
            await("two actual facade plans and native picture views") {
                tokens.value.all { records[it]?.let { r -> r.ready && r.view?.isAvailable == true && r.input.get() != null } == true }
            }
            tokens.value.forEach { present(requireNotNull(records[it])) }
            return this
        } catch (error: Exception) { close(); throw error }
    }

    /** Source token, actual facade identity, and an actual hit through that facade. */
    fun snapshot(): List<Triple<Any, Any, FeedEffectsRenderPlan>> {
        var result = emptyList<Triple<Any, Any, FeedEffectsRenderPlan>>()
        requireNotNull(scenario).onActivity {
            result = tokens.value.map { token ->
                val record = requireNotNull(records[token])
                Triple(token, record.owner, record.readPlan())
            }
        }
        return result
    }

    fun retiredPlan(token: Any): FeedEffectsRenderPlan = requireNotNull(records[token]).readPlan()

    /** Commands are test transport values, never app or renderer policy. */
    fun command(action: String) {
        when (action) {
            "cover", "uncover" -> {
                val next = action == "cover"
                requireNotNull(scenario).onActivity { covered.value = next }
                await("sibling cover composition") { renderedCover == next }
            }
            "rotate" -> {
                val before = renderedOrientation
                requireNotNull(scenario).onActivity { activity ->
                    activity.requestedOrientation = if (before == android.content.res.Configuration.ORIENTATION_LANDSCAPE)
                        ActivityInfo.SCREEN_ORIENTATION_PORTRAIT else ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE
                }
                await("actual configuration rotation retained the activity") { renderedOrientation != before }
            }
            "detach" -> detachAndAttach()
            "retire-first" -> {
                requireNotNull(scenario).onActivity { tokens.value = listOf(secondToken) }
                await("final first-source composition disposal") { records[firstToken]?.disposed == true }
            }
            "replace-first" -> {
                val replacement = Any()
                requireNotNull(scenario).onActivity { tokens.value = listOf(replacement, secondToken) }
                await("replacement actual facade and native view") {
                    records[replacement]?.let { it.ready && it.view?.isAvailable == true && it.input.get() != null } == true
                }
            }
            "unmount" -> {
                val previous = tokens.value
                requireNotNull(scenario).onActivity { activity -> tokens.value = emptyList(); activity.setContent {} }
                await("all final source compositions disposed") { previous.all { records[it]?.disposed == true } }
                return
            }
            else -> error("Unknown cache proof action $action")
        }
        instrumentation.waitForIdleSync()
        tokens.value.forEach { present(requireNotNull(records[it])) }
    }

    @Composable private fun Content(context: Context) {
        val configuration = LocalConfiguration.current
        val orientation = configuration.orientation
        val container = LocalWindowInfo.current.containerSize
        val density = LocalDensity.current.density
        val width = container.width / density / tokens.value.size.coerceAtLeast(1)
        val height = container.height / density
        val isCovered = covered.value
        SideEffect { renderedCover = isCovered; renderedOrientation = orientation; events.release() }
        Box(Modifier.fillMaxSize()) {
            Row(Modifier.fillMaxSize()) {
                for (token in tokens.value) key(token) {
                    Picture(context, token, width, height, isCovered, Modifier.weight(1f).fillMaxSize())
                }
            }
            if (isCovered) Box(Modifier.fillMaxSize().background(androidx.compose.ui.graphics.Color.Black))
        }
    }

    @Composable private fun Picture(context: Context, token: Any, width: Float, height: Float,
        isCovered: Boolean, modifier: Modifier) {
        val (owner, readPlan) = rememberOwner(context, token)
        val record = remember(token, owner) { Record(token, owner, readPlan).also { records[token] = it } }
        val scopeBus = remember(record) { ScopeSampleBus() }
        val preview = remember(record) { InspectorPreviewPipeline(scopeBus, NativeGlBackend::create) }
        val session = remember(record) {
            NativeGlesFeedSession(context, scopeBus, preview, NativeGlBackend::create,
                onDecoderSurface = { record.input.set(it); events.release() },
                onGpuFailed = { record.failed = "Actual native GLES failed"; events.release() },
                onFramePresented = { record.presented.incrementAndGet(); events.release() })
        }
        var plan by remember(record) { mutableStateOf(FeedEffectsRenderPlan.IDENTITY) }
        LaunchedEffect(record) {
            try {
                plan = withContext(Dispatchers.Default) { readPlan() }
                record.plan = plan
                session.updatePlan(plan)
                session.configurePreviewSource(token, ready = true, active = true)
                record.ready = true
            } catch (error: Exception) { record.failed = error.toString() }
            events.release()
        }
        DisposableEffect(record) {
            onDispose { session.close(); preview.close(); record.disposed = true; events.release() }
        }
        val scope = rememberCoroutineScope()
        val control = remember(record) { MonitorControlModel(scope) }
        MonitorScreen(control, MonitorLayoutPolicy.fieldMonitor(width, height),
            MonitorScreenPresentation(interactive = !isCovered, transientControlsHidden = isCovered), modifier,
            picture = {
                AndroidView(factory = { viewContext ->
                    MonitorTexturePictureHost(viewContext, session.pictureProgram,
                        journal = { message ->
                            if (message == "feed: gles surface destroyed") record.detaches.incrementAndGet()
                            events.release()
                        }).also { record.view = it }
                }, modifier = Modifier.fillMaxSize())
            })
    }

    private fun detachAndAttach() {
        val record = requireNotNull(records[tokens.value.first()])
        val view = requireNotNull(record.view)
        val before = record.detaches.get()
        val oldInput = record.input.get()
        lateinit var parent: ViewGroup
        instrumentation.runOnMainSync { parent = view.parent as ViewGroup; parent.removeView(view) }
        await("real TextureView destruction") { record.detaches.get() > before && !view.isAvailable }
        instrumentation.runOnMainSync { parent.addView(view) }
        await("real replacement input surface") { view.isAvailable && record.input.get().let { it != null && it !== oldInput } }
    }

    private fun present(record: Record) {
        val before = record.presented.get()
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(10)
        do {
            check(record.failed == null) { record.failed ?: "Native failure" }
            record.input.get()?.let { surface ->
                runCatching {
                    val canvas = surface.lockHardwareCanvas()
                    canvas.drawColor(if (record.token === secondToken) Color.GREEN else Color.RED)
                    surface.unlockCanvasAndPost(canvas)
                }
            }
            if (record.presented.get() > before) return
            events.tryAcquire(minOf(TimeUnit.MILLISECONDS.toNanos(100), (deadline - System.nanoTime()).coerceAtLeast(0)), TimeUnit.NANOSECONDS)
        } while (System.nanoTime() < deadline)
        check(record.presented.get() > before) { "Actual native picture did not present in the original 10-second bound" }
    }

    private fun await(description: String, predicate: () -> Boolean) {
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(10)
        while (true) {
            instrumentation.waitForIdleSync()
            records.values.forEach { check(it.failed == null) { it.failed ?: "Native failure" } }
            if (predicate()) return
            val remaining = deadline - System.nanoTime()
            check(remaining > 0) { description }
            events.tryAcquire(remaining, TimeUnit.NANOSECONDS)
        }
    }

    override fun close() { scenario?.close(); scenario = null }
}
