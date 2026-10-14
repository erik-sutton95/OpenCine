package com.opencapture.opencine.appuitesting

import android.graphics.Rect
import android.os.Build
import android.view.accessibility.AccessibilityNodeInfo

/** One window of the app (the activity, a dialog, a popup) as the accessibility service sees it. */
public class UiWindow internal constructor(
    public val id: Int,
    /** Higher layers are drawn, and receive touches, above lower ones. */
    public val layer: Int,
    public val bounds: Box,
    internal val root: AccessibilityNodeInfo,
)

/** One accessibility node, read once per snapshot (XCUITest's element snapshot). */
public class UiNode internal constructor(
    public val info: AccessibilityNodeInfo,
    /** The shared Compose test tag (`monitor.system.record`), or null. */
    public val tag: String?,
    /** What TalkBack announces first: the content description, else the text. */
    public val label: String,
    public val window: UiWindow,
    /** Index of the parent in [UiSnapshot.nodes], -1 for a window root. */
    public val parent: Int,
    /** Inside a scrolling list, whose content may legitimately pass the window's edges. */
    public val inScroll: Boolean,
) {
    public val bounds: Box = Rect().also(info::getBoundsInScreen).box()
    public val visible: Boolean = info.isVisibleToUser
    public val selected: Boolean get() = info.isSelected || info.isChecked
    public val enabled: Boolean get() = info.isEnabled
    /** The state TalkBack announces (`On`, `Shown`), the twin of an iOS accessibility value. */
    public val state: String? get() =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) info.stateDescription?.toString() else null
}

/** Every node of every app window at one moment. */
public class UiSnapshot internal constructor(
    public val nodes: List<UiNode>,
    public val windows: List<UiWindow>,
    /** False when the walk stopped at its node bound. */
    public val complete: Boolean,
) {
    /** True when a higher app window lies over [node]'s centre, so a touch there would not reach it. */
    public fun covers(node: UiNode): Boolean = windows.any {
        it.layer > node.window.layer && it.bounds.containsPoint(node.bounds.centerX, node.bounds.centerY)
    }

    /** The bounds of [node]'s nearest scrolling ancestor, or null. */
    public fun viewport(node: UiNode): Box? {
        var index = node.parent
        while (index >= 0) {
            val ancestor = nodes[index]
            if (ancestor.info.isScrollable) return ancestor.bounds
            index = ancestor.parent
        }
        return null
    }

    /** The nearest scrolling ancestor of [node], or null. */
    public fun scroller(node: UiNode): UiNode? {
        var index = node.parent
        while (index >= 0) {
            val ancestor = nodes[index]
            if (ancestor.info.isScrollable) return ancestor
            index = ancestor.parent
        }
        return null
    }

    /** The nodes below [node]. */
    public fun descendants(node: UiNode): List<UiNode> {
        val root = nodes.indexOf(node)
        return nodes.filterIndexed { index, _ ->
            var parent = nodes[index].parent
            while (parent >= 0 && parent != root) parent = nodes[parent].parent
            index != root && parent == root
        }
    }
}
