package com.opencapture.monitorui

import android.view.View
import android.view.ViewTreeObserver
import android.graphics.Bitmap
import android.graphics.Color
import android.view.ViewGroup
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.clickable
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
import androidx.compose.ui.platform.testTag
import com.opencapture.opencine.appkit.chromeEditable
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
import androidx.compose.ui.text.font.FontWeight
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
import org.junit.Assert.assertFalse
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
                        // The detail line starts where the primary line's own height ends (here a fixed 48dp box).
                        assertTrue("Detail below primary with separate target: $primaryFrame $detailFrame", detailFrame.top >= primaryFrame.bottom - .5f)
                        assertEquals("One trailing drawn column", primaryFrame.right, detailFrame.right, .5f * density)
                        assertTrue(nodes.any { it.config.getOrNull(SemanticsProperties.Text)?.singleOrNull()?.text == "R3D NE" })
                        assertTrue(codec.config[SemanticsActions.OnClick].action!!.invoke())
                        assertEquals(1, primaryCalls); assertEquals(1, detailCalls)
                    } else assertEquals(null, codec)
                }
            }
        }
    }

    @Test(timeout = 90_000) fun explicitTelemetryMetricsKeepNativeDimensionsAndPhoneTabletTypography() {
        ActivityScenario.launch(MonitorTestActivity::class.java).use { scenario ->
            val placed = CountDownLatch(5)
            var phone = Rect.Zero; var tablet = Rect.Zero; var nativeDefault = Rect.Zero
            var phoneReference = Rect.Zero; var tabletReference = Rect.Zero
            var density = 1f
            scenario.onActivity { activity ->
                density = activity.resources.displayMetrics.density
                activity.setContent {
                    Column(Modifier.fillMaxSize().background(androidx.compose.ui.graphics.Color.Black)) {
                        MonitorTelemetry(null, null, listOf(MonitorTelemetryPower(false, 100)), true,
                            modifier = Modifier.onGloballyPositioned { phone = it.boundsInRoot(); placed.countDown() },
                            showsLink = false, metrics = MonitorTelemetryMetrics.PHONE)
                        MonitorTelemetry(null, null, listOf(MonitorTelemetryPower(false, 100)), true,
                            modifier = Modifier.onGloballyPositioned { tablet = it.boundsInRoot(); placed.countDown() },
                            showsLink = false, metrics = MonitorTelemetryMetrics.TABLET)
                        MonitorTelemetry(null, null, listOf(MonitorTelemetryPower(false, 100)), true,
                            modifier = Modifier.onGloballyPositioned { nativeDefault = it.boundsInRoot(); placed.countDown() },
                            showsLink = false)
                        Text("100%", color = androidx.compose.ui.graphics.Color.White,
                            style = MonitorTypography.readout(10f, FontWeight.Bold),
                            modifier = Modifier.onGloballyPositioned { phoneReference = it.boundsInRoot(); placed.countDown() })
                        Text("100%", color = androidx.compose.ui.graphics.Color.White,
                            style = MonitorTypography.readout(11f, FontWeight.Bold),
                            modifier = Modifier.onGloballyPositioned { tabletReference = it.boundsInRoot(); placed.countDown() })
                    }
                }
            }
            assertTrue("Actual native metric cases and font references must lay out", placed.await(5, TimeUnit.SECONDS))
            awaitForegroundFrame(scenario)
            InstrumentationRegistry.getInstrumentation().waitForIdleSync()
            scenario.onActivity { activity ->
                val nodes = nativeNodes(activity.window.decorView).filter {
                    it.config.getOrNull(SemanticsProperties.Text)?.singleOrNull()?.text == "100%"
                        && it.config.getOrNull(SemanticsActions.GetTextLayoutResult)?.action != null
                }.sortedBy { it.boundsInRoot.top }
                assertEquals(5, nodes.size)
                val glyphWidths = nodes.map { node ->
                    val results = mutableListOf<TextLayoutResult>()
                    assertTrue(node.config[SemanticsActions.GetTextLayoutResult].action!!.invoke(results))
                    results.single().getBoundingBox(0).width
                }
                assertTrue("The native 11sp reference must reject reduction to 10sp", glyphWidths[4] > glyphWidths[3] + .05f)
                assertEquals(glyphWidths[3], glyphWidths[0], .05f)
                assertEquals(glyphWidths[4], glyphWidths[1], .05f)
                assertEquals(glyphWidths[3], glyphWidths[2], .05f)
                for ((actual, width, height) in listOf(
                    Triple(phone, 58f, 20f), Triple(tablet, 64f, 22f), Triple(nativeDefault, 58f, 20f))) {
                    assertEquals(width * density, actual.width, .5f)
                    assertEquals(height * density, actual.height, .5f)
                }
                android.util.Log.i("B5NativeTelemetryMetrics",
                    "phone=$phone tablet=$tablet default=$nativeDefault glyphWidths=$glyphWidths density=$density")
                assertRenderedBands(activity.window.decorView, 320f, 0f,
                    listOf("phone" to phone, "tablet" to tablet, "default" to nativeDefault),
                    listOf("phone reference" to phoneReference, "tablet reference" to tabletReference))
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
                                        metrics = MonitorTelemetryMetrics.PHONE,
                                        modifier = Modifier.onGloballyPositioned { performance = it.boundsInRoot(); placed.countDown() }) })
                                MonitorTelemetry(null, null, listOf(MonitorTelemetryPower(false, 100), MonitorTelemetryPower(true, null, bars = 5)),
                                    true, showsLink = false,
                                    metrics = MonitorTelemetryMetrics.PHONE,
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



    /**
     * SIMULATED centred top cutouts (a punch hole and a wide pill) on portrait phones: a long
     * remaining-shots or storage readout must never push the link pill into the housing.
     */
    @Test(timeout = 300_000) fun longShotsAndStorageKeepTheLinkPillLeftOfTheTopCutout() {
        val phones = listOf(Triple(393f, 852f, 59f), Triple(412f, 915f, 52f), Triple(440f, 956f, 62f))
        for ((width, height, safeTop) in phones) for (cutoutWidth in listOf(26f, 60f)) {
            for ((value, icon) in listOf("99.9k" to MonitorIcon.IMAGE, "99999 SHOTS" to MonitorIcon.CARD_SIM,
                "123456789 GB" to MonitorIcon.CARD_SIM)) {
                ActivityScenario.launch(MonitorTestActivity::class.java).use { scenario ->
                    val placed = CountDownLatch(2)
                    var storage = Rect.Zero; var performance = Rect.Zero; var canvas = Rect.Zero
                    var density = 1f
                    val field = MonitorLayoutPolicy.fieldMonitor(width, height, safeTop = safeTop)
                    val cutout = MonitorRect((width - cutoutWidth) / 2f, 11f, cutoutWidth, 40f)
                    scenario.onActivity { activity ->
                        density = activity.resources.displayMetrics.density
                        activity.setContent {
                            Box(Modifier.fillMaxSize().background(androidx.compose.ui.graphics.Color.Black)) {
                                Box(Modifier.requiredSize(width.dp, height.dp).onGloballyPositioned { canvas = it.boundsInRoot() }) {
                                    MonitorCompactTelemetryRow(field, 0f, 0f, MonitorTelemetryMetrics.PHONE, topCutout = cutout,
                                        storage = {
                                            Row(Modifier.onGloballyPositioned { storage = it.boundsInRoot(); placed.countDown() },
                                                horizontalArrangement = Arrangement.spacedBy(5.dp)) {
                                                MonitorIcon(icon, null, Modifier.size(14.dp), MonitorPalette.muted)
                                                MonitorBoundedReadoutText(value)
                                            }
                                        },
                                        link = { MonitorTelemetry(4, "25", emptyList(), true, showsPower = false,
                                            metrics = MonitorTelemetryMetrics.PHONE,
                                            modifier = Modifier.onGloballyPositioned { performance = it.boundsInRoot(); placed.countDown() }) },
                                        power = { MonitorTelemetry(null, null, listOf(MonitorTelemetryPower(false, 100),
                                            MonitorTelemetryPower(true, 68)), true, showsLink = false, metrics = MonitorTelemetryMetrics.PHONE) })
                                }
                            }
                        }
                    }
                    assertTrue("Actual native layout callbacks required", placed.await(5, TimeUnit.SECONDS))
                    InstrumentationRegistry.getInstrumentation().waitForIdleSync()
                    val left = canvas.left + cutout.x * density
                    assertTrue("The witness must place the link pill in the cutout's band: $performance",
                        performance.top < canvas.top + cutout.maxY * density && performance.bottom > canvas.top + cutout.y * density)
                    assertTrue("$value must not push the link pill into the cutout ($width x $height, $cutoutWidth): $performance",
                        performance.right <= left + 1)
                    assertTrue("$value: $storage $performance", storage.right <= performance.left + 1)
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

    @Test(timeout = 90_000) fun portraitTypedFormatMovesColorIntoCodecAndRetainsColorOnlyAccess() {
        for (colorOnly in listOf(false, true))
            productionPrimaryCase(360f, 62f, 0f, listOf(null), typedPortraitHeader = true, colorOnly = colorOnly)
    }

    @Test(timeout = 90_000) fun productionCodecOnlyRetainsDetailFontAndAction() {
        productionPrimaryCase(360f, 24f, 20f, listOf(null), codecOnly = true)
    }

    @Test(timeout = 90_000) fun productionRecordingDoesNotReduceMainNativeFonts() {
        for (width in listOf(320f, 360f, 440f)) {
            productionPrimaryCase(width, 24f, 20f, listOf(null, 0), compareStandbyRecording = true)
        }
    }

    /** Full available host height; other cases cap their original956dp canvas to the native window. */
    @Test(timeout = 90_000) fun productionLongPrimaryUsesActualAvailablePhysicalHostHeight() {
        productionPrimaryCase(360f, 0f, 0f, listOf(null), useActualHostHeight = true)
    }

    @Test(timeout = 90_000) fun expandedPrimaryAndDetailReceiveIndependentNativeTaps() {
        productionPrimaryCase(360f, 24f, 20f, listOf(null), verifyNativeTaps = true)
    }

    @Test(timeout = 90_000) fun lowSafeTopPortraitTargetsStayInsideViewportWithoutMovingPictureOrTelemetry() {
        for (top in listOf(0f, 8f, 24f)) {
            val rails = mutableMapOf<String, Rect>()
            productionPrimaryCase(600f, top, 0f, listOf(null), codecOnly = true, captureRails = rails)
            productionPrimaryCase(600f, top, 0f, listOf(null), verifyNativeTaps = true,
                verifyViewport = true, expectedRails = rails)
        }
    }

    /** SIMULATED actual Live/Clean editor: the real Status eye dims its relocated children together. */
    @Test(timeout = 180_000) fun compactStatusEditorKeepsStorageGroupDimmingAndIndependentPower() {
        for (mode in listOf(com.opencapture.opencine.appkit.MonitorDisplayMode.LIVE,
            com.opencapture.opencine.appkit.MonitorDisplayMode.CLEAN)) {
            productionPrimaryCase(320f, 24f, 0f, listOf(null), compactEditorMode = mode)
        }
    }

    private fun productionPrimaryCase(width: Float, top: Float, side: Float, durations: List<Int?>,
        codecOnly: Boolean = false, compareStandbyRecording: Boolean = false, useActualHostHeight: Boolean = false,
        verifyNativeTaps: Boolean = false, verifyViewport: Boolean = false,
        captureRails: MutableMap<String, Rect>? = null, expectedRails: Map<String, Rect>? = null,
        compactEditorMode: com.opencapture.opencine.appkit.MonitorDisplayMode? = null,
        declaredGauge: com.opencapture.opencine.cameracontrols.MonitorOperatorPowerReading? = null,
        verifyInsetMovement: Boolean = false, typedPortraitHeader: Boolean = false, colorOnly: Boolean = false) {
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
            var liveTop by androidx.compose.runtime.mutableStateOf(top)
            var primaryCalls = 0; var codecCalls = 0; var colorCalls = 0
            val placed = CountDownLatch(1)
            var fontReferences = emptyList<TextLayoutResult>()
            var standbyMainFonts = emptyMap<String, Float>()
            var canvas = Rect.Zero; var actualPicture = Rect.Zero
            var canvasHeightDp = 956f
            run {
                awaitForegroundFrame(scenario)
                scenario.onActivity { activity ->
                    val content = activity.findViewById<View>(android.R.id.content)
                    val density = activity.resources.displayMetrics.density
                    assertTrue("Actual available native window must be measured", content.width > 0 && content.height > 0)
                    if (useActualHostHeight)
                        assertTrue("Full production360width must fit the actual physical host", content.width / density >= width)
                    val availableHeightDp = content.height / density
                    canvasHeightDp = if (useActualHostHeight) availableHeightDp else minOf(canvasHeightDp, availableHeightDp)
                    android.util.Log.i("B5ActualPhysicalHostInputs", JSONObject().put("actualContentWidthPixels", content.width)
                        .put("actualContentHeightPixels", content.height).put("density", density)
                        .put("actualFontScale", activity.resources.configuration.fontScale).put("canvasWidthDp", width)
                        .put("actualAvailableHeightDp", availableHeightDp).put("canvasHeightDp", canvasHeightDp).put("rawSafeTopDp", top)
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
                    if (compactEditorMode != null) {
                        model.live = com.opencapture.opencine.appkit.MonitorDisplayChrome.liveDefaults
                        model.clean = com.opencapture.opencine.appkit.MonitorDisplayChrome.liveDefaults
                        model.beginEditing(compactEditorMode)
                    }
                    activity.setContent {
                        val currentLive = LiveMonitorLayout.fieldMonitor(width, canvasHeightDp, side, side, liveTop, 0f,
                            showsBottomBars = false, pictureAspect = 16f / 9f, showsValues = false)
                        val currentField = requireNotNull(currentLive.field)
                        val nativeMeasurer = androidx.compose.ui.text.rememberTextMeasurer()
                        val mainMaximum = if (field.tablet) 25f else 23f
                        fontReferences = listOf("00:48:03:23" to 10f, "00:48:03:23" to mainMaximum,
                            "[FX] 6K · 25p" to 10f, "[FX] 6K · 25p" to (if (field.tablet) 22f else 20f), "R3D NE" to 10f, "R3D NE" to 13f,
                            // Codec and color share the detail line, so both use the detail size range.
                            "D-Log2" to 10f, "D-Log2" to 13f).map { (value, size) ->
                            nativeMeasurer.measure(androidx.compose.ui.text.AnnotatedString(value),
                                style = MonitorTypography.readout(size, androidx.compose.ui.text.font.FontWeight.Medium))
                        }
                        val format = com.opencapture.opencine.appkit.MonitorOperatorLiveReadout<String, com.opencapture.opencine.appkit.MonitorDisplaySection>(
                            "format", "Recording format", "[FX] 6K · 25p", action = { primaryCalls++ }, quickEnabled = false)
                        val codec = com.opencapture.opencine.appkit.MonitorOperatorLiveReadout<String, com.opencapture.opencine.appkit.MonitorDisplaySection>(
                            if (codecOnly) "compression" else "codec", "Codec", "R3D NE",
                            section = if (codecOnly || typedPortraitHeader) com.opencapture.opencine.appkit.MonitorDisplaySection.CODEC else null,
                            action = { codecCalls++ }, quickEnabled = false)
                        val color = com.opencapture.opencine.appkit.MonitorOperatorLiveReadout<String, com.opencapture.opencine.appkit.MonitorDisplaySection>(
                            "color", "Color mode", "D-Log2", action = { colorCalls++ }, quickEnabled = false)
                        val inputs = com.opencapture.opencine.appkit.MonitorOperatorCaptureInputs<String, com.opencapture.opencine.appkit.MonitorDisplaySection, Nothing>(
                            emptyList(), open = {}, dismiss = {})
                        val status = com.opencapture.opencine.cameracontrols.MonitorOperatorLiveStatus(
                            recording = { MonitorStatusPresentation(elapsed != null, elapsed ?: 0, "00:48:03:23") },
                            showsTimecode = true, showsRecording = true,
                            storage = com.opencapture.opencine.appkit.MonitorOperatorLiveReadout("storage", "Storage remaining", "107 GB",
                                section = if (compactEditorMode != null) com.opencapture.opencine.appkit.MonitorDisplaySection.STORAGE else null),
                            format = if (codecOnly) listOf(codec) else if (colorOnly) listOf(format) else listOf(format, codec), fps = "25 fps", signalBars = 4,
                            fpsSection = if (compactEditorMode != null) com.opencapture.opencine.appkit.MonitorDisplaySection.FPS else null,
                            portraitFormat = if (typedPortraitHeader) com.opencapture.opencine.appkit.MonitorOperatorLiveReadout(
                                "format", "Recording format", "6K · 25p", action = { primaryCalls++ }, quickEnabled = false) else null,
                            color = if (codecOnly) null else color)
                        val source = com.opencapture.opencine.cameracontrols.MonitorOperatorLiveSource(
                            identity = { identity }, available = if (codecOnly) setOf(
                                com.opencapture.opencine.appkit.MonitorDisplaySection.STATUS_BAR,
                                com.opencapture.opencine.appkit.MonitorDisplaySection.BATTERIES,
                                com.opencapture.opencine.appkit.MonitorDisplaySection.CODEC) else setOf(
                                com.opencapture.opencine.appkit.MonitorDisplaySection.STATUS_BAR,
                                com.opencapture.opencine.appkit.MonitorDisplaySection.BATTERIES,
                                com.opencapture.opencine.appkit.MonitorDisplaySection.COLOR) +
                                (if (typedPortraitHeader && !colorOnly) setOf(com.opencapture.opencine.appkit.MonitorDisplaySection.CODEC) else emptySet()) +
                                if (compactEditorMode != null) setOf(com.opencapture.opencine.appkit.MonitorDisplaySection.STORAGE,
                                    com.opencapture.opencine.appkit.MonitorDisplaySection.FPS) else emptySet(),
                            picture = com.opencapture.opencine.cameracontrols.MonitorOperatorLivePicture(16f / 9f, false, false, false, false),
                            status = status, cameraBattery = declaredGauge ?: com.opencapture.opencine.cameracontrols.MonitorOperatorPowerReading(true, 68),
                            capture = inputs, record = com.opencapture.opencine.cameracontrols.MonitorOperatorRecordSource(false, false, false, null),
                            exposure = null, level = null, levelViewFlip = false, audio = null, readOnly = false, borrowed = false,
                            returnToStage = null, coverOpen = false, note = null, clearNote = {}, vpnActive = { false }, settings = {}, media = {})
                        Box(Modifier.fillMaxSize().background(androidx.compose.ui.graphics.Color.Black), contentAlignment = Alignment.TopStart) {
                            Box(Modifier.requiredSize(width.dp, canvasHeightDp.dp).onGloballyPositioned { canvas = it.boundsInRoot(); placed.countDown() }) {
                                com.opencapture.opencine.cameracontrols.MonitorOperatorLiveSurface(control, model,
                                    com.opencapture.opencine.cameracontrols.MonitorOperatorLiveLayout(currentLive, null, currentField.picture, currentField.viewport, 16f / 9f),
                                    source, com.opencapture.opencine.cameracontrols.MonitorOperatorLiveAssists(null, emptyList(), emptySet(), null,
                                        com.opencapture.opencine.cameracontrols.MonitorOperatorSignalOptions(), MonitorToolUsageState(), {}, emptyMap()),
                                    com.opencapture.opencine.cameracontrols.MonitorOperatorBodyViews(),
                                    picture = {
                                        Box(Modifier.offset(currentField.picture.x.dp, currentField.picture.y.dp)
                                            .requiredSize(currentField.picture.width.dp, currentField.picture.height.dp)
                                            .background(androidx.compose.ui.graphics.Color.Green)
                                            .semantics { contentDescription = "SIMULATED production picture" }
                                            .onGloballyPositioned { actualPicture = it.boundsInRoot() })
                                        if (compactEditorMode != null) {
                                            MonitorBoundedReadoutText("107 GB", Modifier.offset(20.dp, 250.dp).width(92.dp)
                                                .then(legacyStatusEditReference(model, compactEditorMode))
                                                .semantics { contentDescription = "SIMULATED original Status edit reference" })
                                        }
                                    }, cameraPanel = { _, _, _, _ -> }, photoRelease = null)
                            }
                        }
                    }
                }
                assertTrue("Actual production composition must lay out", placed.await(5, TimeUnit.SECONDS))
                if (verifyInsetMovement) {
                    for ((index, inset) in listOf(0f, 64f, 84f, 0f).withIndex()) {
                        scenario.onActivity { liveTop = inset }
                        awaitForegroundFrame(scenario)
                        var powerBottom = 0f; var density = 1f
                        val composedTargets = mutableMapOf<String, Rect>()
                        scenario.onActivity { activity ->
                            density = activity.resources.displayMetrics.density
                            val origin = IntArray(2)
                            activity.findViewById<ViewGroup>(android.R.id.content).getChildAt(0).getLocationOnScreen(origin)
                            val nodes = nativeNodes(activity.window.decorView)
                            val power = nodes.filter { it.config.getOrNull(SemanticsProperties.ContentDescription)?.singleOrNull()
                                ?.let { label -> label.startsWith("Phone battery ") || label.startsWith("Camera battery ") } == true }
                            assertEquals(2, power.size)
                            powerBottom = power.maxOf { it.boundsInRoot.bottom } + origin[1]
                            for (label in listOf("Recording format", "Codec", "Color mode")) {
                                val target = nodes.single { it.config.getOrNull(SemanticsProperties.ContentDescription)?.singleOrNull() == label }
                                composedTargets[label] = target.boundsInRoot.translate(origin[0].toFloat(), origin[1].toFloat())
                                assertTrue(target.config[SemanticsActions.OnClick].action!!.invoke())
                            }
                            assertEquals(index + 1, primaryCalls); assertEquals(index + 1, codecCalls); assertEquals(index + 1, colorCalls)
                            val shot = requireNotNull(InstrumentationRegistry.getInstrumentation().uiAutomation.takeScreenshot())
                            try { activity.cacheDir.resolve("SIMULATED-declared-inset-$inset-${android.os.SystemClock.uptimeMillis()}.png")
                                .outputStream().use { assertTrue(shot.compress(Bitmap.CompressFormat.PNG, 100, it)) }
                            } finally { shot.recycle() }
                        }
                        InstrumentationRegistry.getInstrumentation().waitForIdleSync()
                        InstrumentationRegistry.getInstrumentation().uiAutomation.waitForIdle(100, 5_000)
                        for (label in listOf("Recording format", "Codec", "Color mode")) {
                            val target = nativeClickableTarget(label, refreshOwner = true)
                            android.util.Log.i("DeclaredGaugeInsets", JSONObject().put("inset", inset).put("label", label)
                                .put("density", density).put("powerBottom", powerBottom).put("target", target.toShortString())
                                .put("composedTarget", composedTargets.getValue(label).toString()).toString())
                            assertTrue("Actual displaced $label target clears native power at inset$inset by8dp",
                                target.top >= powerBottom + 8f * density - 1f)
                        }
                    }
                    return
                }
                if (compactEditorMode != null) {
                    assertCompactEditorDimming(scenario, requireNotNull(session), compactEditorMode,
                        powerIsGreen = declaredGauge == null)
                    return
                }
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
                        if (typedPortraitHeader) {
                            val format = labeled("Recording format")
                            val detail = labeled(if (colorOnly) "Color mode" else "Codec")
                            assertEquals("6K · 25p", format.config[SemanticsProperties.StateDescription])
                            assertEquals(colorOnly, nodes.any {
                                it.config.getOrNull(SemanticsProperties.ContentDescription)?.singleOrNull() == "Color mode"
                            })
                            assertEquals(if (colorOnly) "D-Log2" else "R3D NE", detail.config[SemanticsProperties.StateDescription])
                            assertEquals("Selected profile belongs in the color-only portrait header", colorOnly, nodes.any {
                                val text = it.config.getOrNull(SemanticsProperties.Text)?.singleOrNull()?.text
                                val value = it.config.getOrNull(SemanticsProperties.StateDescription)
                                text == "D-Log2" || value == "D-Log2"
                            })
                            assertTrue("FX/DX stay out of the portrait header", nodes.none {
                                val text = it.config.getOrNull(SemanticsProperties.Text)?.singleOrNull()?.text
                                text?.contains("[FX]") == true || text?.contains("[DX]") == true
                            })
                            assertRenderedBands(activity.window.decorView, width, top, emptyList(), listOf(
                                "status" to recording.boundsInRoot, "clock" to clock.boundsInRoot,
                                "format" to format.boundsInRoot, "detail" to detail.boundsInRoot))
                            val density = activity.resources.displayMetrics.density
                            for (target in listOf(format, detail)) {
                                assertTrue("Portrait target width", target.boundsInRoot.width >= 48f * density - .5f)
                                assertTrue("Portrait target height", target.boundsInRoot.height >= 48f * density - .5f)
                            }
                            assertTrue("Primary/detail targets stay separate", format.boundsInRoot.bottom <= detail.boundsInRoot.top + .5f)
                            assertTrue("Clock clears both header lines", clock.boundsInRoot.right <= minOf(format.boundsInRoot.left, detail.boundsInRoot.left) + .5f)
                            for ((value, maximum) in listOf("6K · 25p" to 20f, (if (colorOnly) "D-Log2" else "R3D NE") to 13f)) {
                                val node = nodes.single { it.config.getOrNull(SemanticsProperties.Text)?.singleOrNull()?.text == value }
                                val results = mutableListOf<TextLayoutResult>()
                                assertTrue(node.config[SemanticsActions.GetTextLayoutResult].action!!.invoke(results))
                                val actual = results.single()
                                assertEquals(1, actual.lineCount)
                                assertTrue("Native text remains bounded", !actual.didOverflowWidth && !actual.didOverflowHeight)
                                assertTrue("Native portrait font ceiling", actual.layoutInput.style.fontSize.value <= maximum)
                            }
                            assertTrue(detail.config[SemanticsActions.OnClick].action!!.invoke())
                            assertEquals(1, if (colorOnly) colorCalls else codecCalls)
                            assertEquals(0, if (colorOnly) codecCalls else colorCalls)
                            return@onActivity
                        }
                        if (captureRails != null || expectedRails != null) {
                            fun powerFrame(prefix: String) = nodes.single {
                                it.config.getOrNull(SemanticsProperties.ContentDescription)?.singleOrNull()
                                    ?.startsWith("$prefix battery ") == true
                            }.boundsInRoot
                            val rails = mapOf("picture" to actualPicture,
                                "storage" to labeled("Storage remaining").boundsInRoot,
                                "phone" to powerFrame("Phone"), "camera" to powerFrame("Camera"))
                            captureRails?.putAll(rails)
                            expectedRails?.forEach { (name, original) ->
                                val actual = rails.getValue(name)
                                for ((value, expected) in listOf(actual.left, actual.top, actual.width, actual.height)
                                    .zip(listOf(original.left, original.top, original.width, original.height))) {
                                    assertEquals("Status clearance preserves independent $name", expected, value, .5f)
                                }
                            }
                            android.util.Log.i("B5LowSafeTopRails", JSONObject().put("rawSafeTop", top)
                                .put("codecOnly", codecOnly).put("rails", rails.toString()).toString())
                        }
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
                        val color = requireNotNull(availableColor) { "Production Color mode must remain present with its profile" }
                        assertEquals(recording.boundsInRoot.top, clock.boundsInRoot.top, .5f)
                        val primaryText = nodes.single {
                            it.config.getOrNull(SemanticsProperties.Text)?.singleOrNull()?.text == "[FX] 6K · 25p"
                        }
                        assertEquals("Actual primary text keeps the clock's native top anchor",
                            clock.boundsInRoot.top, primaryText.boundsInRoot.top, .5f)
                        val originalStatusTop = canvas.top + field.status.y * density
                        val minimumClearance = if (verifyViewport) maxOf(0f,
                            format.boundsInRoot.height - primaryText.boundsInRoot.height - field.status.y * density) else 0f
                        val expectedStatusTop = originalStatusTop + minimumClearance
                        assertEquals(expectedStatusTop, clock.boundsInRoot.top, .5f)
                        if (verifyViewport) {
                            assertTrue("The full tablet canvas must fit its actual host", canvas.left >= -.5f &&
                                canvas.right <= activity.window.decorView.width + .5f)
                            for (target in listOf(format, codec, color)) {
                                assertTrue("The full original target stays in the viewport", target.boundsInRoot.top >= canvas.top - .5f &&
                                    target.boundsInRoot.bottom <= canvas.bottom + .5f)
                            }
                            assertEquals("Only the measured obstruction moves the row",
                                maxOf(canvas.top, originalStatusTop - format.boundsInRoot.height + primaryText.boundsInRoot.height),
                                format.boundsInRoot.top, .5f)
                            android.util.Log.i("B5LowSafeTopClearance", JSONObject().put("rawSafeTop", top)
                                .put("originalStatusTop", originalStatusTop).put("minimumClearancePixels", minimumClearance)
                                .put("format", format.boundsInRoot.toString()).put("clock", clock.boundsInRoot.toString()).toString())
                        }
                        for (target in listOf(format, color, codec)) {
                            assertTrue("Original native target width retained", target.boundsInRoot.width >= 44f * density)
                            assertTrue("Original native target height retained", target.boundsInRoot.height >= 48f * density)
                        }
                        // Stacked targets tile: the primary ends where the detail line begins, so no
                        // tap lands on two readouts; the detail line keeps the full target height.
                        for (target in listOf(color, codec)) {
                            assertTrue("Original native target height retained", target.boundsInRoot.height >= 48f * density)
                            assertTrue("No overlapping targets", format.boundsInRoot.bottom <= target.boundsInRoot.top + .5f)
                        }
                        // STBY/REC, the clock and the primary share the status row's top edge; codec
                        // then color stack on the detail line under the primary, end aligned with it.
                        val row = listOf(recording, clock, format)
                        listOf(recording, clock).forEach { target ->
                            assertEquals(expectedStatusTop, target.boundsInRoot.top, .5f)
                        }
                        (row + listOf(codec, color)).forEach { target ->
                            assertTrue("All native row frames remain inside side-safe width",
                                target.boundsInRoot.left >= canvas.left + field.status.x * density - .5f &&
                                target.boundsInRoot.right <= canvas.left + (field.status.x + field.status.width) * density + .5f)
                        }
                        assertEquals(codec.boundsInRoot.top, color.boundsInRoot.top, .5f)
                        assertTrue("The detail line sits under the primary glyphs",
                            codec.boundsInRoot.top > primaryText.boundsInRoot.top + 8f * density &&
                                codec.boundsInRoot.top < primaryText.boundsInRoot.top + 48f * density)
                        assertEquals(format.boundsInRoot.right, color.boundsInRoot.right, .5f)
                        (row.zipWithNext() + listOf(clock to codec, codec to color)).forEach { (left, right) ->
                            assertTrue("Each complete readout owns its native target",
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
                    if (verifyNativeTaps) {
                        for ((index, label) in listOf("Recording format", "Recording format", "Codec", "Color mode").withIndex()) {
                            var point = android.graphics.PointF()
                            var before = intArrayOf()
                            scenario.onActivity { activity ->
                                val nodes = nativeNodes(activity.window.decorView)
                                val target = nodes.single {
                                    it.config.getOrNull(SemanticsProperties.ContentDescription)?.singleOrNull() == label
                                }.boundsInRoot
                                val density = activity.resources.displayMetrics.density
                                val origin = IntArray(2)
                                activity.window.decorView.getLocationOnScreen(origin)
                                val y = if (index == 1) target.bottom - density else target.top + density
                                point = android.graphics.PointF(origin[0] + target.center.x, origin[1] + y)
                                before = intArrayOf(primaryCalls, codecCalls, colorCalls)
                            }
                            val instrumentation = InstrumentationRegistry.getInstrumentation()
                            val down = android.os.SystemClock.uptimeMillis()
                            for ((action, time) in listOf(android.view.MotionEvent.ACTION_DOWN to down,
                                android.view.MotionEvent.ACTION_UP to down + 50)) {
                                val event = android.view.MotionEvent.obtain(down, time, action, point.x, point.y, 0)
                                try { instrumentation.sendPointerSync(event) } finally { event.recycle() }
                            }
                            instrumentation.waitForIdleSync()
                            scenario.onActivity {
                                assertEquals("Real tap $index at $point reaches only $label", before[0] + if (index < 2) 1 else 0, primaryCalls)
                                assertEquals("Real tap $index keeps codec independent", before[1] + if (index == 2) 1 else 0, codecCalls)
                                assertEquals("Real tap $index keeps color independent", before[2] + if (index == 3) 1 else 0, colorCalls)
                            }
                        }
                    }
                }
            } finally {
                scenario.onActivity { session?.close(); control.unbind(); storage.edit().clear().commit() }
                scope.cancel()
            }
        }
    }

    /** SIMULATED real signal/FPS action, same storage paragraph, actual native occupied targets. */
    @Test(timeout = 180_000) fun compactTabletTogglePreservesStorageAndNativeFPSGlyphs() {
        compactTogglePreservesStorageAndNativeFPSGlyphs(MonitorTelemetryMetrics.TABLET, 134f, 11f)
    }

    @Test(timeout = 180_000) fun compactPhoneTogglePreservesStorageAndNativeFPSGlyphs() {
        compactTogglePreservesStorageAndNativeFPSGlyphs(MonitorTelemetryMetrics.PHONE, 122f, 10f)
    }

    /** SIMULATED: exact dense values retain native glyphs and occupied action clearance. */
    @Test(timeout = 180_000) fun compactDeclaredGaugesKeepFullFontAndOccupiedClearance() {
        for (count in listOf(100, Int.MAX_VALUE)) {
            compactTogglePreservesStorageAndNativeFPSGlyphs(MonitorTelemetryMetrics.TABLET, 0f, 11f,
                MonitorTelemetryPower(true, null, bars = count, barCount = count))
        }
    }

    /** SIMULATED production editor keeps one Status owner after its header is displaced. */
    @Test(timeout = 180_000) fun compactDeclaredGaugeRetainsProductionEditorOwnership() {
        for (mode in listOf(com.opencapture.opencine.appkit.MonitorDisplayMode.LIVE,
            com.opencapture.opencine.appkit.MonitorDisplayMode.CLEAN)) {
            productionPrimaryCase(320f, 24f, 0f, listOf(null), compactEditorMode = mode,
                declaredGauge = com.opencapture.opencine.cameracontrols.MonitorOperatorPowerReading(true, null,
                    bars = Int.MAX_VALUE, barCount = Int.MAX_VALUE))
        }
    }

    /** SIMULATED actual composition updates the occupied boundary when only its inset changes. */
    @Test(timeout = 180_000) fun compactDeclaredGaugeRetainsClearanceWhenSafeTopChanges() {
        productionPrimaryCase(320f, 0f, 0f, listOf(null), verifyInsetMovement = true,
            declaredGauge = com.opencapture.opencine.cameracontrols.MonitorOperatorPowerReading(true, null,
                bars = Int.MAX_VALUE, barCount = Int.MAX_VALUE))
    }

    private fun compactTogglePreservesStorageAndNativeFPSGlyphs(metrics: MonitorTelemetryMetrics,
        expectedPowerWidth: Float, literalFpsFont: Float, declaredGauge: MonitorTelemetryPower? = null) {
        for (width in if (declaredGauge == null) listOf(320f, 360f, 440f) else listOf(320f, 440f))
            for (value in if (declaredGauge == null) listOf("\u2014", "107 GB", "123456789 GB") else listOf("123456789 GB")) {
            ActivityScenario.launch(MonitorTestActivity::class.java).use { scenario ->
                var candidate by androidx.compose.runtime.mutableStateOf(false)
                var storageFrame = Rect.Zero
                var powerFrame = Rect.Zero
                var canvas = Rect.Zero
                var density = 1f
                val field = MonitorLayoutPolicy.fieldMonitor(width, 956f)
                scenario.onActivity { activity ->
                    density = activity.resources.displayMetrics.density
                    activity.setContent {
                        val storage: @androidx.compose.runtime.Composable () -> Unit = {
                            Row(Modifier.clickable { }.semantics { contentDescription = "Storage remaining" }
                                .onGloballyPositioned { storageFrame = it.boundsInRoot() },
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(5.dp)) {
                                MonitorIcon(MonitorIcon.CARD_SIM, null, Modifier.size(14.dp))
                                MonitorBoundedReadoutText(value)
                            }
                        }
                        val link: @androidx.compose.runtime.Composable () -> Unit = {
                            MonitorTelemetry(4, "25", emptyList(), true, metrics = metrics,
                                showsPower = false)
                        }
                        val power: @androidx.compose.runtime.Composable () -> Unit = {
                            MonitorTelemetry(null, null, listOf(MonitorTelemetryPower(false, 100), declaredGauge ?: MonitorTelemetryPower(true, 68)),
                                true, metrics = metrics, showsLink = false,
                                modifier = Modifier.onGloballyPositioned { powerFrame = it.boundsInRoot() })
                        }
                        Box(Modifier.fillMaxSize().background(androidx.compose.ui.graphics.Color.Black)) {
                            Box(Modifier.requiredSize(width.dp, 956.dp).onGloballyPositioned { canvas = it.boundsInRoot() }) {
                                if (candidate) MonitorCompactTelemetryRow(field, 0f, 0f, metrics,
                                    storage = storage, link = link, power = power)
                                else {
                                    MonitorStatusChrome(field, MonitorStatusPresentation(false),
                                        modifier = Modifier.offset(field.status.x.dp, field.status.y.dp).width(field.status.width.dp),
                                        storage = storage, format = {}, link = link)
                                    Box(Modifier.offset(field.telemetry.x.dp, field.telemetry.y.dp)) { power() }
                                }
                                Text("25 fps", style = MonitorTypography.readout(literalFpsFont, FontWeight.Bold),
                                    color = MonitorPalette.accent, modifier = Modifier.offset(20.dp, (if (declaredGauge == null) 100 else 200).dp))
                                if (declaredGauge != null) Text("${declaredGauge.bars}/${declaredGauge.barCount}",
                                    style = MonitorTypography.readout(10f, FontWeight.Bold), color = MonitorPalette.text,
                                    modifier = Modifier.offset(20.dp, 240.dp))
                                if (declaredGauge != null) {
                                    Text("${declaredGauge.bars}/${declaredGauge.barCount}",
                                        style = MonitorTypography.readout(9f, FontWeight.Bold), color = MonitorPalette.text,
                                        modifier = Modifier.offset(20.dp, 280.dp).testTag("wide-gauge-smaller"))
                                    Text("${declaredGauge.bars}/${declaredGauge.barCount}".dropLast(1),
                                        style = MonitorTypography.readout(10f, FontWeight.Bold), color = MonitorPalette.text,
                                        modifier = Modifier.offset(20.dp, 320.dp).testTag("wide-gauge-shorter"))
                                }
                            }
                        }
                    }
                }
                awaitForegroundFrame(scenario)
                var originalPaint: NativeStoragePaint? = null
                var originalStorageWidth = 0f
                scenario.onActivity { activity ->
                    val node = nativeNodes(activity.window.decorView).single {
                        it.config.getOrNull(SemanticsProperties.Text)?.singleOrNull()?.text == value
                    }
                    val results = mutableListOf<TextLayoutResult>()
                    assertTrue(node.config[SemanticsActions.GetTextLayoutResult].action!!.invoke(results))
                    originalPaint = nativeStoragePaint(results.single())
                    originalStorageWidth = storageFrame.width
                }
                val originalOccupiedWidth = nativeClickableTarget("Storage remaining", refreshOwner = true).width().toFloat()
                scenario.onActivity { candidate = true }
                for ((index, fps) in listOf(false, true, false).withIndex()) {
                    awaitForegroundFrame(scenario)
                    val instrumentation = InstrumentationRegistry.getInstrumentation()
                    // A toggle may move both owners. Refresh each platform node so the gap
                    // compares current occupied bounds rather than a mix of cached frames.
                    val storageTarget = nativeClickableTarget("Storage remaining", refreshOwner = true)
                    val performanceTarget = nativeClickableTarget("Live link ", refreshOwner = true)
                    android.util.Log.i("CompactTelemetryTargets", JSONObject().put("width", width).put("storage", value)
                        .put("fps", fps).put("density", density).put("originalOccupiedWidth", originalOccupiedWidth)
                        .put("storageTarget", storageTarget.toShortString()).put("performanceTarget", performanceTarget.toShortString()).toString())
                    scenario.onActivity { activity ->
                        val shot = requireNotNull(instrumentation.uiAutomation.takeScreenshot())
                        try {
                            val file = activity.cacheDir.resolve("SIMULATED-compact-$literalFpsFont-$width-$value-$index-${android.os.SystemClock.uptimeMillis()}.png")
                            file.outputStream().use { assertTrue(shot.compress(Bitmap.CompressFormat.PNG, 100, it)) }
                        } finally { shot.recycle() }
                    }
                    for (target in listOf(storageTarget, performanceTarget)) {
                        assertTrue("Actual native target width retains48dp", target.width() >= 48f * density - 1f)
                        assertTrue("Actual native target height retains48dp", target.height() >= 48f * density - 1f)
                    }
                    // Preserve valid original allocation; a clipped legacy target cannot lower the native floor.
                    assertEquals("Keep complete original occupied storage allocation",
                        maxOf(originalOccupiedWidth, 48f * density), storageTarget.width().toFloat(), .5f)
                    assertTrue("Actual occupied targets retain8dp", storageTarget.right + 8f * density <= performanceTarget.left + 1f)
                    var button: SemanticsNode? = null
                    scenario.onActivity { activity ->
                        val nodes = nativeNodes(activity.window.decorView)
                        button = nodes.single {
                            it.config.getOrNull(SemanticsProperties.ContentDescription)?.singleOrNull()?.startsWith("Live link ") == true
                                && it.config.getOrNull(SemanticsActions.OnClick) != null
                        }
                        val storageNode = nodes.single { it.config.getOrNull(SemanticsProperties.Text)?.singleOrNull()?.text == value }
                        val layouts = mutableListOf<TextLayoutResult>()
                        assertTrue(storageNode.config[SemanticsActions.GetTextLayoutResult].action!!.invoke(layouts))
                        val actual = layouts.single()
                        val paint = nativeStoragePaint(actual)
                        assertTrue("Keep actual visible prefix and native glyph metrics",
                            sameStoragePaint(requireNotNull(originalPaint), paint))
                        assertEquals("Keep original native storage allocation", originalStorageWidth, storageFrame.width, .05f)
                        val linkFrame = button!!.boundsInRoot
                        assertTrue("Full native horizontal target floor", linkFrame.width >= 48f * density - 1f)
                        if (declaredGauge == null) {
                            assertTrue("Actual link target clears real power", linkFrame.right + 8f * density <= powerFrame.left + 1f)
                            assertEquals("Power uses the actual declared metrics", expectedPowerWidth * density, powerFrame.width, .5f)
                        } else {
                            assertTrue("Power clears the complete occupied action targets by8dp",
                                linkFrame.right + 8f * density <= powerFrame.left + 1f ||
                                    maxOf(storageTarget.bottom.toFloat(), performanceTarget.bottom.toFloat()) + 8f * density <= powerFrame.top + 1f)
                            val expected = "${declaredGauge.bars}/${declaredGauge.barCount}"
                            val counts = nodes.filter { it.config.getOrNull(SemanticsProperties.Text)?.singleOrNull()?.text == expected &&
                                it.config.getOrNull(SemanticsProperties.TestTag) != "wide-gauge-smaller" }
                            assertEquals("Both exact full native count strings exist", 2, counts.size)
                            val layouts = counts.sortedBy { it.boundsInRoot.top }.map { node ->
                                val result = mutableListOf<TextLayoutResult>()
                                assertTrue(node.config[SemanticsActions.GetTextLayoutResult].action!!.invoke(result)); result.single()
                            }
                            assertFalse("Full count must not ellipsize", layouts[0].isLineEllipsized(0))
                            for (glyph in expected.indices) {
                                assertEquals(layouts[1].getBoundingBox(glyph).width, layouts[0].getBoundingBox(glyph).width, .05f)
                                assertEquals(layouts[1].getBoundingBox(glyph).height, layouts[0].getBoundingBox(glyph).height, .05f)
                            }
                            val smaller = nodes.single { it.config.getOrNull(SemanticsProperties.TestTag) == "wide-gauge-smaller" }
                            val shorter = nodes.single { it.config.getOrNull(SemanticsProperties.TestTag) == "wide-gauge-shorter" }
                            assertDeclaredGaugeRaster(activity.window.decorView, counts.sortedBy { it.boundsInRoot.top }, smaller, shorter)
                        }
                        assertTrue("Safe leading target", storageFrame.center.x - maxOf(storageFrame.width, 48f * density) / 2 >= canvas.left + 14f * density - 1f)
                        assertTrue("Safe trailing power", powerFrame.right <= canvas.left + (width - 14f) * density + 1f)
                        if (fps) {
                            val text = nodes.filter { it.config.getOrNull(SemanticsProperties.Text)?.singleOrNull()?.text == "25 fps" }
                            assertEquals("The real toggle must expose full FPS and its literal reference", 2, text.size)
                            val measured = text.sortedBy { it.boundsInRoot.top }.map { node ->
                                val result = mutableListOf<TextLayoutResult>()
                                assertTrue(node.config[SemanticsActions.GetTextLayoutResult].action!!.invoke(result))
                                result.single()
                            }
                            assertTrue("FPS must not ellipsize", !measured[0].isLineEllipsized(0))
                            for (glyph in "25 fps".indices) {
                                assertEquals(measured[1].getBoundingBox(glyph).width, measured[0].getBoundingBox(glyph).width, .05f)
                                assertEquals(measured[1].getBoundingBox(glyph).height, measured[0].getBoundingBox(glyph).height, .05f)
                            }
                        }
                        android.util.Log.i("CompactTelemetryNative", JSONObject().put("width", width).put("storage", value)
                            .put("fps", fps).put("storageFrame", storageFrame.toString()).put("linkFrame", linkFrame.toString())
                            .put("powerFrame", powerFrame.toString()).put("literalFpsFont", literalFpsFont)
                            .put("originalOccupiedWidth", originalOccupiedWidth).put("visiblePrefix", paint.visiblePrefix)
                            .put("nativeGlyphs", paint.glyphs.toString()).toString())
                        if (index < 2) assertTrue(button!!.config[SemanticsActions.OnClick].action!!.invoke())
                    }
                    instrumentation.waitForIdleSync()
                }
            }
        }
    }

    private fun assertDeclaredGaugeRaster(decor: View, counts: List<SemanticsNode>, smaller: SemanticsNode, shorter: SemanticsNode) {
        fun root(view: View): View? = if (view is RootForTest) view else if (view is ViewGroup)
            (0 until view.childCount).firstNotNullOfOrNull { root(view.getChildAt(it)) } else null
        val origin = IntArray(2).also(requireNotNull(root(decor))::getLocationOnScreen)
        val shot = requireNotNull(InstrumentationRegistry.getInstrumentation().uiAutomation.takeScreenshot())
        try {
            fun ink(node: SemanticsNode): android.graphics.Rect {
                val frame = node.boundsInRoot.translate(origin[0].toFloat(), origin[1].toFloat())
                var left = shot.width; var top = shot.height; var right = -1; var bottom = -1
                for (y in kotlin.math.floor(frame.top).toInt().coerceAtLeast(0) until kotlin.math.ceil(frame.bottom).toInt().coerceAtMost(shot.height))
                    for (x in kotlin.math.floor(frame.left).toInt().coerceAtLeast(0) until kotlin.math.ceil(frame.right).toInt().coerceAtMost(shot.width)) {
                        val color = shot.getPixel(x, y)
                        if (minOf(Color.red(color), Color.green(color), Color.blue(color)) >= 180) {
                            left = minOf(left, x); top = minOf(top, y); right = maxOf(right, x); bottom = maxOf(bottom, y)
                        }
                    }
                assertTrue("Native count pixels must exist", right >= left && bottom >= top)
                return android.graphics.Rect(left, top, right + 1, bottom + 1)
            }
            val actual = ink(counts[0]); val literal = ink(counts[1]); val small = ink(smaller); val short = ink(shorter)
            assertEquals("Every full10sp count glyph survives native raster", literal.width().toFloat(), actual.width().toFloat(), 1f)
            assertEquals("Native count font height", literal.height().toFloat(), actual.height().toFloat(), 1f)
            assertTrue("Native font oracle rejects the actual9sp control", small.width() < literal.width() - 1)
            assertTrue("Native full-value oracle rejects the actually shortened count", short.width() < literal.width() - 1)
            android.util.Log.i("DeclaredGaugeRaster", JSONObject().put("actual", actual.toShortString())
                .put("literal", literal.toShortString()).put("smallerNegative", small.toShortString()).put("shorterNegative", short.toShortString()).toString())
        } finally { shot.recycle() }
    }

    @androidx.compose.runtime.Composable
    private fun legacyStatusEditReference(model: com.opencapture.opencine.appkit.MonitorOperatorSessionModel,
        mode: com.opencapture.opencine.appkit.MonitorDisplayMode): Modifier {
        val host = androidx.compose.runtime.remember(model) {
            object : com.opencapture.opencine.appkit.ChromeEditHost<com.opencapture.opencine.appkit.MonitorDisplaySection,
                com.opencapture.opencine.appkit.MonitorDisplayMode> {
                override val chromeEditSections = com.opencapture.opencine.appkit.MonitorDisplaySection.entries
                override fun chromeSectionTitle(section: com.opencapture.opencine.appkit.MonitorDisplaySection) = section.title
                override fun chromeSectionID(section: com.opencapture.opencine.appkit.MonitorDisplaySection) = section.key
                override fun chromeModeTitle(mode: com.opencapture.opencine.appkit.MonitorDisplayMode) = mode.title
                override fun isChromeConfigurable(section: com.opencapture.opencine.appkit.MonitorDisplaySection,
                    mode: com.opencapture.opencine.appkit.MonitorDisplayMode) =
                    com.opencapture.opencine.appkit.MonitorDisplayChrome.isConfigurable(section, mode)
                override fun isChromeVisible(section: com.opencapture.opencine.appkit.MonitorDisplaySection,
                    mode: com.opencapture.opencine.appkit.MonitorDisplayMode) = model.chrome(mode).isVisible(section)
                override fun toggleChrome(section: com.opencapture.opencine.appkit.MonitorDisplaySection,
                    mode: com.opencapture.opencine.appkit.MonitorDisplayMode) = model.toggle(section, mode)
                override fun endChromeEditing() = model.finishEditing()
            }
        }
        return Modifier.chromeEditable(host, com.opencapture.opencine.appkit.MonitorDisplaySection.STATUS_BAR, mode) { _, _ -> }
    }

    private fun assertCompactEditorDimming(scenario: ActivityScenario<MonitorTestActivity>,
        model: com.opencapture.opencine.appkit.MonitorOperatorSessionModel,
        mode: com.opencapture.opencine.appkit.MonitorDisplayMode, powerIsGreen: Boolean = true) {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        var original: Bitmap? = null
        var originalFrames = emptyMap<String, Rect>()
        try {
            for ((index, hidden) in listOf(false, true, false).withIndex()) {
                awaitForegroundFrame(scenario)
                instrumentation.waitForIdleSync()
                scenario.onActivity { activity ->
                    assertEquals(!hidden, model.chrome(mode).statusBar)
                    assertTrue("Storage remains individually enabled while Status Bar is hidden", model.chrome(mode).storage)
                    assertEquals(mode, model.editingMode)
                    val nodes = nativeNodes(activity.window.decorView)
                    val badge = nodes.single {
                        it.config.getOrNull(SemanticsProperties.TestTag) == "monitor.chromeEdit.statusBar"
                    }
                    assertEquals(if (hidden) "Hidden" else "Shown", badge.config[SemanticsProperties.StateDescription])
                    fun description(node: SemanticsNode) = node.config.getOrNull(SemanticsProperties.ContentDescription)?.singleOrNull()
                    val reference = nodes.single { description(it) == "SIMULATED original Status edit reference" }
                    val storage = nodes.single {
                        it.config.getOrNull(SemanticsProperties.Text)?.singleOrNull()?.text == "107 GB" &&
                            description(it) != "SIMULATED original Status edit reference"
                    }
                    val link = nodes.single { description(it)?.startsWith("Live link ") == true }
                    val power = nodes.single { description(it)?.startsWith("Camera battery ") == true }
                    val location = IntArray(2)
                    activity.findViewById<ViewGroup>(android.R.id.content).getChildAt(0).getLocationOnScreen(location)
                    fun pixels(node: SemanticsNode) = node.boundsInRoot.translate(location[0].toFloat(), location[1].toFloat())
                    val frames = mapOf("reference" to pixels(reference), "storage" to pixels(storage),
                        "link" to pixels(link), "power" to pixels(power))
                    val raw = requireNotNull(instrumentation.uiAutomation.takeScreenshot())
                    val shot = requireNotNull(raw.copy(Bitmap.Config.ARGB_8888, false))
                    raw.recycle()
                    try {
                        val file = activity.cacheDir.resolve("SIMULATED-status-editor-$mode-$index-${android.os.SystemClock.uptimeMillis()}.png")
                        file.outputStream().use { assertTrue(shot.compress(Bitmap.CompressFormat.PNG, 100, it)) }
                        if (original == null) {
                            original = requireNotNull(shot.copy(Bitmap.Config.ARGB_8888, false))
                            originalFrames = frames
                        } else {
                            for ((name, frame) in frames) {
                                val before = originalFrames.getValue(name)
                                for ((actual, expected) in listOf(frame.left, frame.top, frame.width, frame.height)
                                    .zip(listOf(before.left, before.top, before.width, before.height))) {
                                    assertEquals("Edit visibility preserves $name geometry", expected, actual, .5f)
                                }
                            }
                            val before = requireNotNull(original)
                            val referenceRatio = nativeBrightnessRatio(before, shot, frames.getValue("reference"), false)
                            val storageRatio = nativeBrightnessRatio(before, shot, frames.getValue("storage"), false)
                            val linkRatio = nativeBrightnessRatio(before, shot, frames.getValue("link"), false)
                            val powerRatio = nativeBrightnessRatio(before, shot, frames.getValue("power"), powerIsGreen)
                            assertEquals("Storage keeps original Status group dimming", referenceRatio, storageRatio, .05f)
                            assertEquals("Link keeps original Status group dimming", referenceRatio, linkRatio, .05f)
                            assertEquals("Power keeps its separate visible owner", 1f, powerRatio, .05f)
                            if (hidden) assertTrue("The original path actually dims", referenceRatio < .8f)
                            else assertEquals("The real eye restores its children", 1f, referenceRatio, .05f)
                            android.util.Log.i("CompactStatusEditor", JSONObject().put("mode", mode.toString())
                                .put("hidden", hidden).put("frames", frames.toString()).put("referenceRatio", referenceRatio)
                                .put("storageRatio", storageRatio).put("linkRatio", linkRatio).put("powerRatio", powerRatio).toString())
                        }
                    } finally { shot.recycle() }
                    if (index < 2) assertTrue("Use the actual Status Bar eye callback", badge.config[SemanticsActions.OnClick].action!!.invoke())
                }
            }
        } finally { original?.recycle() }
    }

    private fun nativeBrightnessRatio(original: Bitmap, actual: Bitmap, frame: Rect, green: Boolean): Float {
        val ratios = mutableListOf<Float>()
        for (y in kotlin.math.floor(frame.top).toInt().coerceAtLeast(0) until kotlin.math.ceil(frame.bottom).toInt().coerceAtMost(original.height)) {
            for (x in kotlin.math.floor(frame.left).toInt().coerceAtLeast(0) until kotlin.math.ceil(frame.right).toInt().coerceAtMost(original.width)) {
                val old = original.getPixel(x, y)
                val accepted = if (green) Color.green(old) >= 160 && Color.red(old) < 140 && Color.blue(old) < 140
                    else minOf(Color.red(old), Color.green(old), Color.blue(old)) >= 200
                if (accepted) {
                    val now = actual.getPixel(x, y)
                    val oldValue = if (green) Color.green(old) else minOf(Color.red(old), Color.green(old), Color.blue(old))
                    val newValue = if (green) Color.green(now) else minOf(Color.red(now), Color.green(now), Color.blue(now))
                    ratios += newValue.toFloat() / oldValue
                }
            }
        }
        assertTrue("Actual native glyph/icon pixels are required", ratios.size >= 8)
        return ratios.sorted()[ratios.size / 2]
    }

    private data class NativeStoragePaint(val value: String, val visiblePrefix: String,
        val ellipsized: Boolean, val glyphs: List<Pair<Float, Float>>)

    private fun nativeStoragePaint(result: TextLayoutResult): NativeStoragePaint {
        assertEquals("One native storage line", 1, result.lineCount)
        val value = result.layoutInput.text.text
        val end = result.getLineEnd(0, visibleEnd = true)
        return NativeStoragePaint(value, value.substring(0, end), result.isLineEllipsized(0),
            (0 until end).map { index -> result.getBoundingBox(index).let { it.width to it.height } })
    }

    private fun sameStoragePaint(original: NativeStoragePaint, actual: NativeStoragePaint): Boolean =
        original.value == actual.value && original.visiblePrefix == actual.visiblePrefix &&
            original.ellipsized == actual.ellipsized && original.glyphs.size == actual.glyphs.size &&
            original.glyphs.zip(actual.glyphs).all { (left, right) ->
                kotlin.math.abs(left.first - right.first) <= .05f && kotlin.math.abs(left.second - right.second) <= .05f
            }

    @Test(timeout = 90_000) fun compactStorageOracleRejectsShorterPrefixAndSmallerNativeGlyphs() {
        val value = "123456789 GB"
        ActivityScenario.launch(MonitorTestActivity::class.java).use { scenario ->
            scenario.onActivity { activity ->
                activity.setContent {
                    Column(Modifier.fillMaxSize().background(androidx.compose.ui.graphics.Color.Black)) {
                        MonitorBoundedReadoutText(value, Modifier.width(69.dp))
                        MonitorBoundedReadoutText(value, Modifier.width(69.dp))
                        MonitorBoundedReadoutText(value, Modifier.width(40.dp))
                        MonitorBoundedReadoutText(value, Modifier.width(69.dp), minimumSize = 10f)
                    }
                }
            }
            awaitForegroundFrame(scenario)
            scenario.onActivity { activity ->
                val nodes = nativeNodes(activity.window.decorView).filter {
                    it.config.getOrNull(SemanticsProperties.Text)?.singleOrNull()?.text == value
                }.sortedBy { it.boundsInRoot.top }
                assertEquals(4, nodes.size)
                val samples = nodes.map { node ->
                    val results = mutableListOf<TextLayoutResult>()
                    assertTrue(node.config[SemanticsActions.GetTextLayoutResult].action!!.invoke(results))
                    nativeStoragePaint(results.single())
                }
                assertTrue("Identical native controls must match", sameStoragePaint(samples[0], samples[1]))
                assertTrue("The narrower control actually paints fewer original characters",
                    samples[2].visiblePrefix.length < samples[0].visiblePrefix.length)
                assertFalse("Reject an additionally truncated prefix with unchanged full semantics",
                    sameStoragePaint(samples[0], samples[2]))
                assertTrue("The lower-floor control actually uses smaller native glyphs",
                    samples[3].glyphs.first().first < samples[0].glyphs.first().first - .05f)
                assertFalse("Reject a native font reduction despite unchanged requested maximum/full semantics",
                    sameStoragePaint(samples[0], samples[3]))
                android.util.Log.i("CompactStorageOracle", samples.toString())
            }
        }
    }

    private fun nativeClickableTarget(prefix: String, refreshOwner: Boolean = false): android.graphics.Rect {
        fun find(root: android.view.accessibility.AccessibilityNodeInfo): android.graphics.Rect? {
            fun search(node: android.view.accessibility.AccessibilityNodeInfo,
                parentOwner: android.view.accessibility.AccessibilityNodeInfo?): android.graphics.Rect? {
                val owner = if (node.isClickable) node else parentOwner
                if (node.contentDescription?.toString()?.startsWith(prefix) == true && owner != null) {
                    // Compose may put the label on a child of the native click owner.
                    // Return that real nearest owner's platform bounds without changing them.
                    if (refreshOwner && !owner.refresh()) return null
                    return android.graphics.Rect().also(owner::getBoundsInScreen)
                }
                for (child in 0 until node.childCount) {
                    val found = node.getChild(child)?.let { search(it, owner) }
                    if (found != null) return found
                }
                return null
            }
            return search(root, null)
        }
        val automation = InstrumentationRegistry.getInstrumentation().uiAutomation
        // A displayed frame and Compose semantics do not establish the platform AX tree.
        // Wait only for the actual named clickable to exist; all geometry is judged unchanged below.
        val deadline = android.os.SystemClock.uptimeMillis() + 5_000
        do {
            automation.rootInActiveWindow?.let(::find)?.let { return it }
            val remaining = deadline - android.os.SystemClock.uptimeMillis()
            if (remaining <= 0) break
            try { automation.waitForIdle(50, remaining) }
            catch (_: java.util.concurrent.TimeoutException) { break }
        } while (android.os.SystemClock.uptimeMillis() < deadline)
        val tree = org.json.JSONArray()
        fun describe(node: android.view.accessibility.AccessibilityNodeInfo, depth: Int) {
            val bounds = android.graphics.Rect().also(node::getBoundsInScreen)
            tree.put(JSONObject().put("depth", depth).put("class", node.className?.toString())
                .put("description", node.contentDescription?.toString()).put("text", node.text?.toString())
                .put("clickable", node.isClickable).put("visible", node.isVisibleToUser)
                .put("bounds", bounds.toShortString()).put("window", node.windowId))
            for (child in 0 until node.childCount) node.getChild(child)?.let { describe(it, depth + 1) }
        }
        automation.rootInActiveWindow?.let { describe(it, 0) }
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val stem = "SIMULATED-missing-native-target-${android.os.SystemClock.uptimeMillis()}"
        context.cacheDir.resolve("$stem.json").writeText(JSONObject().put("prefix", prefix)
            .put("deadlineMillis", 5_000).put("nativeTree", tree).toString())
        automation.takeScreenshot()?.let { image ->
            try { context.cacheDir.resolve("$stem.png").outputStream().use { image.compress(Bitmap.CompressFormat.PNG, 100, it) } }
            finally { image.recycle() }
        }
        throw IllegalArgumentException("The actual accessibility target is missing after native AX readiness: $prefix; $tree")
    }

    /**
     * The finished open transition, focus and a submitted hardware frame precede the unchanged
     * foreground screenshot oracle. The display screenshot shows whatever is on screen, so the
     * window must have finished animating in (the host has no splash screen over it).
     */
    private fun awaitForegroundFrame(scenario: ActivityScenario<MonitorTestActivity>) {
        var entered: CountDownLatch? = null
        scenario.onActivity { entered = it.entered }
        assertTrue("The test window's open transition must finish", requireNotNull(entered).await(10, TimeUnit.SECONDS))
        val focused = CountDownLatch(1)
        var focusOwner: ViewTreeObserver? = null
        val marker = ForegroundFrameMarker()
        val origin = IntArray(2)
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
                // This window-only identity sits outside the header and never changes its layout.
                marker.setBounds(decor.width - 40, decor.height / 2,
                    decor.width - 8, decor.height / 2 + 16)
                decor.getLocationOnScreen(origin)
                decor.overlay.add(marker)
                frameOwner = decor.viewTreeObserver
                decor.viewTreeObserver.registerFrameCommitCallback(frameCallback)
                decor.invalidate()
            }
            try {
                assertTrue("Current native frame must commit", committed.await(5, TimeUnit.SECONDS))
                // A frame-commit callback means submitted, not necessarily displayed. Match this
                // window's own pixels instead of waiting on the header values the oracle checks.
                val deadline = android.os.SystemClock.uptimeMillis() + 5_000
                var visible = false
                var last: Bitmap? = null
                try {
                    while (android.os.SystemClock.uptimeMillis() < deadline) {
                        last?.recycle()
                        last = InstrumentationRegistry.getInstrumentation().uiAutomation.takeScreenshot()
                        if (last?.let { marker.matches(it, origin) } == true) {
                            visible = true
                            break
                        }
                        val next = CountDownLatch(1)
                        scenario.onActivity { it.window.decorView.postOnAnimation { next.countDown() } }
                        val remaining = deadline - android.os.SystemClock.uptimeMillis()
                        if (remaining <= 0 || !next.await(remaining, TimeUnit.MILLISECONDS)) break
                    }
                    if (!visible) scenario.onActivity { activity ->
                        val file = activity.cacheDir.resolve("SIMULATED-window-not-visible-${android.os.SystemClock.uptimeMillis()}.png")
                        last?.let { image -> file.outputStream().use { image.compress(Bitmap.CompressFormat.PNG, 100, it) } }
                    }
                    assertTrue("The current native window must be fully visible after its frame commits", visible)
                    scenario.onActivity { it.window.decorView.overlay.remove(marker) }
                    val removalDeadline = android.os.SystemClock.uptimeMillis() + 5_000
                    var removed = false
                    while (android.os.SystemClock.uptimeMillis() < removalDeadline) {
                        last?.recycle()
                        last = InstrumentationRegistry.getInstrumentation().uiAutomation.takeScreenshot()
                        if (last?.let { !marker.matches(it, origin) } == true) {
                            removed = true
                            break
                        }
                        val next = CountDownLatch(1)
                        scenario.onActivity { it.window.decorView.postOnAnimation { next.countDown() } }
                        val remaining = removalDeadline - android.os.SystemClock.uptimeMillis()
                        if (remaining <= 0 || !next.await(remaining, TimeUnit.MILLISECONDS)) break
                    }
                    if (!removed) scenario.onActivity { activity ->
                        val file = activity.cacheDir.resolve("SIMULATED-marker-not-removed-${android.os.SystemClock.uptimeMillis()}.png")
                        last?.let { image -> file.outputStream().use { image.compress(Bitmap.CompressFormat.PNG, 100, it) } }
                    }
                    assertTrue("The visibility marker must leave the display before the header proof", removed)
                } finally { last?.recycle() }
            } finally {
                scenario.onActivity {
                    frameOwner?.takeIf { it.isAlive }?.unregisterFrameCommitCallback(frameCallback)
                }
            }
        } finally {
            scenario.onActivity { activity ->
                activity.window.decorView.overlay.remove(marker)
                focusOwner?.takeIf { it.isAlive }?.removeOnWindowFocusChangeListener(focusListener)
            }
        }
    }

    /** Unique test-window pixels establish visibility independently of the actual header paint. */
    private class ForegroundFrameMarker : android.graphics.drawable.Drawable() {
        private val token = java.util.UUID.randomUUID()
        private val paint = android.graphics.Paint()
        private fun white(index: Int): Boolean {
            val value = if (index < 64) token.mostSignificantBits else token.leastSignificantBits
            return (value ushr (index % 64)) and 1L != 0L
        }
        override fun draw(canvas: android.graphics.Canvas) {
            for (index in 0 until 128) {
                paint.color = if (white(index)) Color.WHITE else Color.BLACK
                val x = bounds.left + index % 16 * 2
                val y = bounds.top + index / 16 * 2
                canvas.drawRect(x.toFloat(), y.toFloat(), x + 2f, y + 2f, paint)
            }
        }
        fun matches(image: Bitmap, origin: IntArray): Boolean = (0 until 128).all { index ->
            val x = origin[0] + bounds.left + index % 16 * 2 + 1
            val y = origin[1] + bounds.top + index / 16 * 2 + 1
            if (x !in 0 until image.width || y !in 0 until image.height) return@all false
            val pixel = image.getPixel(x, y)
            // Require an opaque window, so a dimmed or transitioning surface cannot be ready.
            if (white(index)) minOf(Color.red(pixel), Color.green(pixel), Color.blue(pixel)) >= 250
            else maxOf(Color.red(pixel), Color.green(pixel), Color.blue(pixel)) <= 5
        }
        override fun setAlpha(alpha: Int) { paint.alpha = alpha }
        override fun setColorFilter(filter: android.graphics.ColorFilter?) { paint.colorFilter = filter }
        @Suppress("DEPRECATION")
        override fun getOpacity(): Int = android.graphics.PixelFormat.OPAQUE
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
