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
    @Test fun passcodeRuleTakesAnyTextOfFourCharactersTrimmed() {
        val rule = MonitorWatcherPasscodeRule
        assertEquals(4, rule.MINIMUM_LENGTH)
        assertEquals(MonitorWatcherPasscodeRule.Entry.Open, rule.entry(""))
        assertEquals(MonitorWatcherPasscodeRule.Entry.Open, rule.entry(" \t\n\u00A0"))
        assertEquals(MonitorWatcherPasscodeRule.Entry.TooShort, rule.entry("abc"))
        assertEquals(MonitorWatcherPasscodeRule.Entry.TooShort, rule.entry("  abc  "))
        assertEquals(MonitorWatcherPasscodeRule.Entry.Code("abcd"), rule.entry("abcd"))
        assertEquals(MonitorWatcherPasscodeRule.Entry.Code("set pass"), rule.entry(" set pass\n"))
        assertEquals(MonitorWatcherPasscodeRule.Entry.Code("a1 b2 c3"), rule.entry("a1 b2 c3"))
        assertEquals(MonitorWatcherPasscodeRule.Entry.Code("pässwörd"), rule.entry("\u2003pässwörd\u0085"))
        // Code points, so Swift's Unicode-scalar count agrees.
        assertEquals(MonitorWatcherPasscodeRule.Entry.TooShort, rule.entry("🎬🎬"))
        assertEquals(MonitorWatcherPasscodeRule.Entry.Code("🎬🎬🎬🎬"), rule.entry("🎬🎬🎬🎬"))
        // Swift's whitespacesAndNewlines set, not Java's isWhitespace (U+001F is not trimmed).
        assertEquals("\u001Fabcd", rule.normalized("\u001Fabcd"))
        assertEquals("", MonitorWatcherPasscodeRule.Entry.Open.passcode)
        assertEquals("abcd", MonitorWatcherPasscodeRule.Entry.Code("abcd").passcode)
        assertNull(MonitorWatcherPasscodeRule.Entry.TooShort.passcode)
    }
    @Test fun everySavedPasscodeFormStaysUsable() {
        // OpenZCine saved four decimal digits (the only app with a relay on Android). Each still
        // takes effect when chosen again and is always a valid watcher answer.
        for (saved in listOf("0000", "4821", "١٢٣٤", "set pass", "pässwörd", "abcdefghijklmnopqrstuvwxyz0123456789")) {
            assertEquals(MonitorWatcherPasscodeRule.Entry.Code(saved), MonitorWatcherPasscodeRule.entry(saved), saved)
            assertEquals(saved, MonitorWatcherPasscodeRule.answer(saved), saved)
        }
        for (saved in listOf("a", "ab1", " abc ")) {
            assertEquals(MonitorWatcherPasscodeRule.normalized(saved), MonitorWatcherPasscodeRule.answer(saved))
        }
        assertEquals("1234", MonitorWatcherPasscodeRule.answer(" 1234 "))
        assertNull(MonitorWatcherPasscodeRule.answer("  "))
    }
}
