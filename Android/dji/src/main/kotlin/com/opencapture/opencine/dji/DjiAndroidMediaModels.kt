package com.opencapture.opencine.dji

import com.opencapture.opencine.vocabulary.MediaFile
import com.opencapture.opencine.vocabulary.MediaListCommand as VocabularyListCommand

data class MediaPageSliceInfo(
    val declared: Int,
    val records: Int,
    val endMarker: Boolean,
    val ended: Boolean,
) {
    val incomplete: Boolean
        get() = declared in 1..MediaListCommand.COUNT_MAX && records < declared
}

data class MediaPageStep(
    val fresh: List<MediaFile>,
    val sdCursor: Long,
    val internalCursor: Long,
    val moreAvailable: Boolean,
)

/** `0x00/0x26` list payloads. Byte-identical to Osmosis / Mimo. */
object MediaListCommand {
    const val PAGE_SIZE = 45
    const val COUNT_MAX = 512
    const val NEWEST_SD = 0x00000001L
    const val NEWEST_INTERNAL = 0x40000001L
    const val INTERNAL_BIT = VocabularyListCommand.INTERNAL_BIT
    const val SD_STORAGE = VocabularyListCommand.SD_STORAGE
    const val INTERNAL_STORAGE = VocabularyListCommand.INTERNAL_STORAGE
    const val SD_COUNTER: Int = 1
    const val INTERNAL_COUNTER: Int = 2

    val listTemplate: ByteArray =
        byteArrayOf(
            0x4A, 0x00, 0x2A, 0x10,
            0x01, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x01, 0x00, 0x00, 0x00,
            0x2D, 0x00, 0x0D, 0x01, 0x00,
            0xFF.toByte(), 0xFF.toByte(), 0xFF.toByte(), 0xFF.toByte(),
            0xFF.toByte(), 0xFF.toByte(), 0xFF.toByte(), 0xFF.toByte(),
            0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00,
        )

    val triggerPayload: ByteArray =
        byteArrayOf(
            0x4A, 0x04, 0x0E, 0x10,
            0x01, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x01, 0x00, 0x00, 0x00,
        )

    fun listPayload(counter: Int, cursor: Long): ByteArray {
        val payload = listTemplate.copyOf()
        payload[4] = (counter and 0xFF).toByte()
        payload[10] = (cursor and 0xFF).toByte()
        payload[11] = ((cursor shr 8) and 0xFF).toByte()
        payload[12] = ((cursor shr 16) and 0xFF).toByte()
        payload[13] = ((cursor shr 24) and 0xFF).toByte()
        return payload
    }

    fun storeOf(file: MediaFile): Int = VocabularyListCommand.storeOf(file)

    fun pageKey(file: MediaFile): String = VocabularyListCommand.pageKey(file)

    fun storeSlice(page: List<MediaFile>, store: Int): List<MediaFile> =
        page.filter { storeOf(it) == store }

    fun oldestHandle(page: List<MediaFile>, store: Int, below: Long? = null): Long? =
        storeSlice(page, store)
            .map { it.handle }
            .filter { it != 0L && (below == null || it < below) }
            .minOrNull()

    fun seedPagination(
        page: List<MediaFile>,
        seen: MutableSet<String>,
        slices: Map<Int, MediaPageSliceInfo> = emptyMap(),
    ): MediaPageStep =
        pageStep(NEWEST_SD, NEWEST_INTERNAL, page, seen, slices, initial = true)

    fun stepPagination(
        sdCursor: Long,
        internalCursor: Long,
        page: List<MediaFile>,
        seen: MutableSet<String>,
        slices: Map<Int, MediaPageSliceInfo> = emptyMap(),
    ): MediaPageStep =
        pageStep(sdCursor, internalCursor, page, seen, slices, initial = false)

    fun hasOlderPage(recordCount: Int, cursor: Long?): Boolean {
        val c = cursor ?: return false
        if (c <= 0L) return false
        return recordCount >= PAGE_SIZE
    }

    fun storeHasOlderPage(
        sliceSize: Int,
        cursorMoved: Boolean,
        info: MediaPageSliceInfo?,
    ): Boolean =
        when {
            !cursorMoved -> false
            info == null -> sliceSize >= PAGE_SIZE
            info.incomplete -> true
            info.endMarker -> false
            else -> sliceSize >= PAGE_SIZE
        }

    private fun pageStep(
        sdCursor: Long,
        internalCursor: Long,
        page: List<MediaFile>,
        seen: MutableSet<String>,
        slices: Map<Int, MediaPageSliceInfo>,
        initial: Boolean,
    ): MediaPageStep {
        val fresh = page.filter { seen.add(pageKey(it)) }
        val sdOldest = oldestHandle(page, SD_STORAGE, if (initial) null else sdCursor)
        val internalOldest = oldestHandle(page, INTERNAL_STORAGE, if (initial) null else internalCursor)
        val more =
            fresh.isNotEmpty() &&
                (
                    storeHasOlderPage(
                        storeSlice(page, SD_STORAGE).size,
                        sdOldest != null,
                        slices[SD_STORAGE],
                    ) ||
                        storeHasOlderPage(
                            storeSlice(page, INTERNAL_STORAGE).size,
                            internalOldest != null,
                            slices[INTERNAL_STORAGE],
                        )
                )
        return MediaPageStep(
            fresh = fresh,
            sdCursor = sdOldest ?: sdCursor,
            internalCursor = internalOldest ?: internalCursor,
            moreAvailable = more,
        )
    }
}

object MediaCommands {
    const val SET_GENERAL = 0x00
    const val SET_CAMERA = 0x02
    const val CMD_MEDIA_LIST = 0x26
    const val CMD_MEDIA_CHUNK = 0x27
    const val CMD_MEDIA_DELETE = 0x28
    const val CMD_PLAYBACK = 0x0C
    const val CMD_MEDIA_FAVORITE = 0xBF

    fun enterPlaybackPayload(): ByteArray = byteArrayOf(0x01, 0x01, 0x00, 0x01)

    fun exitPlaybackPayload(): ByteArray = byteArrayOf(0x01, 0x01, 0x00, 0x00)

    /** `0x00/0x28` delete. `[count][handle:u32][counter:u32] 00 [count:u32] 01 01 00 00`. */
    fun deletePayload(handle: Long, counter: Long): ByteArray {
        val out = ByteArray(18)
        out[0] = 0x01
        writeU32LE(out, 1, handle)
        writeU32LE(out, 5, counter)
        out[9] = 0x00
        writeU32LE(out, 10, 1)
        out[14] = 0x01
        out[15] = 0x01
        out[16] = 0x00
        out[17] = 0x00
        return out
    }

    /** `0x02/0xBF` star. `01 01 [handle:u32] [counter:u32] 00 [on:u8] 00 00 00`. */
    fun favoritePayload(handle: Long, on: Boolean, counter: Long): ByteArray {
        val out = ByteArray(15)
        out[0] = 0x01
        out[1] = 0x01
        writeU32LE(out, 2, handle)
        writeU32LE(out, 6, counter)
        out[10] = 0x00
        out[11] = if (on) 0x01 else 0x00
        return out
    }

    fun isReplySuccess(payload: ByteArray): Boolean =
        payload.isNotEmpty() && payload[0] == 0.toByte()
}

internal fun writeU32LE(dest: ByteArray, offset: Int, value: Long) {
    dest[offset] = (value and 0xFF).toByte()
    dest[offset + 1] = ((value shr 8) and 0xFF).toByte()
    dest[offset + 2] = ((value shr 16) and 0xFF).toByte()
    dest[offset + 3] = ((value shr 24) and 0xFF).toByte()
}

internal fun wrappingSub32(a: Long, b: Long): Long = (a - b) and 0xFFFF_FFFFL

internal fun wrappingAdd32(a: Long, b: Long): Long = (a + b) and 0xFFFF_FFFFL

internal fun wrappingMul32(a: Long, b: Long): Long = (a * b) and 0xFFFF_FFFFL
