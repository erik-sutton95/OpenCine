package com.opencapture.opencine.cameracontrols

import com.opencapture.monitorui.MonitorRect
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse

class MonitorOperatorChromeBoundsTest {
    private val deck = MonitorRect(16f, 38f, 288f, 44f)
    private val storage = MonitorRect(14f, 0f, 86f, 48f)
    private val link = MonitorRect(108f, 13f, 55.5f, 22f)
    private val power = MonitorRect(172f, 13f, 134f, 22f)

    @Test fun statusFragmentsHaveOneCompleteOwnerInEveryCallbackOrder() {
        val frames = mapOf("deck" to deck, "storage" to storage, "link" to link)
        val orders = listOf(listOf("deck", "storage", "link"), listOf("deck", "link", "storage"),
            listOf("storage", "deck", "link"), listOf("storage", "link", "deck"),
            listOf("link", "deck", "storage"), listOf("link", "storage", "deck"))
        for (order in orders) {
            val boxes = mutableMapOf("power" to power)
            val owner = MonitorOperatorChromeBounds { rect ->
                if (rect == null) boxes.remove("status") else boxes["status"] = rect
            }
            order.forEach { owner.update(it, frames.getValue(it)) }
            assertEquals(MonitorRect(14f, 0f, 290f, 82f), boxes["status"])
            assertEquals(power, boxes["power"], "Power retains its independent owner")
        }
    }

    @Test fun changedAndDisposedFragmentsDoNotLeaveStaleBadgeBounds() {
        val boxes = mutableMapOf("power" to power)
        val owner = MonitorOperatorChromeBounds { rect ->
            if (rect == null) boxes.remove("status") else boxes["status"] = rect
        }
        owner.update("deck", deck); owner.update("storage", storage); owner.update("link", link)
        owner.update("deck", deck.copy(width = 320f))
        assertEquals(336f, boxes.getValue("status").maxX)
        owner.update("deck", deck)
        assertEquals(304f, boxes.getValue("status").maxX)
        owner.remove("deck")
        assertEquals(MonitorRect(14f, 0f, 149.5f, 48f), boxes["status"])
        owner.remove("link")
        assertEquals(storage, boxes["status"])
        owner.update("storage", MonitorRect(0f, 0f, 0f, 0f))
        assertFalse("status" in boxes)
        assertEquals(power, boxes["power"])
    }
}
