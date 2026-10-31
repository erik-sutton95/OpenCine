package com.opencapture.monitorui

import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * The translation half of the shared copy.
 *
 * `Fixtures/playback-copy.tsv` already lists every string the playback surface can show, and the
 * vector tests pin the English. This test reads the same rows to prove three things: every row has
 * a simplified Chinese translation, resolving in English reproduces the vectors byte for byte, and
 * a translation whose English no longer matches is reported instead of being silently ignored.
 */
class CopyTranslationTest {
    private val rows: List<List<String>> =
        File(System.getProperty("opencine.fixtures"), "playback-copy.tsv")
            .takeIf { it.isFile }
            ?.readLines()
            .orEmpty()
            .filter { it.isNotBlank() && !it.startsWith("#") }
            .map { it.split("\t") }

    private fun rows(kind: String) = rows.filter { it[0] == kind }

    private val chinese = CopyLanguage.SIMPLIFIED_CHINESE
    private val catalog = CopyCatalog.bundled
    private val english = MonitorPlaybackCopy.resolved(CopyLanguage.ENGLISH)
    private val simplified = MonitorPlaybackCopy.resolved(chinese)

    /** Every English key this surface can produce, constants and composed units alike. */
    private val keys: List<String> =
        rows("text").map { it[2] } +
            listOf(
                MonitorPlaybackCopyUnits.RATE,
                MonitorPlaybackCopyUnits.SECONDS,
                MonitorPlaybackCopyUnits.STAR,
                MonitorPlaybackCopyUnits.STARS,
            )

    /** The fixture writes the scrubber's special inputs in lowercase. */
    private fun seconds(raw: String): Double =
        when (raw) {
            "nan" -> Double.NaN
            "inf" -> Double.POSITIVE_INFINITY
            else -> raw.toDouble()
        }

    @Test
    fun `the bundled catalog carries the shared language`() {
        assertTrue(chinese in catalog.languages, catalog.languages.toString())
    }

    @Test
    fun `every shared playback string has a Chinese row`() {
        assertEquals(emptyList<String>(), catalog.missingKeys(keys, chinese))
    }

    @Test
    fun `no Chinese row is left behind by an edited English string`() {
        assertEquals(emptyList<String>(), catalog.unusedKeys(keys, chinese))
    }

    @Test
    fun `English resolution reproduces the shared vectors`() {
        for (row in rows("transport")) {
            val reachedEnd = row[1] == "1"
            val playing = row[2] == "1"
            assertEquals(row[3], english.transport(reachedEnd = reachedEnd, playing = playing), row.toString())
        }
        for (row in rows("toggle")) assertEquals(row[2], english.toggleValue(row[1] == "1"), row.toString())
        for (row in rows("mute")) assertEquals(row[2], english.muteToggle(row[1] == "1"), row.toString())
        for (row in rows("rating")) assertEquals(row[2], english.rating(row[1] == "1"), row.toString())
        for (row in rows("rate")) assertEquals(row[2], english.rate(row[1].toInt()), row.toString())
        for (row in rows("position")) {
            assertEquals(row[2], english.positionValue(seconds(row[1])), row.toString())
        }
        for (row in rows("conform")) assertEquals(row[2], english.conformSubtitle(row[1].toDouble()), row.toString())
        for (row in rows("text")) assertEquals(row[2], catalog.text(row[2], CopyLanguage.ENGLISH), row.toString())
    }

    @Test
    fun `Chinese reads the translated labels`() {
        assertEquals("返回素材", simplified.backToMedia)
        assertEquals("播放", simplified.play)
        assertEquals("暂停", simplified.pause)
        assertEquals("循环播放", simplified.loop)
        assertEquals("片段信息", simplified.clipInformation)
        assertEquals("变速预览", simplified.conformPreview)
        assertEquals("实时速度", simplified.realTime)
    }

    @Test
    fun `Chinese composes the units it shares with English`() {
        assertEquals("7 秒", simplified.positionValue(7.9))
        assertEquals("0 秒", simplified.positionValue(Double.NaN))
        assertEquals("评分 1 星", simplified.rate(1))
        assertEquals("评分 2 星", simplified.rate(2))
    }

    @Test
    fun `derived Chinese labels follow the same branches as English`() {
        assertEquals(simplified.restart, simplified.transport(reachedEnd = true, playing = false))
        assertEquals(simplified.pause, simplified.transport(reachedEnd = false, playing = true))
        assertEquals(simplified.play, simplified.transport(reachedEnd = false, playing = false))
        assertEquals(simplified.unmute, simplified.muteToggle(muted = true))
        assertEquals(simplified.on, simplified.toggleValue(on = true))
        assertEquals(simplified.hideRating, simplified.rating(expanded = true))
    }

    @Test
    fun `translated copy keeps the shared style rules`() {
        for ((key, value) in catalog.entries(chinese)) {
            assertTrue(value.isNotBlank(), "blank translation for $key")
            assertTrue(!value.contains("\u2014"), "em dash in $key")
        }
    }

    @Test
    fun `a language without a table reads English`() {
        val empty = CopyCatalog(emptyMap())
        assertEquals(MonitorPlaybackCopy.PLAY, MonitorPlaybackCopy.resolved(chinese, empty).play)
        assertEquals(MonitorPlaybackCopy.BACK_TO_MEDIA, MonitorPlaybackCopy.resolved(chinese, empty).backToMedia)
    }

    @Test
    fun `language resolution follows the device tags`() {
        assertEquals(chinese, CopyLanguage.resolve(listOf("zh-Hans-CN")))
        assertEquals(chinese, CopyLanguage.resolve(listOf("zh-CN")))
        assertEquals(chinese, CopyLanguage.resolve(listOf("zh_Hans_CN")))
        assertEquals(chinese, CopyLanguage.resolve(listOf("zh")))
        assertEquals(chinese, CopyLanguage.resolve(listOf("zh-CN", "en-US")))
        assertEquals(CopyLanguage.ENGLISH, CopyLanguage.resolve(listOf("zh-TW")))
        assertEquals(CopyLanguage.ENGLISH, CopyLanguage.resolve(listOf("zh-Hant-HK")))
        assertEquals(CopyLanguage.ENGLISH, CopyLanguage.resolve(listOf("zh-MO")))
        assertEquals(CopyLanguage.ENGLISH, CopyLanguage.resolve(listOf("en-GB", "zh-CN")))
        assertEquals(CopyLanguage.ENGLISH, CopyLanguage.resolve(listOf("de-DE")))
        assertEquals(CopyLanguage.ENGLISH, CopyLanguage.resolve(emptyList()))
    }
}
