package com.opencapture.monitorui

import android.app.UiAutomation
import android.graphics.Rect
import android.os.SystemClock
import android.view.MotionEvent
import android.view.accessibility.AccessibilityNodeInfo
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.ui.Modifier
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.setValue
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.opencapture.opencine.appkit.*
import com.opencapture.opencine.cameracontrols.*
import com.opencapture.opencine.media.*
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.nio.file.Files

/** SIMULATED held source, actual catalog and real pointer input. No camera qualification. */
@RunWith(AndroidJUnit4::class)
class MonitorMediaDeletionOverlayTest {
    private var diagnosticState: (() -> Unit)? = null
    @Test fun singleItemProgressBlocksTheOriginalCloseCoordinate() = check(1, 0, 1, "0 of 1")
    @Test fun expandedCompanionProgressBlocksTheOriginalCloseCoordinate() =
        check(6, 2, 3, "2 of 6 files · incl. RAW + copies")

    private fun check(total: Int, completed: Int, selected: Int, detail: String) {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        assertTrue("The private test device must enter landscape before the activity is created",
            instrumentation.uiAutomation.setRotation(UiAutomation.ROTATION_FREEZE_90))
        val root = Files.createTempDirectory("SIMULATED-Z7-deletion-").toFile()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
        val gate = CompletableDeferred<Unit>()
        var closes = 0
        var revision by mutableIntStateOf(0)
        var initialized = false
        lateinit var library: MonitorMediaLibraryModel<String>
        val codec = object : MonitorMediaCatalogCodec<String> {
            override fun decode(bytes: ByteArray): List<MonitorMediaRecord<String>> = emptyList()
            override fun encode(records: List<MonitorMediaRecord<String>>) = byteArrayOf()
            override fun capture(asset: MediaAsset, binding: MediaBrowseBinding): MonitorMediaRecord<String> =
                throw MediaServiceException(MediaServiceFailure.UNSUPPORTED)
        }
        val favorites = object : MonitorMediaFavoritesStore {
            override fun favorites(): Set<String> = emptySet()
            override fun saveFavorites(keys: Set<String>) = Unit
        }
        try {
            ActivityScenario.launch(MonitorTestActivity::class.java).use { scenario ->
                scenario.onActivity { activity ->
                    library = MonitorMediaLibraryModel(MonitorMediaCache(MonitorMediaCacheDirectory(root), codec,
                        MonitorMediaOriginalEligibility.ExactSize, "index.json", listOf("index.json")), favorites, scope = scope)
                    initialized = true
                    library.begin()
                    activity.setContent {
                        key(revision) {
                        MonitorOperatorCatalogScreen(library, "SIMULATED deletion", false,
                            MonitorMediaGalleryOperations<String>(),
                            deletionDetail = { value -> if (value.total > value.selectedCount)
                                "${value.completed} of ${value.total} files · incl. RAW + copies" else null },
                            facts = { MonitorMediaGalleryFileFacts("SIMULATED", null, null) },
                            begin = {}, close = { closes += 1; revision += 1 }, open = {},
                            thumbnail = { Box(Modifier.fillMaxSize()) })
                        }
                    }
                }
                diagnosticState = {
                    scenario.onActivity { activity ->
                        println("Z7_OWNER_STATE closes=$closes revision=$revision state=${library.state.value} lifecycle=${activity.lifecycle.currentState} focus=${activity.hasWindowFocus()} viewport=${activity.window.decorView.width}x${activity.window.decorView.height} shown=${activity.window.decorView.isShown}")
                    }
                }
                val close = awaitNode("Close")
                scenario.onActivity { activity ->
                    assertTrue("Verify the actual catalog in landscape first",
                        activity.window.decorView.width > activity.window.decorView.height)
                }
                val bounds = Rect().also(close::getBoundsInScreen)
                tap(bounds)
                instrumentation.waitForIdleSync()
                scenario.onActivity { assertEquals("The original coordinate must exercise Close", 1, closes) }
                scenario.onActivity {
                    val authority = library.captureDeletion(MonitorMediaLibraryIOKey("SIMULATED-delete")) { true }
                    scope.launch {
                        println("Z7_DELETE_ENTER admitted=${authority.isCurrent}")
                        val removed = library.deleteHostBatch(authority,
                            (0 until total).map { MonitorMediaDeletionTarget(it, listOf(it)) }, selected,
                            port = MonitorMediaDeletionPort(remove = { value ->
                                println("Z7_REMOVE value=$value admitted=${authority.isCurrent}")
                                if (value == completed) gate.await()
                                MonitorMediaDeleteAcknowledgement.REMOVED
                            }, commit = { _, _ -> true }))
                        println("Z7_DELETE_RETURN removed=$removed")
                    }
                }
                val title = "Deleting $selected ${if (selected == 1) "item" else "items"}…"
                awaitNode(title)
                awaitNode(detail)
                screenshot("SIMULATED-deletion-$selected-$total-before-tap")
                tap(bounds)
                instrumentation.waitForIdleSync()
                scenario.onActivity { assertEquals("The actual overlay must swallow the original Close tap", 1, closes) }
                awaitNode(title)
                awaitNode(detail)
                screenshot("SIMULATED-deletion-$selected-$total-after-tap")
            }
        } finally {
            instrumentation.runOnMainSync { scope.cancel(); if (initialized) library.close() }
            gate.complete(Unit)
            root.deleteRecursively()
            assertTrue(instrumentation.uiAutomation.setRotation(UiAutomation.ROTATION_UNFREEZE))
        }
    }
    private fun tap(bounds: Rect) {
        val automation = InstrumentationRegistry.getInstrumentation().uiAutomation
        val down = SystemClock.uptimeMillis()
        for (action in listOf(MotionEvent.ACTION_DOWN, MotionEvent.ACTION_UP)) {
            val event = MotionEvent.obtain(down, SystemClock.uptimeMillis(), action,
                bounds.exactCenterX(), bounds.exactCenterY(), 0)
            event.source = android.view.InputDevice.SOURCE_TOUCHSCREEN
            try { assertTrue(automation.injectInputEvent(event, true)) } finally { event.recycle() }
        }
    }
    private fun awaitNode(label: String): AccessibilityNodeInfo {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val deadline = SystemClock.uptimeMillis() + 5_000
        var acknowledgedImmersiveTutorial = false
        do {
            instrumentation.waitForIdleSync()
            val pending = ArrayDeque<AccessibilityNodeInfo>()
            instrumentation.uiAutomation.rootInActiveWindow?.let(pending::add)
            var visited = 0
            var immersiveTutorial = false
            var gotIt: AccessibilityNodeInfo? = null
            while (pending.isNotEmpty() && visited++ < 5_000) {
                val node = pending.removeFirst()
                if (node.isVisibleToUser && node.text?.toString() == "Viewing full screen") immersiveTutorial = true
                if (node.isVisibleToUser && node.text?.toString() == "Got it" && node.isClickable) gotIt = node
                if (node.isVisibleToUser && (node.text?.toString() == label || node.contentDescription?.toString() == label)) return node
                for (i in 0 until node.childCount) node.getChild(i)?.let(pending::add)
            }
            if (!acknowledgedImmersiveTutorial && immersiveTutorial && gotIt != null) {
                // Only the fresh emulator's identified system tutorial is acknowledged.
                assertTrue(gotIt.performAction(AccessibilityNodeInfo.ACTION_CLICK))
                acknowledgedImmersiveTutorial = true
                println("Z7_ACK_IMMERSIVE_TUTORIAL")
            }
            Thread.yield()
        } while (SystemClock.uptimeMillis() < deadline)
        diagnosticState?.invoke()
        runCatching { screenshot("SIMULATED-missing-${label.hashCode()}") }
            .onFailure { println("Z7_SCREENSHOT_FAILURE $it") }
        val pending = ArrayDeque<AccessibilityNodeInfo>()
        instrumentation.uiAutomation.rootInActiveWindow?.let(pending::add)
        var visited = 0
        while (pending.isNotEmpty() && visited++ < 200) {
            val node = pending.removeFirst()
            val bounds = Rect().also(node::getBoundsInScreen)
            println("Z7_AX visible=${node.isVisibleToUser} text=${node.text} description=${node.contentDescription} bounds=$bounds class=${node.className}")
            for (i in 0 until node.childCount) node.getChild(i)?.let(pending::add)
        }
        throw AssertionError("Actual shared catalog must visibly show: $label")
    }
    private fun screenshot(name: String) {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val bitmap = requireNotNull(instrumentation.uiAutomation.takeScreenshot())
        val directory = java.io.File(instrumentation.context.getExternalFilesDir(null), "z7-media")
        directory.mkdirs()
        directory.resolve("$name.png").outputStream().use {
            bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it)
        }
        bitmap.recycle()
    }
}
