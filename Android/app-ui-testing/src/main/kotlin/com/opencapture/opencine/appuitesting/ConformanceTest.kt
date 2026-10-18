package com.opencapture.opencine.appuitesting

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.AccessibilityServiceInfo
import android.app.Activity
import android.app.Instrumentation
import android.app.UiAutomation
import android.content.Intent
import android.content.res.Configuration
import android.content.res.Resources
import android.graphics.Bitmap
import android.graphics.Rect
import android.hardware.display.DisplayManager
import android.os.Build
import android.os.Bundle
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.os.SystemClock
import android.view.Display
import android.view.InputDevice
import android.view.MotionEvent
import android.view.WindowInsets
import android.view.accessibility.AccessibilityNodeInfo
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.platform.io.PlatformTestStorageRegistry
import com.opencapture.monitorui.ReviewLaunch
import com.opencapture.opencine.systemhints.SystemHints
import java.io.File
import java.io.OutputStream
import kotlin.math.abs
import kotlin.math.ceil
import org.junit.After
import org.junit.Before
import org.junit.runner.RunWith

/**
 * Base of the scenarios every app shares (Swift twin: `SharedAppUITestCase`). They launch the app's
 * real entry with a typed [ReviewLaunch] and drive it through the platform accessibility tree and
 * injected touches, as an operator or TalkBack reaches it, in real time: no Compose test clock, no
 * mounted composable. Identifiers are the shared Compose test tags (as resource ids, or the tag the
 * accessibility node reports on request), labels are content descriptions or text.
 */
@RunWith(AndroidJUnit4::class)
public abstract class ConformanceTest(protected val subject: ConformanceApp) {
    public val instrumentation: Instrumentation = InstrumentationRegistry.getInstrumentation()
    public val automation: UiAutomation = instrumentation.uiAutomation.also { automation ->
        // Dialogs and popups are windows of their own; scenarios read every window of the app.
        automation.serviceInfo = automation.serviceInfo.apply {
            flags = flags or AccessibilityServiceInfo.FLAG_RETRIEVE_INTERACTIVE_WINDOWS or
                AccessibilityServiceInfo.FLAG_REPORT_VIEW_IDS or
                AccessibilityServiceInfo.FLAG_INCLUDE_NOT_IMPORTANT_VIEWS
        }
    }
    private val target: String = instrumentation.targetContext.packageName
    private val tags = HashMap<AccessibilityNodeInfo, String?>()
    private var scenario: ActivityScenario<out Activity>? = null
    private var snapshotStages = ""

    /** The profile the app's androidTest source set declared. */
    public val profile: ConformanceProfile get() = subject.profile

    /** Pixels per dp, for tolerances written in dp as the Swift kit writes them in points. */
    public val density: Float = instrumentation.targetContext.resources.displayMetrics.density

    /** The orientation the kit froze: portrait at the start of each scenario, then what [rotate] set. */
    private var frozenLandscape = false

    @Before
    public fun startInPortrait() {
        // Also set by the run listener; idempotent, so a bundle without the listener is covered too.
        SystemHints.suppress(automation)
        // A scenario that ended in landscape leaves the display turned; start each one upright.
        // [launch] freezes again once the app is in front and checks that its window turned.
        frozenLandscape = false
        automation.setRotation(rotationFor(landscape = false))
    }

    @After
    public fun closeTheApp() {
        scenario?.close()
        scenario = null
        automation.setRotation(UiAutomation.ROTATION_UNFREEZE)
    }

    /** Launches the app's real entry with [review] staged by the app's own debug harness. */
    public fun launch(review: ReviewLaunch): ActivityScenario<out Activity> {
        scenario?.close()
        val intent = Intent(instrumentation.targetContext, subject.activity)
        review.extras.forEach { (key, value) -> intent.putExtra(key, value) }
        val launched = ActivityScenario.launch<Activity>(intent).also { scenario = it }
        // Android 14+ restores the user rotation a portrait-only launcher overrode once an app comes to
        // front (DisplayRotationReversionController#revertOverride), which undoes a freeze made while the
        // launcher showed and opens the app in the previous scenario's rotation. Freeze again now that
        // the app is in front; rotate fails clearly if the app does not turn.
        rotate(frozenLandscape)
        return launched
    }

    /**
     * Launches the app's real launcher entry with nothing staged, as the operator opens it: the
     * production camera list and saved connections (physical qualification only).
     */
    public fun launchProduction(): ActivityScenario<out Activity> {
        scenario?.close()
        val intent = Intent(instrumentation.targetContext, subject.activity)
        return ActivityScenario.launch<Activity>(intent).also { scenario = it }
    }

    // MARK: The accessibility tree

    /**
     * Every node of every window the app shows, walked once (at most [bound] nodes; a larger tree is
     * reported [UiSnapshot.complete] false). Nodes keep their parent so a scenario can look inside a
     * container, the way XCUITest's snapshot does.
     */
    public fun snapshot(bound: Int = 5_000): UiSnapshot {
        if (Looper.myLooper() == Looper.getMainLooper()) return readSnapshot(bound)
        var observed: Result<UiSnapshot>? = null
        // The native accessibility client dispatches same-process UI-thread queries directly.
        // The caller still owns the original deadline and the gap between fresh observations.
        instrumentation.runOnMainSync { observed = runCatching { readSnapshot(bound) } }
        return checkNotNull(observed).getOrThrow()
    }

    private fun readSnapshot(bound: Int): UiSnapshot {
        val began = SystemClock.uptimeMillis()
        // Native cache entries can outlive Compose layout updates; every observation is current.
        if (Build.VERSION.SDK_INT >= 34) automation.clearCache()
        val cacheCleared = SystemClock.uptimeMillis()
        val windows = automation.windows.mapNotNull { window ->
            val root = window.root ?: return@mapNotNull null
            if (root.packageName?.toString() != target) return@mapNotNull null
            val bounds = Rect().also(window::getBoundsInScreen)
            UiWindow(window.id, window.layer, bounds.box(), root)
        }
        val windowsRead = SystemClock.uptimeMillis()
        var childMs = 0L
        var tagMs = 0L
        val nodes = ArrayList<UiNode>()
        var complete = true
        for (window in windows.sortedBy { it.layer }) {
            val pending = ArrayDeque(listOf(Triple(window.root, -1, false)))
            while (pending.isNotEmpty()) {
                if (nodes.size >= bound) {
                    complete = false
                    break
                }
                val (info, parent, scrolling) = pending.removeFirst()
                val index = nodes.size
                val tagBegan = SystemClock.uptimeMillis()
                val tag = tagOf(info)
                tagMs += SystemClock.uptimeMillis() - tagBegan
                nodes += UiNode(info, tag, labelOf(info), window, parent, scrolling)
                val inScroll = scrolling || info.isScrollable
                for (child in 0 until info.childCount) {
                    val childBegan = SystemClock.uptimeMillis()
                    val descendant = info.getChild(child)
                    childMs += SystemClock.uptimeMillis() - childBegan
                    descendant?.let { pending.addLast(Triple(it, index, inScroll)) }
                }
            }
        }
        val walked = SystemClock.uptimeMillis()
        val labelled = spoken(nodes)
        val finished = SystemClock.uptimeMillis()
        snapshotStages = "cacheMs=${cacheCleared - began} windowsMs=${windowsRead - cacheCleared} " +
            "walkMs=${walked - windowsRead} childMs=$childMs tagMs=$tagMs " +
            "spokenMs=${finished - walked} nodes=${nodes.size} windows=${windows.size} complete=$complete"
        return UiSnapshot(labelled, windows, complete)
    }

    /**
     * What TalkBack announces for a node it focuses that has no description or text of its own (a
     * Material button whose label is its child `Text`): the labels of the descendants it does not focus
     * separately, in order. Compose exposes such a button as an unlabelled clickable node over its text.
     */
    private fun spoken(nodes: List<UiNode>): List<UiNode> {
        val children = nodes.indices.groupBy { nodes[it].parent }
        fun focusable(node: UiNode) = node.info.isClickable || node.info.isFocusable || node.info.isScreenReaderFocusable
        fun inner(index: Int): List<String> = children[index].orEmpty().flatMap { child ->
            val node = nodes[child]
            if (focusable(node)) emptyList() else listOfNotNull(node.label.ifBlank { null }) + inner(child)
        }
        return nodes.mapIndexed { index, node ->
            if (node.label.isNotBlank() || !focusable(node)) node
            else inner(index).joinToString(", ").takeIf { it.isNotEmpty() }
                ?.let { UiNode(node.info, node.tag, it, node.window, node.parent, node.inScroll) } ?: node
        }
    }

    /** The first node [match] admits within [timeoutMs]; fails with the tree and a screenshot otherwise. */
    public fun await(what: String, timeoutMs: Long = 15_000, match: (UiNode) -> Boolean): UiNode {
        val deadline = SystemClock.uptimeMillis() + timeoutMs
        while (true) {
            snapshot().nodes.firstOrNull { it.visible && match(it) }?.let { return it }
            if (SystemClock.uptimeMillis() > deadline) fail("$what did not appear")
            pause(150)
        }
    }

    public fun awaitTag(tag: String, timeoutMs: Long = 15_000): UiNode = await(tag, timeoutMs) { it.tag == tag }

    public fun awaitLabel(label: String, timeoutMs: Long = 15_000): UiNode = await(label, timeoutMs) { it.label == label }

    /** True once no visible node [match] admits, within [timeoutMs]. */
    public fun awaitGone(timeoutMs: Long = 10_000, match: (UiNode) -> Boolean): Boolean {
        val deadline = SystemClock.uptimeMillis() + timeoutMs
        while (SystemClock.uptimeMillis() <= deadline) {
            if (snapshot().nodes.none { it.visible && match(it) }) return true
            pause(150)
        }
        return false
    }

    /** The visible node tagged [tag] now, or null. */
    public fun node(tag: String): UiNode? = snapshot().nodes.firstOrNull { it.visible && it.tag == tag }

    /**
     * The node [match] admits, scrolled wholly into its scrolling container first (as a TalkBack user's
     * focus brings it): the node's own show-on-screen action, else its container scrolled towards it.
     * Compose leaves a scrolled-away child out of the tree altogether; with [container] (the tag of the
     * scrolling container that holds it) an absent node is looked for by scrolling that container
     * forward to its end, then back, as TalkBack's next and previous gestures do.
     */
    public fun reveal(
        what: String, timeoutMs: Long = 15_000, container: String? = null, match: (UiNode) -> Boolean,
    ): UiNode {
        val deadline = SystemClock.uptimeMillis() + timeoutMs
        var attempts = 0
        var searchForward = true
        while (true) {
            val snapshot = snapshot()
            val node = snapshot.nodes.firstOrNull(match)
            val holder = container?.let { tag -> snapshot.nodes.firstOrNull { it.visible && it.tag == tag && it.info.isScrollable } }
            if (node == null && holder != null && SystemClock.uptimeMillis() <= deadline) {
                val action = if (searchForward) AccessibilityNodeInfo.ACTION_SCROLL_FORWARD else AccessibilityNodeInfo.ACTION_SCROLL_BACKWARD
                if (!holder.info.performAction(action)) {
                    if (!searchForward) fail("$what is not in $container")
                    searchForward = false
                }
                pause(400)
                continue
            }
            if (node != null) {
                val viewport = snapshot.viewport(node)
                if (node.visible && (viewport == null || viewport.shows(node.bounds))) return node
                if (attempts++ >= 8) fail("$what cannot be brought on screen")
                val scroller = snapshot.scroller(node)
                val shown = node.info.performAction(AccessibilityNodeInfo.AccessibilityAction.ACTION_SHOW_ON_SCREEN.id)
                if (!shown && scroller != null && viewport != null) {
                    val forward = node.bounds.bottom > viewport.bottom || node.bounds.right > viewport.right
                    scroller.info.performAction(
                        if (forward) AccessibilityNodeInfo.ACTION_SCROLL_FORWARD else AccessibilityNodeInfo.ACTION_SCROLL_BACKWARD)
                }
                pause(400)
            } else if (SystemClock.uptimeMillis() > deadline) {
                fail("$what did not appear")
            } else {
                pause(150)
            }
        }
    }

    // MARK: Touch

    /**
     * Taps [node] where it rests now. XCUITest waits for the app to go idle before a tap; here the same
     * node (its tag, else its label, nearest where it was found) must keep its frame across two
     * snapshots first, so a node found while its sheet was still sliding in is not tapped where it was.
     */
    public fun tap(node: UiNode) {
        val bounds = settled(node).bounds
        tapAt(bounds.centerX, bounds.centerY)
    }

    private fun settled(node: UiNode, timeoutMs: Long = 2_000): UiNode {
        val deadline = SystemClock.uptimeMillis() + timeoutMs
        val observations = ArrayList<String>()
        observations += "target tag=${node.tag} label=${node.label} bounds=${node.bounds} timeoutMs=$timeoutMs"
        fun readinessFailure(message: String): Nothing {
            evidence("${javaClass.simpleName}-tap-readiness-${SystemClock.uptimeMillis()}.txt",
                observations.joinToString("\n"))
            fail(message)
        }
        var previous: Box? = null
        while (SystemClock.uptimeMillis() < deadline) {
            val snapshotStarted = SystemClock.uptimeMillis()
            val current = snapshot()
            val snapshotFinished = SystemClock.uptimeMillis()
            val stages = snapshotStages
            val now = current.nodes.filter {
                it.visible && if (node.tag != null) it.tag == node.tag else it.label == node.label
            }.minByOrNull { abs(it.bounds.centerX - node.bounds.centerX) + abs(it.bounds.centerY - node.bounds.centerY) }
            if (now == null) {
                observations += "startMs=${snapshotStarted - (deadline - timeoutMs)} " +
                    "endMs=${snapshotFinished - (deadline - timeoutMs)} " +
                    "snapshotMs=${snapshotFinished - snapshotStarted} $stages target=missing previous=$previous"
                readinessFailure("The target disappeared before input")
            }
            val viewport = current.viewport(now)
            val admitted = now.enabled && now.bounds.width > 0 && now.bounds.height > 0 &&
                now.window.bounds.containsPoint(now.bounds.centerX, now.bounds.centerY) &&
                (viewport == null || viewport.shows(now.bounds)) && !current.covers(now)
            if (admitted && now.bounds == previous && SystemClock.uptimeMillis() < deadline) return now
            observations += "startMs=${snapshotStarted - (deadline - timeoutMs)} " +
                "endMs=${snapshotFinished - (deadline - timeoutMs)} snapshotMs=${snapshotFinished - snapshotStarted} $stages " +
                "tag=${now.tag} label=${now.label} bounds=${now.bounds} window=${now.window.id} " +
                "layer=${now.window.layer} windowBounds=${now.window.bounds} enabled=${now.enabled} " +
                "positive=${now.bounds.width > 0 && now.bounds.height > 0} " +
                "centerInside=${now.window.bounds.containsPoint(now.bounds.centerX, now.bounds.centerY)} " +
                "viewport=$viewport viewportAdmitted=${viewport == null || viewport.shows(now.bounds)} " +
                "covered=${current.covers(now)} admitted=$admitted previous=$previous stable=${now.bounds == previous} " +
                "elapsedMs=${SystemClock.uptimeMillis() - (deadline - timeoutMs)}"
            previous = if (admitted) now.bounds else null
            pause(minOf(120, maxOf(0, deadline - SystemClock.uptimeMillis())))
        }
        readinessFailure("The target never became enabled, uncovered and stable before input")
    }

    public fun tapAt(x: Int, y: Int) {
        val down = SystemClock.uptimeMillis()
        touch(MotionEvent.ACTION_DOWN, x, y, down, down)
        SystemClock.sleep(60)
        touch(MotionEvent.ACTION_UP, x, y, down, SystemClock.uptimeMillis())
        pause(250)
    }

    /** A finger held [holdMs] at the start, then moved to the end over [moveMs], then lifted. */
    public fun drag(fromX: Int, fromY: Int, toX: Int, toY: Int, holdMs: Long = 0, moveMs: Long = 300) {
        val down = SystemClock.uptimeMillis()
        touch(MotionEvent.ACTION_DOWN, fromX, fromY, down, down)
        if (holdMs > 0) SystemClock.sleep(holdMs)
        val steps = 12
        for (step in 1..steps) {
            val x = fromX + (toX - fromX) * step / steps
            val y = fromY + (toY - fromY) * step / steps
            SystemClock.sleep(moveMs / steps)
            touch(MotionEvent.ACTION_MOVE, x, y, down, SystemClock.uptimeMillis())
        }
        touch(MotionEvent.ACTION_UP, toX, toY, down, SystemClock.uptimeMillis())
        pause(400)
    }

    /** Long-presses [from] and drags to [to] (the shared media selection sweep). */
    public fun pressAndDrag(from: Box, to: Box) {
        drag(from.centerX, from.centerY, to.centerX, to.centerY, holdMs = 450, moveMs = 500)
    }

    /** One upward fling inside [container], moving its content towards its end. */
    public fun swipeUp(container: Box) {
        drag(container.centerX, container.top + container.height * 4 / 5, container.centerX,
            container.top + container.height / 5, moveMs = 180)
    }

    /** The system Back, as the operator's gesture or button sends it. */
    public fun pressBack() {
        automation.performGlobalAction(AccessibilityService.GLOBAL_ACTION_BACK)
        pause(400)
    }

    private fun touch(action: Int, x: Int, y: Int, down: Long, time: Long) {
        val event = MotionEvent.obtain(down, time, action, x.toFloat(), y.toFloat(), 0)
        event.source = InputDevice.SOURCE_TOUCHSCREEN
        try {
            check(automation.injectInputEvent(event, true)) { "Touch injection failed at $x,$y" }
        } finally {
            event.recycle()
        }
    }

    // MARK: Device

    /**
     * Turns the device, then waits until the app's window has turned and [settling] (the app window by
     * default) has kept its frame for half a second, as the Swift kit's `rotate` does.
     */
    public fun rotate(landscape: Boolean, settling: (() -> UiNode?)? = null) {
        frozenLandscape = landscape
        automation.setRotation(rotationFor(landscape))
        val deadline = SystemClock.uptimeMillis() + 10_000
        while (mainWindow()?.let { (it.width > it.height) == landscape } != true) {
            if (SystemClock.uptimeMillis() > deadline) {
                fail("The app must turn to ${if (landscape) "landscape" else "portrait"}")
            }
            pause(150)
        }
        settle { listOfNotNull(mainWindow(), settling?.invoke()?.bounds) }
    }

    /** Sets the system light or dark appearance for the app's next launch (and the running one). */
    public fun appearance(dark: Boolean) {
        shell("cmd uimode night ${if (dark) "yes" else "no"}")
        val deadline = SystemClock.uptimeMillis() + 5_000
        while (isDark() != dark && SystemClock.uptimeMillis() < deadline) pause(100)
    }

    public fun isDark(): Boolean =
        Resources.getSystem().configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK == Configuration.UI_MODE_NIGHT_YES

    /** The device class and size the evidence names carry: `phone411dp`, `tablet800dp`. */
    public val device: String by lazy {
        val smallest = instrumentation.targetContext.resources.configuration.smallestScreenWidthDp
        "${if (smallest >= 600) "tablet" else "phone"}${smallest}dp"
    }

    /**
     * Whether the panel is landscape at rotation 0, from the display mode's physical size. The size
     * and rotation an app process reads can disagree after a scenario left the display turned (the
     * launcher shows upright on a turned display), which once made "portrait" freeze rotation 90.
     */
    private val naturalLandscape: Boolean by lazy {
        val mode = instrumentation.targetContext.getSystemService(DisplayManager::class.java)
            .getDisplay(Display.DEFAULT_DISPLAY).mode
        mode.physicalWidth > mode.physicalHeight
    }

    private fun rotationFor(landscape: Boolean): Int =
        if (landscape == naturalLandscape) UiAutomation.ROTATION_FREEZE_0 else UiAutomation.ROTATION_FREEZE_90

    /** The app's activity window: its lowest app window. */
    public fun mainWindow(): Box? =
        automation.windows.filter { it.root?.packageName?.toString() == target }.minByOrNull { it.layer }
            ?.let { window -> Rect().also(window::getBoundsInScreen).box() }

    /**
     * What hides part of the app's window, in screen pixels: each visible system bar and the display
     * cutout's own outline (not its inset band: controls may use the corners beside a punch hole).
     */
    public fun hiddenAreas(): List<Pair<String, Box>> {
        val areas = mutableListOf<Pair<String, Box>>()
        scenario?.onActivity { activity ->
            val decor = activity.window.decorView
            val insets = decor.rootWindowInsets ?: return@onActivity
            val origin = IntArray(2).also(decor::getLocationOnScreen)
            val frame = Box(origin[0], origin[1], origin[0] + decor.width, origin[1] + decor.height)
            val (left, top, right, bottom) = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                insets.getInsets(WindowInsets.Type.systemBars()).let { listOf(it.left, it.top, it.right, it.bottom) }
            } else {
                @Suppress("DEPRECATION")
                listOf(insets.stableInsetLeft, insets.stableInsetTop, insets.stableInsetRight, insets.stableInsetBottom)
            }
            if (left > 0) areas += "system bar" to Box(frame.left, frame.top, frame.left + left, frame.bottom)
            if (top > 0) areas += "system bar" to Box(frame.left, frame.top, frame.right, frame.top + top)
            if (right > 0) areas += "system bar" to Box(frame.right - right, frame.top, frame.right, frame.bottom)
            if (bottom > 0) areas += "system bar" to Box(frame.left, frame.bottom - bottom, frame.right, frame.bottom)
            insets.displayCutout?.boundingRects?.forEach { cutout ->
                areas += "display cutout" to Rect(cutout).apply { offset(origin[0], origin[1]) }.box()
            }
        }
        return areas
    }

    // MARK: Checkpoints and evidence

    /**
     * A scenario's key state. Every enabled, clickable `monitor.*` control outside a scrolling list
     * must lie inside its window, and no two uncovered ones whose tags start with [operable] may
     * overlap within one window (a mode that makes the rest inert, the chrome editor, names its own
     * controls). The screenshot matrix also requires that none lies under a system bar or the display
     * cutout ([safeArea], [hiddenAreas]); the behavior scenarios leave layout to it. The screen is then saved as
     * `<app>-<device>-<orientation>-<scenario>-<name>.png`, before any failure is reported.
     */
    public fun checkpoint(name: String, operable: String = "monitor.", safeArea: Boolean = false) {
        val snapshot = snapshot()
        val controls = snapshot.nodes.filter {
            it.visible && it.tag?.startsWith("monitor.") == true && it.info.isClickable && it.info.isEnabled &&
                !it.inScroll && !it.bounds.isEmpty
        }.map { CheckpointControl(it.tag!!, it.bounds, it.window.id, it.window.bounds, snapshot.covers(it)) }
        val window = mainWindow()
        val landscape = window != null && window.width > window.height
        val evidence = CheckpointGeometry.evidenceName(profile.app, device, landscape, javaClass.simpleName, name)
        capture(evidence)
        // Each message starts with the screenshot's name, so a report puts it next to the screenshot.
        val problems = CheckpointGeometry.violations(
            evidence, controls, if (safeArea) hiddenAreas() else emptyList(), operable, tolerance = 1,
            overlapSlack = ceil(density).toInt())
        if (problems.isNotEmpty()) fail(problems.joinToString("\n"), dump = false)
    }

    /** Saves a screenshot of the whole device as `conformance/<name>.png` in the test storage. */
    public fun capture(name: String) {
        val bitmap = automation.takeScreenshot() ?: return
        output("$name.png").use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
    }

    /** Saves [text] as `conformance/<name>` in the test storage, beside the screenshots. */
    public fun evidence(name: String, text: String) {
        output(name).use { it.write(text.toByteArray()) }
    }

    /** Cancels the presented confirmation with its Cancel button; [confirm] (its confirming action) must then be gone. */
    public fun cancelConfirmation(confirm: (UiNode) -> Boolean) {
        val snapshot = snapshot()
        val cancel = snapshot.nodes.firstOrNull {
            it.visible && it.label == "Cancel" && it.info.isClickable && !snapshot.covers(it)
        } ?: fail("The confirmation offers no Cancel button")
        tap(cancel)
        if (!awaitGone(match = confirm)) fail("The confirmation must close on Cancel")
    }

    /** Dismisses the presented confirmation with the system Back; [confirm] must then be gone. */
    public fun backOutOfConfirmation(confirm: (UiNode) -> Boolean) {
        pressBack()
        if (!awaitGone(match = confirm)) fail("The confirmation must close on Back")
    }

    /** Fails the scenario with a screenshot and the app's tree attached. */
    public fun fail(message: String, dump: Boolean = true): Nothing {
        if (dump) {
            val stamp = "${javaClass.simpleName}-failure-${SystemClock.uptimeMillis()}"
            runCatching { capture(stamp) }
            runCatching { output("$stamp.txt").use { it.write(describe(snapshot()).toByteArray()) } }
        }
        throw AssertionError(message)
    }

    public fun pause(milliseconds: Long) {
        SystemClock.sleep(milliseconds)
    }

    /** Waits until [frames] reports the same rectangles for half a second (at most ten). */
    public fun settle(frames: () -> List<Box>) {
        var previous: List<Box>? = null
        var since = SystemClock.uptimeMillis()
        val deadline = since + 10_000
        while (SystemClock.uptimeMillis() < deadline) {
            val current = frames()
            if (current != previous) {
                previous = current
                since = SystemClock.uptimeMillis()
            } else if (SystemClock.uptimeMillis() - since >= 500) {
                return
            }
            pause(100)
        }
    }

    public fun shell(command: String): String =
        ParcelFileDescriptor.AutoCloseInputStream(automation.executeShellCommand(command)).bufferedReader().use { it.readText() }

    private fun output(name: String): OutputStream {
        val path = "conformance/$name"
        return runCatching { PlatformTestStorageRegistry.getInstance().openOutputFile(path) }.getOrElse {
            File(instrumentation.targetContext.getExternalFilesDir(null), path).apply { parentFile?.mkdirs() }.outputStream()
        }
    }

    private fun describe(snapshot: UiSnapshot): String = buildString {
        for (window in snapshot.windows) appendLine("window ${window.id} layer=${window.layer} bounds=${window.bounds}")
        for (node in snapshot.nodes) {
            var depth = 0
            var parent = node.parent
            while (parent >= 0) {
                depth += 1
                parent = snapshot.nodes[parent].parent
            }
            append("  ".repeat(depth))
            appendLine("tag=${node.tag} label=${node.label.take(120)} state=${node.state} visible=${node.visible} " +
                "clickable=${node.info.isClickable} enabled=${node.info.isEnabled} selected=${node.selected} " +
                "scrollable=${node.info.isScrollable} bounds=${node.bounds} window=${node.window.id}")
        }
        if (!snapshot.complete) appendLine("(truncated)")
    }

    private fun tagOf(info: AccessibilityNodeInfo): String? {
        info.viewIdResourceName?.let { return it.substringAfter(":id/") }
        if (TEST_TAG !in info.availableExtraData) return null
        return tags.getOrPut(info) {
            info.refreshWithExtraData(TEST_TAG, Bundle())
            info.extras.getCharSequence(TEST_TAG)?.toString()
        }
    }

    private fun labelOf(info: AccessibilityNodeInfo): String =
        (info.contentDescription ?: info.text)?.toString()?.trim().orEmpty()

    private companion object {
        /** The extra a Compose node reports its test tag under, when asked. */
        const val TEST_TAG = "androidx.compose.ui.semantics.testTag"
    }
}

internal fun Rect.box(): Box = Box(left, top, right, bottom)

/**
 * True when [bounds] lies wholly inside this scrolling viewport along the axis it scrolls (a wide
 * viewport scrolls sideways). Across that axis a control may reach past the viewport: Compose grows a
 * small control's touch bounds to the minimum touch target, beyond a slim tab strip.
 */
internal fun Box.shows(bounds: Box): Boolean =
    if (width > height) bounds.left >= left - 1 && bounds.right <= right + 1
    else bounds.top >= top - 1 && bounds.bottom <= bottom + 1
