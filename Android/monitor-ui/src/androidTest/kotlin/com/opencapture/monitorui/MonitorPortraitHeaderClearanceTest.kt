package com.opencapture.monitorui

import android.view.View
import android.view.ViewTreeObserver
import android.graphics.Bitmap
import android.graphics.Color
import android.view.ViewGroup
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.requiredSize
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.height
import androidx.compose.material3.Text
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.layout.boundsInRoot
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.node.RootForTest
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.semantics.SemanticsNode
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.text.TextLayoutResult
import androidx.compose.ui.unit.dp
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import kotlin.math.ceil
import kotlin.math.floor
import org.json.JSONObject
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import androidx.compose.runtime.getValue
import androidx.compose.runtime.setValue
import kotlinx.coroutines.cancel
import org.junit.Assert.assertTrue
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith

/** SIMULATED values through the production native shared header, never a geometry-only oracle. */
@RunWith(AndroidJUnit4::class)
class MonitorPortraitHeaderClearanceTest {
    private val safeTops = listOf(0f, 24f, 30.333333f, 44f, 59f, 62f)
    @Test(timeout = 90_000) fun portraitPrimaryReadoutTopsShareOneNativeAnchor() {
        for (safeTop in safeTops) {
            ActivityScenario.launch(MonitorTestActivity::class.java).use { scenario ->
                val placed = CountDownLatch(1)
                var primary = Rect.Zero
                var canvas = Rect.Zero
                val field = MonitorLayoutPolicy.fieldMonitor(440f, 956f, safeTop = safeTop)
                scenario.onActivity { activity ->
                    activity.setContent {
                        Box(Modifier.requiredSize(440.dp, 956.dp)
                            .background(androidx.compose.ui.graphics.Color.Black)
                            .onGloballyPositioned { canvas = it.boundsInRoot() }) {
                        MonitorStatusChrome(field, MonitorStatusPresentation(false, timecode = "01:23:45"),
                            modifier = Modifier.offset(field.status.x.dp, field.status.y.dp).width(field.status.width.dp),
                            storage = {}, format = {
                                MonitorPortraitFormatGroup(true, primary = {
                                    Box(Modifier.height(48.dp).onGloballyPositioned {
                                        primary = it.boundsInRoot(); placed.countDown()
                                    }, contentAlignment = Alignment.TopEnd) {
                                        MonitorBoundedReadoutText("4K25p", maximumSize = 23f, minimumSize = 16f)
                                    }
                                }, detail = { Text("I-Log") })
                            })
                        }
                    }
                }
                assertTrue(placed.await(5, TimeUnit.SECONDS))
                awaitForegroundFrame(scenario)
                InstrumentationRegistry.getInstrumentation().waitForIdleSync()
                scenario.onActivity { activity ->
                    val nodes = nativeNodes(activity.window.decorView)
                    val recording = nodes.single { it.config.getOrNull(SemanticsProperties.ContentDescription)?.singleOrNull() == "Standby" }
                    val clock = nodes.single { it.config.getOrNull(SemanticsProperties.ContentDescription)?.singleOrNull() == "Timecode 01:23:45" }
                    android.util.Log.i("B5NativeTopAlignment", "recording=${recording.boundsInRoot} clock=${clock.boundsInRoot} primary=$primary")
                    assertEquals(recording.boundsInRoot.top, clock.boundsInRoot.top, .5f)
                    assertEquals(clock.boundsInRoot.top, primary.top, .5f)
                    assertEquals(canvas.top + field.status.y * activity.resources.displayMetrics.density,
                        clock.boundsInRoot.top, .5f)
                    assertRenderedBands(activity.window.decorView, 440f, safeTop, emptyList(),
                        listOf("status" to recording.boundsInRoot, "clock" to clock.boundsInRoot, "format" to primary))
                }
            }
        }
    }

    @Test(timeout = 90_000) fun nativeTextShrinksWithinBoundsThenEllipsizesWithoutLosingItsValue() {
        val short = "123 GB"
        val long = "123456789 GB · 100%"
        ActivityScenario.launch(MonitorTestActivity::class.java).use { scenario ->
            val placed = CountDownLatch(5)
            scenario.onActivity { activity ->
                activity.setContent {
                    Column {
                        MonitorBoundedReadoutText(short, Modifier.width(200.dp).onGloballyPositioned { placed.countDown() })
                        MonitorBoundedReadoutText(long, Modifier.width(120.dp).onGloballyPositioned { placed.countDown() })
                        MonitorBoundedReadoutText(long, Modifier.width(50.dp).onGloballyPositioned { placed.countDown() })
                        MonitorBoundedReadoutText(long, Modifier.width(400.dp).onGloballyPositioned { placed.countDown() }, maximumSize = 11f, minimumSize = 11f)
                        MonitorBoundedReadoutText(long, Modifier.width(400.dp).onGloballyPositioned { placed.countDown() }, maximumSize = 14f, minimumSize = 14f)
                    }
                }
            }
            assertTrue("Actual native text must lay out", placed.await(5, TimeUnit.SECONDS))
            InstrumentationRegistry.getInstrumentation().waitForIdleSync()
            scenario.onActivity { activity ->
                val nodes = nativeNodes(activity.window.decorView).filter {
                    it.config.getOrNull(SemanticsActions.GetTextLayoutResult)?.action != null
                }
                assertEquals(5, nodes.size)
                val results = nodes.map { node ->
                    val result = mutableListOf<TextLayoutResult>()
                    assertTrue(node.config[SemanticsActions.GetTextLayoutResult].action!!.invoke(result))
                    result.single()
                }
                // Compose's accessibility layout input rewrites the requested style. The retained
                // native paragraph supplies actual glyph metrics, compared with native 11/14sp controls.
                val glyphWidths = results.map { it.getBoundingBox(0).width }
                val minimum = glyphWidths[3]; val maximum = glyphWidths[4]
                android.util.Log.i("B5NativeText", results.mapIndexed { index, result ->
                    "glyph=${glyphWidths[index]} width=${result.size.width} ellipsis=${result.isLineEllipsized(0)} text=${result.layoutInput.text}"
                }.joinToString())
                assertEquals(maximum, glyphWidths[0], .05f)
                assertTrue("Long storage must shrink before overflow", glyphWidths[1] < maximum - .05f)
                results.take(3).forEachIndexed { index, result ->
                    assertTrue("Readable native font bounds", glyphWidths[index] >= minimum - .05f && glyphWidths[index] <= maximum + .05f)
                    assertEquals(1, result.lineCount)
                }
                assertEquals(minimum, glyphWidths[2], .05f)
                assertTrue("Overflow after the lower bound must be ellipsized", results[2].isLineEllipsized(0))
                assertEquals(listOf(short, long, long, long, long), nodes.map { it.config[SemanticsProperties.Text].single().text })
            }
        }
    }

    @Test(timeout = 90_000) fun groupedFormatAndCodecRetainNativeActionsAndMissingDetailStaysAbsent() {
        for (detailPresent in listOf(true, false)) {
            ActivityScenario.launch(MonitorTestActivity::class.java).use { scenario ->
                val placed = CountDownLatch(if (detailPresent) 2 else 1)
                var primaryCalls = 0; var detailCalls = 0
                var primaryFrame = Rect.Zero; var detailFrame = Rect.Zero
                scenario.onActivity { activity ->
                    activity.setContent {
                        MonitorPortraitFormatGroup(detailPresent, primary = {
                            Box(Modifier.height(48.dp).onGloballyPositioned { primaryFrame = it.boundsInRoot(); placed.countDown() }
                                .monitorChromeClickable { primaryCalls++ }.semantics { contentDescription = "Format" },
                                contentAlignment = Alignment.BottomEnd) {
                                MonitorBoundedReadoutText("[FX] 6K · 25p", maximumSize = 23f, minimumSize = 16f)
                            }
                        }, detail = {
                            Box(Modifier.height(48.dp).onGloballyPositioned { detailFrame = it.boundsInRoot(); placed.countDown() }
                                .monitorChromeClickable { detailCalls++ }.semantics { contentDescription = "Codec" },
                                contentAlignment = Alignment.TopEnd) {
                                MonitorBoundedReadoutText("R3D NE", maximumSize = 11f, minimumSize = 11f)
                            }
                        })
                    }
                }
                assertTrue("Actual native grouped targets must lay out", placed.await(5, TimeUnit.SECONDS))
                InstrumentationRegistry.getInstrumentation().waitForIdleSync()
                scenario.onActivity { activity ->
                    val nodes = nativeNodes(activity.window.decorView)
                    val format = nodes.single { it.config.getOrNull(SemanticsProperties.ContentDescription)?.singleOrNull() == "Format" }
                    val codec = nodes.singleOrNull { it.config.getOrNull(SemanticsProperties.ContentDescription)?.singleOrNull() == "Codec" }
                    assertTrue(nodes.any { it.config.getOrNull(SemanticsProperties.Text)?.singleOrNull()?.text == "[FX] 6K · 25p" })
                    assertTrue(format.config[SemanticsActions.OnClick].action!!.invoke())
                    assertEquals(1, primaryCalls); assertEquals(0, detailCalls)
                    if (detailPresent) {
                        requireNotNull(codec)
                        val density = activity.resources.displayMetrics.density
                        android.util.Log.i("B5NativeGroup", "drawn=$primaryFrame/$detailFrame AX=${format.boundsInRoot}/${codec.boundsInRoot}")
                        assertTrue("Detail below primary with separate target: $primaryFrame $detailFrame", detailFrame.top >= primaryFrame.bottom + 1.5f * density)
                        assertEquals("One trailing drawn column", primaryFrame.right, detailFrame.right, .5f * density)
                        assertTrue(nodes.any { it.config.getOrNull(SemanticsProperties.Text)?.singleOrNull()?.text == "R3D NE" })
                        assertTrue(codec.config[SemanticsActions.OnClick].action!!.invoke())
                        assertEquals(1, primaryCalls); assertEquals(1, detailCalls)
                    } else assertEquals(null, codec)
                }
            }
        }
    }

    @Test(timeout = 90_000) fun compactPortraitStorageAndPerformanceRemainAdjacentBeforePower() {
        for (safeTop in safeTops) {
            for (width in listOf(320f, 360f, 440f)) {
                ActivityScenario.launch(MonitorTestActivity::class.java).use { scenario ->
                    val placed = CountDownLatch(4)
                    var storage = Rect.Zero; var performance = Rect.Zero; var power = Rect.Zero
                    var density = 1f
                    var primary = Rect.Zero
                    var canvas = Rect.Zero
                    val field = MonitorLayoutPolicy.fieldMonitor(width, 700f, safeTop = safeTop, safeLeading = 20f, safeTrailing = 20f)
                    scenario.onActivity { activity ->
                        density = activity.resources.displayMetrics.density
                        activity.setContent {
                            Box(Modifier.fillMaxSize().background(androidx.compose.ui.graphics.Color.Black), contentAlignment = Alignment.TopStart) {
                            Box(Modifier.requiredSize(width.dp, 700.dp).onGloballyPositioned { canvas = it.boundsInRoot() }, contentAlignment = Alignment.TopStart) {
                                MonitorStatusChrome(field, MonitorStatusPresentation(false, timecode = "01:23:45:59"),
                                    modifier = Modifier.offset(field.status.x.dp, field.status.y.dp).width(field.status.width.dp),
                                    storage = { MonitorBoundedReadoutText("123456789 GB",
                                        modifier = Modifier.onGloballyPositioned { storage = it.boundsInRoot(); placed.countDown() }) },
                                    format = {
                                        MonitorPortraitFormatGroup(true, primary = {
                                            Box(Modifier.height(48.dp).onGloballyPositioned {
                                                primary = it.boundsInRoot(); placed.countDown()
                                            }, contentAlignment = Alignment.TopEnd) {
                                                MonitorBoundedReadoutText("[FX] 6K · 25p", maximumSize = 23f, minimumSize = 16f)
                                            }
                                        }, detail = { Text("I-Log") })
                                    },
                                    link = { MonitorTelemetry(4, "25", emptyList(), true, showsPower = false,
                                        modifier = Modifier.onGloballyPositioned { performance = it.boundsInRoot(); placed.countDown() }) })
                                MonitorTelemetry(null, null, listOf(MonitorTelemetryPower(false, 100), MonitorTelemetryPower(true, null, bars = 5)),
                                    true, showsLink = false,
                                    modifier = Modifier.offset(field.telemetry.x.dp, field.telemetry.y.dp)
                                        .onGloballyPositioned { power = it.boundsInRoot(); placed.countDown() })
                            }
                            }
                        }
                    }
                    assertTrue("Actual native layout callbacks required", placed.await(5, TimeUnit.SECONDS))
                    val top = canvas.top + (field.telemetry.y - 13f) * density
                    assertTrue("Storage leaves the restored corner band: $storage", storage.top >= top - 1)
                    assertTrue("Performance enters safe top: $performance", performance.top >= top - 1)
                    assertTrue("Power enters safe top: $power", power.top >= top - 1)
                    assertTrue("Storage must not push performance into power: $storage $performance $power",
                        storage.right + 8 * density <= performance.left + 1 && performance.right + 8 * density <= power.left + 1)
                    awaitForegroundFrame(scenario)
                    InstrumentationRegistry.getInstrumentation().waitForIdleSync()
                    scenario.onActivity { activity ->
                        val nodes = nativeNodes(activity.window.decorView)
                        val recording = nodes.single {
                            it.config.getOrNull(SemanticsProperties.ContentDescription)?.singleOrNull() == "Standby"
                        }
                        val clock = nodes.single {
                            it.config.getOrNull(SemanticsProperties.ContentDescription)?.singleOrNull() == "Timecode 01:23:45:59"
                        }
                        assertRenderedBands(activity.window.decorView, width, safeTop,
                            listOf("storage" to storage, "performance" to performance, "power" to power),
                            listOf("status" to recording.boundsInRoot, "clock" to clock.boundsInRoot, "format" to primary))
                    }
                }
            }
        }
    }



    /** Original-red selector: complete production common body, not standalone layout slots. */
    @Test(timeout = 90_000) fun productionLongPrimaryHasOneCompleteNativeRow() {
        productionPrimaryCase(360f, 0f, 0f, listOf(null))
    }

    @Test(timeout = 90_000) fun productionLongPrimaryRawInsetsAndSideSafeWidthMatrix() {
        for (width in listOf(320f, 360f, 440f)) for (side in listOf(0f, 20f)) for (top in safeTops) {
            productionPrimaryCase(width, top, side, listOf(null))
        }
    }

    @Test(timeout = 90_000) fun productionLongPrimaryRecordingDurationTransitions() {
        for (width in listOf(320f, 360f, 440f)) for (side in listOf(0f, 20f)) {
            productionPrimaryCase(width, 24f, side, listOf(9, 10, 3599, 3600, 5999, 6000))
        }
    }

    @Test(timeout = 90_000) fun productionCodecOnlyRetainsDetailFontAndAction() {
        productionPrimaryCase(360f, 24f, 20f, listOf(null), codecOnly = true)
    }

    @Test(timeout = 90_000) fun productionRecordingDoesNotReduceMainNativeFonts() {
        for (width in listOf(320f, 360f, 440f)) {
            productionPrimaryCase(width, 24f, 20f, listOf(null, 0), compareStandbyRecording = true)
        }
    }

    /** Separate physical-host adapter; original private956dp cases retain their original inputs. */
    @Test(timeout = 90_000) fun productionLongPrimaryUsesActualAvailablePhysicalHostHeight() {
        productionPrimaryCase(360f, 0f, 0f, listOf(null), useActualHostHeight = true)
    }

    private fun productionPrimaryCase(width: Float, top: Float, side: Float, durations: List<Int?>,
        codecOnly: Boolean = false, compareStandbyRecording: Boolean = false, useActualHostHeight: Boolean = false) {
        ActivityScenario.launch(MonitorTestActivity::class.java).use { scenario ->
            val scope = kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.SupervisorJob() + kotlinx.coroutines.Dispatchers.Main.immediate)
            val control = com.opencapture.opencine.appkit.MonitorControlModel(scope)
            var document: String? = null
            val store = com.opencapture.opencine.appkit.SavedCamerasStore(object : com.opencapture.opencine.appkit.StoredString {
                override fun read(): String? = document
                override fun write(value: String) { document = value }
            })
            val cameras = com.opencapture.opencine.appkit.CamerasModel(emptyList(), store, scope)
            val shell = com.opencapture.opencine.appkit.ShellModel(cameras, control)
            val assist = com.opencapture.opencine.appkit.MonitorAssistState()
            val identity = com.opencapture.opencine.cameracontrols.MonitorOperatorLiveIdentity(null, null, null,
                picture = "SIMULATED production primary")
            var elapsed by androidx.compose.runtime.mutableStateOf(durations.first())
            var primaryCalls = 0; var codecCalls = 0; var colorCalls = 0
            val placed = CountDownLatch(1)
            var fontReferences = emptyList<TextLayoutResult>()
            var standbyMainFonts = emptyMap<String, Float>()
            var canvas = Rect.Zero; var actualPicture = Rect.Zero
            var canvasHeightDp = 956f
            if (useActualHostHeight) {
                awaitForegroundFrame(scenario)
                scenario.onActivity { activity ->
                    val content = activity.findViewById<View>(android.R.id.content)
                    val density = activity.resources.displayMetrics.density
                    assertTrue("Actual available native window must be measured", content.width > 0 && content.height > 0)
                    assertTrue("Full production360width must fit the actual physical host", content.width / density >= width)
                    canvasHeightDp = content.height / density
                    android.util.Log.i("B5ActualPhysicalHostInputs", JSONObject().put("actualContentWidthPixels", content.width)
                        .put("actualContentHeightPixels", content.height).put("density", density)
                        .put("actualFontScale", activity.resources.configuration.fontScale).put("canvasWidthDp", width)
                        .put("actualAvailableHeightDp", canvasHeightDp).put("rawSafeTopDp", top)
                        .put("sideSafeDp", side).put("ownedTestOnlyHost", true).toString())
                }
            }
            val live = LiveMonitorLayout.fieldMonitor(width, canvasHeightDp, side, side, top, 0f,
                showsBottomBars = false, pictureAspect = 16f / 9f, showsValues = false)
            val field = requireNotNull(live.field)
            var session: com.opencapture.opencine.appkit.MonitorOperatorSessionModel? = null
            lateinit var storage: android.content.SharedPreferences
            try {
                scenario.onActivity { activity ->
                    storage = activity.getSharedPreferences("SIMULATED.production-header." + java.util.UUID.randomUUID(), 0)
                    val model = com.opencapture.opencine.appkit.MonitorOperatorSessionModel(shell, assist,
                        com.opencapture.opencine.appkit.MonitorDisplayPreferences(storage,
                            com.opencapture.opencine.appkit.MonitorDisplayPreferences.Keys("live", "clean")), scope)
                    session = model
                    activity.setContent {
                        val nativeMeasurer = androidx.compose.ui.text.rememberTextMeasurer()
                        fontReferences = listOf("00:48:03:23" to 10f, "00:48:03:23" to 23f,
                            "[FX] 6K · 25p" to 10f, "[FX] 6K · 25p" to 23f, "R3D NE" to 10f, "R3D NE" to 11f,
                            "D-Log2" to 10f, "D-Log2" to 23f).map { (value, size) ->
                            nativeMeasurer.measure(androidx.compose.ui.text.AnnotatedString(value),
                                style = MonitorTypography.readout(size, androidx.compose.ui.text.font.FontWeight.Medium))
                        }
                        val format = com.opencapture.opencine.appkit.MonitorOperatorLiveReadout<String, com.opencapture.opencine.appkit.MonitorDisplaySection>(
                            "format", "Recording format", "[FX] 6K · 25p", action = { primaryCalls++ }, quickEnabled = false)
                        val codec = com.opencapture.opencine.appkit.MonitorOperatorLiveReadout<String, com.opencapture.opencine.appkit.MonitorDisplaySection>(
                            if (codecOnly) "compression" else "codec", "Codec", "R3D NE",
                            section = if (codecOnly) com.opencapture.opencine.appkit.MonitorDisplaySection.CODEC else null,
                            action = { codecCalls++ }, quickEnabled = false)
                        val color = com.opencapture.opencine.appkit.MonitorOperatorLiveReadout<String, com.opencapture.opencine.appkit.MonitorDisplaySection>(
                            "color", "Color mode", "D-Log2", action = { colorCalls++ }, quickEnabled = false)
                        val inputs = com.opencapture.opencine.appkit.MonitorOperatorCaptureInputs<String, com.opencapture.opencine.appkit.MonitorDisplaySection, Nothing>(
                            emptyList(), open = {}, dismiss = {})
                        val status = com.opencapture.opencine.cameracontrols.MonitorOperatorLiveStatus(
                            recording = { MonitorStatusPresentation(elapsed != null, elapsed ?: 0, "00:48:03:23") },
                            showsTimecode = true, showsRecording = true,
                            storage = com.opencapture.opencine.appkit.MonitorOperatorLiveReadout("storage", "Storage remaining", "107 GB"),
                            format = if (codecOnly) listOf(codec) else listOf(format, codec), fps = "25 fps", signalBars = 4,
                            fpsSection = null, color = if (codecOnly) null else color)
                        val source = com.opencapture.opencine.cameracontrols.MonitorOperatorLiveSource(
                            identity = { identity }, available = if (codecOnly) setOf(
                                com.opencapture.opencine.appkit.MonitorDisplaySection.STATUS_BAR,
                                com.opencapture.opencine.appkit.MonitorDisplaySection.BATTERIES,
                                com.opencapture.opencine.appkit.MonitorDisplaySection.CODEC) else setOf(
                                com.opencapture.opencine.appkit.MonitorDisplaySection.STATUS_BAR,
                                com.opencapture.opencine.appkit.MonitorDisplaySection.BATTERIES,
                                com.opencapture.opencine.appkit.MonitorDisplaySection.COLOR),
                            picture = com.opencapture.opencine.cameracontrols.MonitorOperatorLivePicture(16f / 9f, false, false, false, false),
                            status = status, cameraBattery = com.opencapture.opencine.cameracontrols.MonitorOperatorPowerReading(true, 68),
                            capture = inputs, record = com.opencapture.opencine.cameracontrols.MonitorOperatorRecordSource(false, false, false, null),
                            exposure = null, level = null, levelViewFlip = false, audio = null, readOnly = false, borrowed = false,
                            returnToStage = null, coverOpen = false, note = null, clearNote = {}, vpnActive = { false }, settings = {}, media = {})
                        Box(Modifier.fillMaxSize().background(androidx.compose.ui.graphics.Color.Black), contentAlignment = Alignment.TopStart) {
                            Box(Modifier.requiredSize(width.dp, canvasHeightDp.dp).onGloballyPositioned { canvas = it.boundsInRoot(); placed.countDown() }) {
                                com.opencapture.opencine.cameracontrols.MonitorOperatorLiveSurface(control, model,
                                    com.opencapture.opencine.cameracontrols.MonitorOperatorLiveLayout(live, null, field.picture, field.viewport, 16f / 9f),
                                    source, com.opencapture.opencine.cameracontrols.MonitorOperatorLiveAssists(null, emptyList(), emptySet(), null,
                                        com.opencapture.opencine.cameracontrols.MonitorOperatorSignalOptions(), MonitorToolUsageState(), {}, emptyMap()),
                                    com.opencapture.opencine.cameracontrols.MonitorOperatorBodyViews(),
                                    picture = {
                                        Box(Modifier.offset(field.picture.x.dp, field.picture.y.dp)
                                            .requiredSize(field.picture.width.dp, field.picture.height.dp)
                                            .background(androidx.compose.ui.graphics.Color.Green)
                                            .semantics { contentDescription = "SIMULATED production picture" }
                                            .onGloballyPositioned { actualPicture = it.boundsInRoot() })
                                    }, cameraPanel = { _, _, _, _ -> }, photoRelease = null)
                            }
                        }
                    }
                }
                assertTrue("Actual production composition must lay out", placed.await(5, TimeUnit.SECONDS))
                for (duration in durations) {
                    scenario.onActivity { elapsed = duration }
                    awaitForegroundFrame(scenario)
                    InstrumentationRegistry.getInstrumentation().waitForIdleSync()
                    scenario.onActivity { activity ->
                        val nodes = nativeNodes(activity.window.decorView)
                        fun labeled(label: String): SemanticsNode = nodes.single {
                            it.config.getOrNull(SemanticsProperties.ContentDescription)?.singleOrNull() == label
                        }
                        val presentation = MonitorStatusPresentation(duration != null, duration ?: 0, "00:48:03:23")
                        val recording = labeled(if (duration == null) presentation.recordingAccessibilityLabel
                            else "${presentation.recordingAccessibilityLabel}, ${presentation.elapsedAccessibilityLabel}")
                        val clock = labeled("Timecode 00:48:03:23")
                        if (codecOnly) {
                            val codec = labeled("Codec")
                            val density = activity.resources.displayMetrics.density
                            val row = listOf(recording, clock, codec)
                            android.util.Log.i("B5CodecOnly", JSONObject().put("typedCodecSection", "CODEC")
                                .put("opaqueReadoutID", "compression").put("expectedCodec", "R3D NE")
                                .put("canvasWidth", width).put("rawSafeTop", top).put("sideSafe", side)
                                .put("actualNodes", nodes.map { it.config.toString() + " " + it.boundsInRoot }).toString())
                            assertRenderedBands(activity.window.decorView, width, top, emptyList(),
                                listOf("status" to recording.boundsInRoot, "clock" to clock.boundsInRoot, "codec" to codec.boundsInRoot))
                            assertTrue("FORMAT and color remain hidden", nodes.none {
                                it.config.getOrNull(SemanticsProperties.ContentDescription)?.singleOrNull() in listOf("Recording format", "Color mode")
                            })
                            row.forEach { target ->
                                assertEquals(canvas.top + field.status.y * density, target.boundsInRoot.top, .5f)
                                assertTrue("Codec-only row remains side-safe",
                                    target.boundsInRoot.left >= canvas.left + field.status.x * density - .5f &&
                                    target.boundsInRoot.right <= canvas.left + (field.status.x + field.status.width) * density + .5f)
                            }
                            row.zipWithNext().forEach { (left, right) ->
                                assertTrue("Distinct complete native targets", left.boundsInRoot.right <= right.boundsInRoot.left + .5f)
                            }
                            assertTrue("Codec native target width retained", codec.boundsInRoot.width >= 44f * density)
                            assertTrue("Codec native target height retained", codec.boundsInRoot.height >= 48f * density)
                            assertEquals(canvas.left + field.picture.x * density, actualPicture.left, .5f)
                            assertEquals(canvas.top + field.picture.y * density, actualPicture.top, .5f)
                            assertEquals(field.picture.width * density, actualPicture.width, .5f)
                            assertEquals(field.picture.height * density, actualPicture.height, .5f)
                            val text = nodes.single { it.config.getOrNull(SemanticsProperties.Text)?.singleOrNull()?.text == "R3D NE" }
                            val results = mutableListOf<TextLayoutResult>()
                            assertTrue(text.config[SemanticsActions.GetTextLayoutResult].action!!.invoke(results))
                            val result = results.single()
                            assertEquals("R3D NE", result.layoutInput.text.text)
                            assertEquals(1, result.lineCount)
                            assertTrue("Complete codec must not ellipsize or overflow",
                                !result.isLineEllipsized(0) && !result.didOverflowWidth && !result.didOverflowHeight)
                            assertEquals(6, result.getLineEnd(0, visibleEnd = false))
                            assertTrue("Codec detail font floor", result.getBoundingBox(0).height >= fontReferences[4].getBoundingBox(0).height - .5f)
                            assertTrue("Codec detail font maximum", result.getBoundingBox(0).height <= fontReferences[5].getBoundingBox(0).height + .5f)
                            for (index in "R3D NE".indices) {
                                val glyph = result.getBoundingBox(index)
                                assertTrue("Every codec glyph fits", glyph.left >= -.5f && glyph.right <= result.size.width + .5f)
                            }
                            android.util.Log.i("B5CodecOnlyNativeText", JSONObject().put("text", result.layoutInput.text.text)
                                .put("requestedFontSizeSp", result.layoutInput.style.fontSize.value)
                                .put("nativeSize", result.size.toString()).put("lineEnd", result.getLineEnd(0, false))
                                .put("overflow", result.hasVisualOverflow).put("glyphBounds",
                                    org.json.JSONArray("R3D NE".indices.map { result.getBoundingBox(it).toString() })).toString())
                            assertTrue(codec.config[SemanticsActions.OnClick].action!!.invoke())
                            assertEquals(1, codecCalls); assertEquals(0, primaryCalls); assertEquals(0, colorCalls)
                            return@onActivity
                        }
                        val format = labeled("Recording format"); val codec = labeled("Codec")
                        val availableColor = nodes.singleOrNull {
                            it.config.getOrNull(SemanticsProperties.ContentDescription)?.singleOrNull() == "Color mode"
                        }
                        android.util.Log.i("B5FiveReadoutInventory", JSONObject()
                            .put("expectedColor", "D-Log2").put("expectedCodec", "R3D NE")
                            .put("canvasWidth", width).put("rawSafeTop", top).put("sideSafe", side)
                            .put("elapsedSeconds", duration ?: JSONObject.NULL)
                            .put("nodeCount", nodes.size).toString())
                        nodes.forEachIndexed { index, node ->
                            android.util.Log.i("B5FiveReadoutNode", JSONObject()
                                .put("canvasWidth", width).put("rawSafeTop", top).put("sideSafe", side)
                                .put("elapsedSeconds", duration ?: JSONObject.NULL).put("index", index)
                                .put("descriptions", node.config.getOrNull(SemanticsProperties.ContentDescription).toString())
                                .put("text", node.config.getOrNull(SemanticsProperties.Text).toString())
                                .put("value", node.config.getOrNull(SemanticsProperties.StateDescription) ?: JSONObject.NULL)
                                .put("bounds", node.boundsInRoot.toString()).toString())
                        }
                        val density = activity.resources.displayMetrics.density
                        android.util.Log.i("B5ProductionPrimary", JSONObject().put("canvasWidth", width).put("rawSafeTop", top)
                            .put("sideSafe", side).put("elapsedSeconds", duration ?: JSONObject.NULL)
                            .put("statusAnchorPixels", canvas.top + field.status.y * density)
                            .put("recordingBounds", recording.boundsInRoot.toString()).put("clockBounds", clock.boundsInRoot.toString())
                            .put("formatBounds", format.boundsInRoot.toString()).put("codecBounds", codec.boundsInRoot.toString())
                            .put("colorBounds", availableColor?.boundsInRoot?.toString() ?: JSONObject.NULL)
                            .put("actualPictureBounds", actualPicture.toString()).put("expectedRawPicture", field.picture.toString()).toString())
                        // Preserve native foreground pixels before the absent original color can fail.
                        val painted = listOf("status" to recording.boundsInRoot, "clock" to clock.boundsInRoot,
                            "format" to format.boundsInRoot, "codec" to codec.boundsInRoot) +
                            listOfNotNull(availableColor?.let { "color" to it.boundsInRoot })
                        assertRenderedBands(activity.window.decorView, width, top, emptyList(), painted)
                        val originalImage = activity.cacheDir.resolve("b5-header-width-$width-raw-$top.png")
                        val uniqueImage = activity.cacheDir.resolve("b5-production-width-$width-raw-$top-side-$side-elapsed-${duration ?: "STBY"}.png")
                        originalImage.copyTo(uniqueImage, overwrite = true)
                        android.util.Log.i("B5ProductionImage", JSONObject().put("image", uniqueImage.absolutePath)
                            .put("canvasWidth", width).put("rawSafeTop", top).put("sideSafe", side)
                            .put("elapsedSeconds", duration ?: JSONObject.NULL).toString())
                        // Diagnostics precede unchanged geometry guards; a failing width remains a failing case.
                        val nativeParagraphs = nodes.mapNotNull { node ->
                            val value = node.config.getOrNull(SemanticsProperties.Text)?.singleOrNull()?.text
                            if (value !in listOf("[FX] 6K · 25p", "D-Log2", "R3D NE")) null
                            else {
                                val results = mutableListOf<TextLayoutResult>()
                                val supplied = node.config.getOrNull(SemanticsActions.GetTextLayoutResult)?.action?.invoke(results) == true
                                results.singleOrNull()?.takeIf { supplied }?.let { result ->
                                    JSONObject().put("literal", value).put("requestedFontSizeSp", result.layoutInput.style.fontSize.value)
                                        .put("requestedLetterSpacing", result.layoutInput.style.letterSpacing.toString())
                                        .put("nativeSize", result.size.toString()).put("paragraphWidth", result.multiParagraph.width)
                                        .put("constraints", result.layoutInput.constraints.toString()).put("didOverflowWidth", result.didOverflowWidth)
                                        .put("didOverflowHeight", result.didOverflowHeight).put("lineEnd", result.getLineEnd(0, false))
                                        .put("nativeBounds", node.boundsInRoot.toString())
                                }
                            }
                        }
                        android.util.Log.i("B5NativeBeforeGeometryGuard", JSONObject().put("canvasWidth", width)
                            .put("rawSafeTop", top).put("sideSafe", side).put("elapsedSeconds", duration ?: JSONObject.NULL)
                            .put("density", density).put("actualFontScale", activity.resources.configuration.fontScale)
                            .put("canvasBoundsPixels", canvas.toString()).put("nativeStatusRectDp", field.status.toString())
                            .put("statusWidthDp", field.status.width).put("paragraphs", org.json.JSONArray(nativeParagraphs)).toString())
                        val color = requireNotNull(availableColor) { "Production Color mode must remain present with D-Log2" }
                        assertEquals(recording.boundsInRoot.top, clock.boundsInRoot.top, .5f)
                        assertEquals(clock.boundsInRoot.top, format.boundsInRoot.top, .5f)
                        assertEquals(canvas.top + field.status.y * density, clock.boundsInRoot.top, .5f)
                        for (target in listOf(format, color, codec)) {
                            assertTrue("Original native target width retained", target.boundsInRoot.width >= 44f * density)
                            assertTrue("Original native target height retained", target.boundsInRoot.height >= 48f * density)
                        }
                        val row = listOf(recording, clock, format, color, codec)
                        row.forEach { target ->
                            assertEquals(canvas.top + field.status.y * density, target.boundsInRoot.top, .5f)
                            assertTrue("All native row frames remain inside side-safe width",
                                target.boundsInRoot.left >= canvas.left + field.status.x * density - .5f &&
                                target.boundsInRoot.right <= canvas.left + (field.status.x + field.status.width) * density + .5f)
                        }
                        row.zipWithNext().forEach { (left, right) ->
                            assertTrue("Each complete readout owns a horizontal native target",
                                left.boundsInRoot.right <= right.boundsInRoot.left + .5f)
                        }
                        assertEquals(canvas.left + field.picture.x * density, actualPicture.left, .5f)
                        assertEquals(canvas.top + field.picture.y * density, actualPicture.top, .5f)
                        assertEquals(field.picture.width * density, actualPicture.width, .5f)
                        assertEquals(field.picture.height * density, actualPicture.height, .5f)
                        assertEquals(8, fontReferences.size)
                        assertTrue("Actual clock font remains above reviewed native 10sp portrait floor",
                            clock.boundsInRoot.height >= fontReferences[0].size.height - .5f)
                        assertTrue("Actual clock font remains below native 23sp maximum",
                            clock.boundsInRoot.height <= fontReferences[1].size.height + .5f)
                        // Clock intentionally clears its Text semantics. Its full eleven-character
                        // paint is independently validated from the original PNG and bounded native frame.
                        val mainFonts = mutableMapOf("clockNativeHeightPixels" to clock.boundsInRoot.height)
                        for (value in listOf("[FX] 6K · 25p", "D-Log2", "R3D NE")) {
                            val textNode = nodes.single { it.config.getOrNull(SemanticsProperties.Text)?.singleOrNull()?.text == value }
                            val results = mutableListOf<TextLayoutResult>()
                            assertTrue("Actual native paragraph required", textNode.config[SemanticsActions.GetTextLayoutResult].action!!.invoke(results))
                            val result = results.single()
                            if (value != "R3D NE") mainFonts[value + "NativeSizeSp"] = result.layoutInput.style.fontSize.value
                            assertEquals(value, result.layoutInput.text.text)
                            assertEquals(1, result.lineCount)
                            assertTrue("Full value must not ellipsize", !result.isLineEllipsized(0))
                            android.util.Log.i("B5NativeParagraphBeforeOverflow", JSONObject().put("text", value)
                                .put("requestedFontSizeSp", result.layoutInput.style.fontSize.value)
                                .put("nativeSize", result.size.toString()).put("constraints", result.layoutInput.constraints.toString())
                                .put("paragraphWidth", result.multiParagraph.width).put("paragraphHeight", result.multiParagraph.height)
                                .put("paragraphMaxIntrinsicWidth", result.multiParagraph.intrinsics.maxIntrinsicWidth)
                                .put("deviceDensity", density).put("nativeFirstGlyphHeight", result.getBoundingBox(0).height)
                                .put("didOverflowWidth", result.didOverflowWidth).put("didOverflowHeight", result.didOverflowHeight)
                                .put("hasVisualOverflow", result.hasVisualOverflow).put("lineCount", result.lineCount)
                                .put("lineWidth", result.getLineRight(0) - result.getLineLeft(0))
                                .put("lineEnd", result.getLineEnd(0, false)).put("ellipsis", result.isLineEllipsized(0))
                                .put("actualFontScale", activity.resources.configuration.fontScale)
                                .put("glyphBounds", org.json.JSONArray(value.indices.map { result.getBoundingBox(it).toString() })).toString())
                            assertTrue("Full value must not overflow", !result.didOverflowWidth && !result.didOverflowHeight)
                            assertEquals(value.length, result.getLineEnd(0, visibleEnd = false))
                            // Actual paragraph glyphs supplement the retained native layout input.
                            assertTrue("Native glyphs must have positive height", result.getBoundingBox(0).height > 0f)
                            val floorIndex = when (value) { "R3D NE" -> 4; "D-Log2" -> 6; else -> 2 }
                            val upperIndex = when (value) { "R3D NE" -> 5; "D-Log2" -> 7; else -> 3 }
                            assertTrue("Actual native paragraph font floor",
                                result.getBoundingBox(0).height >= fontReferences[floorIndex].getBoundingBox(0).height - .5f)
                            assertTrue("Actual native paragraph font maximum",
                                result.getBoundingBox(0).height <= fontReferences[upperIndex].getBoundingBox(0).height + .5f)
                            for (index in value.indices) {
                                val glyph = result.getBoundingBox(index)
                                assertTrue("Actual complete glyph $index of $value", glyph.left >= -.5f && glyph.right <= result.size.width + .5f)
                            }
                            android.util.Log.i("B5ProductionNativeText", JSONObject().put("text", value).put("size", result.size.toString())
                                .put("lineEnd", result.getLineEnd(0, false)).put("ellipsis", result.isLineEllipsized(0))
                                .put("requestedFontSizeSp", result.layoutInput.style.fontSize.value)
                                .put("actualFontScale", activity.resources.configuration.fontScale)
                                .put("glyphBounds", org.json.JSONArray(value.indices.map { result.getBoundingBox(it).toString() })).toString())
                        }
                        if (compareStandbyRecording) {
                            if (duration == null) standbyMainFonts = mainFonts.toMap()
                            else {
                                assertEquals(mainFonts.keys, standbyMainFonts.keys)
                                mainFonts.forEach { (fieldName, actual) ->
                                    assertTrue("REC must retain or increase actual main font for $fieldName", actual >= standbyMainFonts.getValue(fieldName))
                                }
                                android.util.Log.i("B5RecordingNativeFontNondecrease", JSONObject().put("canvasWidth", width)
                                    .put("rawSafeTop", top).put("sideSafe", side).put("standby", JSONObject(standbyMainFonts))
                                    .put("recording", JSONObject(mainFonts)).toString())
                            }
                        }
                        val beforePrimary = primaryCalls; val beforeCodec = codecCalls; val beforeColor = colorCalls
                        assertTrue(format.config[SemanticsActions.OnClick].action!!.invoke())
                        assertEquals(beforePrimary + 1, primaryCalls); assertEquals(beforeCodec, codecCalls)
                        assertTrue(codec.config[SemanticsActions.OnClick].action!!.invoke())
                        assertEquals(beforePrimary + 1, primaryCalls); assertEquals(beforeCodec + 1, codecCalls)
                        assertEquals(beforeColor, colorCalls)
                        assertTrue(color.config[SemanticsActions.OnClick].action!!.invoke())
                        assertEquals(beforeColor + 1, colorCalls)
                        assertEquals(beforePrimary + 1, primaryCalls); assertEquals(beforeCodec + 1, codecCalls)
                    }
                }
            } finally {
                scenario.onActivity { session?.close(); control.unbind(); storage.edit().clear().commit() }
                scope.cancel()
            }
        }
    }

    /** Focus and a submitted hardware frame precede the unchanged foreground screenshot oracle. */
    private fun awaitForegroundFrame(scenario: ActivityScenario<MonitorTestActivity>) {
        val focused = CountDownLatch(1)
        var focusOwner: ViewTreeObserver? = null
        val focusListener = ViewTreeObserver.OnWindowFocusChangeListener { hasFocus ->
            if (hasFocus) focused.countDown()
        }
        scenario.onActivity { activity ->
            val decor = activity.window.decorView
            val observer = decor.viewTreeObserver
            focusOwner = observer
            observer.addOnWindowFocusChangeListener(focusListener)
            if (decor.isShown && decor.hasWindowFocus()) focused.countDown()
        }
        try {
            assertTrue("Actual native window focus required", focused.await(5, TimeUnit.SECONDS))
            val committed = CountDownLatch(1)
            val frameCallback = Runnable { committed.countDown() }
            var frameOwner: ViewTreeObserver? = null
            scenario.onActivity { activity ->
                val decor = activity.window.decorView
                assertTrue("Native hardware frame required", decor.isHardwareAccelerated)
                frameOwner = decor.viewTreeObserver
                decor.viewTreeObserver.registerFrameCommitCallback(frameCallback)
                decor.invalidate()
            }
            try {
                assertTrue("Current native frame must commit", committed.await(5, TimeUnit.SECONDS))
            } finally {
                scenario.onActivity {
                    frameOwner?.takeIf { it.isAlive }?.unregisterFrameCommitCallback(frameCallback)
                }
            }
        } finally {
            scenario.onActivity {
                focusOwner?.takeIf { it.isAlive }?.removeOnWindowFocusChangeListener(focusListener)
            }
        }
    }

    /** Actual foreground pixels supplement native bounds; a black/system capture cannot pass. */
    private fun assertRenderedBands(decor: View, width: Float, safeTop: Float,
        upper: List<Pair<String, Rect>>, lower: List<Pair<String, Rect>>) {
        assertTrue("Native test window must be foreground", decor.isShown && decor.hasWindowFocus())
        fun root(view: View): View? {
            if (view is RootForTest) return view
            return if (view is ViewGroup) (0 until view.childCount).firstNotNullOfOrNull {
                root(view.getChildAt(it))
            } else null
        }
        val composeRoot = requireNotNull(root(decor))
        val origin = IntArray(2).also(composeRoot::getLocationOnScreen)
        val shot = requireNotNull(InstrumentationRegistry.getInstrumentation().uiAutomation.takeScreenshot()) {
            "Native screenshot is unavailable"
        }
        try {
            android.util.Log.i("B5NativeCaptureOwner", JSONObject()
                .put("rawSafeTop", safeTop).put("canvasWidth", width)
                .put("rootOriginPixels", org.json.JSONArray(origin.toList()))
                .put("screenshotSizePixels", org.json.JSONArray(listOf(shot.width, shot.height)))
                .put("decorShown", decor.isShown).put("windowHasFocus", decor.hasWindowFocus())
                .put("nativeFramesInRoot", (upper + lower).toString()).toString())
            val file = decor.context.cacheDir.resolve("b5-header-width-$width-raw-$safeTop.png")
            file.outputStream().use { assertTrue(shot.compress(Bitmap.CompressFormat.PNG, 100, it)) }
            fun ink(frame: Rect): Rect {
                val left = floor(frame.left + origin[0]).toInt()
                val right = ceil(frame.right + origin[0]).toInt()
                val top = floor(frame.top + origin[1]).toInt()
                val bottom = ceil(frame.bottom + origin[1]).toInt()
                assertTrue("Full native frame must be inside screenshot: $frame",
                    left >= 0 && right <= shot.width && top >= 0 && bottom <= shot.height)
                var minX = right; var minY = bottom; var maxX = left - 1; var maxY = top - 1
                var inkPixels = 0
                for (y in top until bottom) for (x in left until right) {
                    val pixel = shot.getPixel(x, y)
                    // Bright glyphs include the actual colored signal bars; faint glass is excluded.
                    if (maxOf(Color.red(pixel), Color.green(pixel), Color.blue(pixel)) >= 160) {
                        inkPixels++
                        minX = minOf(minX, x); minY = minOf(minY, y)
                        maxX = maxOf(maxX, x); maxY = maxOf(maxY, y)
                    }
                }
                assertTrue("No native ink in $frame; black captures cannot pass", maxX >= minX && maxY >= minY)
                assertTrue("Solid light/system frame cannot substitute for native glyphs",
                    inkPixels.toDouble() / ((right - left) * (bottom - top)) < 0.8)
                return Rect(minX.toFloat(), minY.toFloat(), (maxX + 1).toFloat(), (maxY + 1).toFloat())
            }
            val upperInk = upper.map { it.first to ink(it.second) }
            val lowerInk = lower.map { it.first to ink(it.second) }
            val proof = JSONObject().put("rawSafeTop", safeTop).put("canvasWidth", width)
                .put("image", file.absolutePath).put("nativeTopTolerancePixels", .5f)
                .put("upperInkPixels", upperInk.toString()).put("statusInkPixels", lowerInk.toString())
            android.util.Log.i("B5NativeRenderedBands", proof.toString())
            for ((name, frame) in upperInk) for ((readout, primary) in lowerInk) {
                assertTrue("$name drawn glyphs overlap $readout at raw inset $safeTop",
                    frame.bottom <= primary.top)
            }
        } finally { shot.recycle() }
    }

    private fun nativeNodes(view: View): List<SemanticsNode> {
        if (view is RootForTest) {
            fun walk(node: SemanticsNode): List<SemanticsNode> = listOf(node) + node.children.flatMap(::walk)
            return walk(view.semanticsOwner.unmergedRootSemanticsNode)
        }
        return if (view is ViewGroup) (0 until view.childCount).flatMap { nativeNodes(view.getChildAt(it)) } else emptyList()
    }
}
