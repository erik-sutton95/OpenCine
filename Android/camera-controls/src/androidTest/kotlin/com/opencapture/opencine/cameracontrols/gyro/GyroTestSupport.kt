package com.opencapture.opencine.cameracontrols.gyro

import android.graphics.Rect
import android.os.Bundle
import android.os.SystemClock
import android.view.accessibility.AccessibilityNodeInfo
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.test.core.app.ActivityScenario
import androidx.test.platform.app.InstrumentationRegistry
import com.opencapture.opencine.appkit.MediaShare
import com.opencapture.opencine.cameracontrols.GalleryOpeningTestActivity
import com.opencapture.opencine.gyro.FakeGyroCameraAdapter
import com.opencapture.opencine.gyro.FakeGyroNative
import com.opencapture.opencine.gyro.FakeMotionSensors
import com.opencapture.opencine.gyro.GyroCalibrationBlock
import com.opencapture.opencine.gyro.GyroCalibrationInvalidation
import com.opencapture.opencine.gyro.GyroCaptureCoordinator
import com.opencapture.opencine.gyro.GyroHostConfiguration
import com.opencapture.opencine.gyro.GyroLogEntry
import com.opencapture.opencine.gyro.GyroPreferenceKeys
import com.opencapture.opencine.gyro.GyroRingEvent
import com.opencapture.opencine.gyro.GyroRingPhase
import com.opencapture.opencine.gyro.GyroRingState
import com.opencapture.opencine.gyro.GyroTakeStatus
import java.io.File
import java.util.UUID
import java.util.concurrent.atomic.AtomicBoolean
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertTrue

// Shared by the gyro screen tests: SIMULATED log entries and ring states, the activity host, and
// the accessibility-tree helpers that read the real platform bridge.

/** The extra a Compose node reports its test tag under, when the resource id is absent. */
internal const val TEST_TAG = "androidx.compose.ui.semantics.testTag"

/** A fixed clock so the test takes group under Today regardless of the run date. */
internal const val NOW = 1_760_000_000_000L

/** A coordinator over the gyro test fixtures, hosted by [GyroFeatureHost] in a real activity. */
internal class FeatureHostFixture(
    val coordinator: GyroCaptureCoordinator,
    val adapter: FakeGyroCameraAdapter,
    val sensors: FakeMotionSensors,
    val scenario: ActivityScenario<GalleryOpeningTestActivity>,
) {
    /** Draws [GyroFeatureHost] over an empty monitor in the scenario's current activity. */
    fun showHost() {
        scenario.onActivity { activity ->
            activity.setContent {
                GyroFeatureHost(coordinator, MediaShare("SIMULATED")) {
                    Box(Modifier.fillMaxSize())
                }
            }
        }
    }
}

/**
 * Runs [body] against a [GyroFeatureHost] over a fresh coordinator with private preferences and
 * log root. The coordinator lives outside the activity, so a recreated activity can host it again.
 * A feeder thread delivers a gyro sample every 10 ms on the coordinator's clock so armed capture
 * never stalls while the test drives the screens.
 */
internal fun withFeatureHost(body: (FeatureHostFixture) -> Unit) {
    val context = InstrumentationRegistry.getInstrumentation().targetContext
    val run = UUID.randomUUID().toString()
    val root = File(context.cacheDir, "gyro-host-test-$run")
    val preferences = "gyro-host-test-$run"
    val sensors = FakeMotionSensors()
    val adapter = FakeGyroCameraAdapter()
    val coordinator = GyroCaptureCoordinator(
        context = context,
        host = GyroHostConfiguration(
            appName = "ExampleApp",
            logRoot = root,
            preferencesName = preferences,
            keys = GyroPreferenceKeys.namespaced("gyro.host.test."),
        ),
        native = FakeGyroNative(),
        sensors = sensors,
    )
    val feeding = AtomicBoolean(true)
    val feeder = Thread {
        while (feeding.get()) {
            sensors.emitSample(SystemClock.elapsedRealtimeNanos() / 1e9)
            SystemClock.sleep(10)
        }
    }.apply { start() }
    try {
        ActivityScenario.launch(GalleryOpeningTestActivity::class.java).use { scenario ->
            val fixture = FeatureHostFixture(coordinator, adapter, sensors, scenario)
            fixture.showHost()
            body(fixture)
        }
    } finally {
        feeding.set(false)
        feeder.join(1_000)
        coordinator.close()
        root.deleteRecursively()
        context.deleteSharedPreferences(preferences)
    }
}

internal fun logEntry(
    startMillis: Long,
    status: GyroTakeStatus = GyroTakeStatus.Ready,
    camera: String = "SIMULATED camera",
    duration: Double = 48.0,
    rate: Double = 200.0,
    offset: Double = 0.12,
): GyroLogEntry {
    val id = UUID.randomUUID().toString().uppercase()
    val descriptor = JSONObject()
        .put("id", id)
        .put("cameraLabel", camera)
        .put("startDate", startMillis.toDouble())
        .put("filename", "$id.gcsv")
        .put("isPartial", false)
    if (status != GyroTakeStatus.NotCalibrated) {
        descriptor.put(
            "mountCalibration",
            JSONObject()
                .put("rotation", JSONArray())
                .put("validationErrorDegrees", 1.5)
                .put("separationDegrees", 60),
        )
    }
    val summary = when (status) {
        GyroTakeStatus.CutShort, GyroTakeStatus.Recording -> null
        else -> JSONObject()
            .put("duration", duration)
            .put("measuredRate", rate)
            .put("largestGap", if (status == GyroTakeStatus.SmallGaps) 0.1 else 0.0)
            .put("rejectedSampleCount", 0)
            .put("approximateStartOffset", offset)
            .put("termination", "normal")
            .put("isPartial", false)
            .apply {
                if (status is GyroTakeStatus.MountMoved) {
                    put("mountMovedOffset", status.offsetSeconds)
                }
            }
    }
    return GyroLogEntry(
        descriptor = descriptor,
        summary = summary,
        file = File("SIMULATED-$id.gcsv"),
        active = status == GyroTakeStatus.Recording,
    )
}

internal fun ringState(
    phase: GyroRingPhase,
    step: Int? = 0,
    inZone: Boolean? = null,
    hold: Double? = null,
    block: GyroCalibrationBlock? = null,
    invalidation: GyroCalibrationInvalidation? = null,
    completedSteps: Int = 0,
    event: GyroRingEvent? = null,
    calibrationJSON: String? = null,
) = GyroRingState(
    phase = phase,
    step = step,
    inZone = inZone,
    hold = hold,
    block = block,
    invalidation = invalidation,
    completedSteps = completedSteps,
    event = event,
    calibrationJSON = calibrationJSON,
)

internal fun withScreen(screen: @Composable () -> Unit, assertions: () -> Unit) {
    ActivityScenario.launch(GalleryOpeningTestActivity::class.java).use { scenario ->
        scenario.onActivity { activity -> activity.setContent { screen() } }
        assertions()
    }
}

internal fun tagged(id: String): List<AccessibilityNodeInfo> = nodes().filter { tag(it) == id }

internal fun labels(): List<String> = labelsOf(nodes())

internal fun labelsOf(nodes: List<AccessibilityNodeInfo>): List<String> =
    nodes.mapNotNull { label(it) }

internal fun bounds(node: AccessibilityNodeInfo): Rect = Rect().also { node.getBoundsInScreen(it) }

/**
 * The platform reports an accessibility action both in the legacy action mask and in the action
 * list depending on its API level; either one carries the row's dismiss action.
 */
@Suppress("DEPRECATION")
internal fun AccessibilityNodeInfo.canDismiss(): Boolean =
    (actions and AccessibilityNodeInfo.ACTION_DISMISS) != 0 ||
        actionList.any { it.id == AccessibilityNodeInfo.ACTION_DISMISS }

/**
 * The platform bridge exposes a merged Compose node (a button, a row, a visual) as the tagged
 * wrapper with the merged text and description on its descendants, so a tagged element reads as
 * the first label found in its own subtree.
 */
internal fun deepLabel(node: AccessibilityNodeInfo): String? =
    label(node) ?: (0 until node.childCount).firstNotNullOfOrNull { index ->
        node.getChild(index)?.let(::deepLabel)
    }

/** The node itself or the first descendant that takes a click. */
internal fun AccessibilityNodeInfo.clickTarget(): AccessibilityNodeInfo =
    if (isClickable) {
        this
    } else {
        (0 until childCount).firstNotNullOfOrNull { index ->
            getChild(index)?.takeIf { it.hasClickable() }?.clickTarget()
        } ?: this
    }

internal fun AccessibilityNodeInfo.hasClickable(): Boolean =
    isClickable || (0 until childCount).any { getChild(it)?.hasClickable() == true }

internal fun label(node: AccessibilityNodeInfo): String? {
    val text = node.text?.toString()?.takeIf { it.isNotEmpty() }
    return text ?: node.contentDescription?.toString()?.takeIf { it.isNotEmpty() }
}

internal fun tag(node: AccessibilityNodeInfo): String? {
    node.viewIdResourceName?.substringAfter(":id/")?.takeIf { it.isNotEmpty() }?.let { return it }
    if (TEST_TAG !in node.availableExtraData) return null
    node.refreshWithExtraData(TEST_TAG, Bundle())
    return node.extras.getCharSequence(TEST_TAG)?.toString()
}

internal fun nodes(): List<AccessibilityNodeInfo> {
    val pending = ArrayDeque<AccessibilityNodeInfo>()
    InstrumentationRegistry.getInstrumentation().uiAutomation.rootInActiveWindow?.let(pending::add)
    val result = mutableListOf<AccessibilityNodeInfo>()
    while (pending.isNotEmpty() && result.size < 5_000) {
        val node = pending.removeFirst()
        result += node
        for (index in 0 until node.childCount) node.getChild(index)?.let(pending::add)
    }
    return result
}

internal fun awaitNodes(message: String, predicate: (List<AccessibilityNodeInfo>) -> Boolean) {
    val deadline = SystemClock.uptimeMillis() + 5_000
    while (SystemClock.uptimeMillis() < deadline) {
        InstrumentationRegistry.getInstrumentation().waitForIdleSync()
        if (predicate(nodes())) return
        SystemClock.sleep(20)
    }
    assertTrue(message, predicate(nodes()))
}

internal fun awaitCondition(message: String, predicate: () -> Boolean) {
    val deadline = SystemClock.uptimeMillis() + 5_000
    while (SystemClock.uptimeMillis() < deadline) {
        InstrumentationRegistry.getInstrumentation().waitForIdleSync()
        if (predicate()) return
        SystemClock.sleep(20)
    }
    assertTrue(message, predicate())
}
