package com.opencapture.monitorui

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class MonitorWatcherLayoutTest {
    @Test fun readOnlySourceStillOwnsItsMeasuredPicture() {
        val source = MonitorWatcherTapSource("source", 1, false)
        val geometry = MonitorWatcherPictureGeometry(source, MonitorRect(0f, 0f, 844f, 390f),
            MonitorRect(100f, 0f, 640f, 360f), 10.0, true)
        assertTrue(geometry.belongsTo(source))
        assertEquals(640f, geometry.feed.width)
        assertTrue(geometry.mirrored)
    }
    @Test fun measuredPictureCannotCrossSourceOrSameNameRevisionReplacement() {
        val source = MonitorWatcherTapSource("same-name", 1, true)
        val geometry = MonitorWatcherPictureGeometry(source, MonitorRect(0f, 0f, 0f, 0f),
            MonitorRect(0f, 0f, 0f, 0f), 10.0, false)
        assertFalse(geometry.belongsTo(MonitorWatcherTapSource("same-name", 3, true)))
        assertFalse(geometry.belongsTo(MonitorWatcherTapSource("replacement", 1, true)))
    }
    @Test fun connectionKeyLaneKeepsBothOriginalClearances() {
        assertEquals(192.0, MonitorWatcherControlPlacement.bottomInset(true))
        assertEquals(84.0, MonitorWatcherControlPlacement.bottomInset(false))
    }
    @Test fun passcodeEntryRetainsFourDecimalDigitsAndRequiresACompleteDraft() {
        val draft = MonitorWatcherPasscodeDraft()
        draft.update("a1 b2 c3")
        assertEquals("123", draft.digits)
        assertNull(draft.complete)
        draft.update("a1 b2 c3 d4 e5")
        assertEquals("1234", draft.digits)
        assertEquals("1234", draft.complete)
        draft.update("١٢٣٤")
        assertEquals("١٢٣٤", draft.complete)
        draft.update("")
        assertNull(draft.complete)
    }
}
