package com.opencapture.opencine.media

import java.io.File
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * QuickTime `keys` / `ilst` metadata (`mdta` keys) read from the tail of a movie file, where the
 * camera writes `moov`. The caller names the key it wants and maps the value; no vendor key here.
 */
object QuickTimeKeys {
    /** How much of a file's tail is read for `moov`. */
    const val TAIL_BYTES = 2 * 1024 * 1024

    /** HTTP `Range` for the last [TAIL_BYTES] of a [fileSize]-byte file; an unknown size asks for a suffix. */
    fun tailRange(fileSize: Long): String {
        val window = TAIL_BYTES.toLong()
        return when {
            fileSize > window -> "bytes=${fileSize - window}-${fileSize - 1}"
            fileSize > 0L -> "bytes=0-${fileSize - 1}"
            else -> "bytes=-$TAIL_BYTES"
        }
    }

    /** The last [TAIL_BYTES] of [file], or null when it is not a non-empty file. Throws on a read error. */
    fun tail(file: File): ByteArray? {
        if (!file.isFile || file.length() <= 0L) return null
        val size = file.length()
        val start = if (size > TAIL_BYTES) size - TAIL_BYTES else 0L
        return RandomAccessFile(file, "r").use { raf ->
            raf.seek(start)
            val n = (size - start).toInt()
            ByteArray(n).also { raf.readFully(it) }
        }
    }

    /** Every key and value found in [bytes] (a whole file or its tail); the walk stops at [wanted]. */
    fun keys(bytes: ByteArray, wanted: String): Map<String, String> {
        val found = LinkedHashMap<String, String>()
        visit(bytes, 0, bytes.size, 0, wanted, found)
        if (found.containsKey(wanted)) return found
        val moov = findType(bytes, "moov") ?: return found
        visit(bytes, moov.payload, moov.end, 0, wanted, found)
        return found
    }

    private class Box(val type: String, val payload: Int, val end: Int)

    private fun visit(
        data: ByteArray,
        start: Int,
        end: Int,
        depth: Int,
        wanted: String,
        found: MutableMap<String, String>,
    ) {
        if (depth >= 12 || found.containsKey(wanted)) return
        var offset = start
        var names = emptyList<String>()
        while (offset + 8 <= end) {
            val box = nextBox(data, offset, end) ?: break
            when {
                box.type == "keys" -> names = parseKeys(data, box.payload, box.end)
                box.type == "ilst" && box.end - box.payload < 8192 -> {
                    val values = parseIlst(data, box.payload, box.end)
                    for ((index, value) in values) {
                        if (index in 1..names.size) found[names[index - 1]] = value
                    }
                }
                box.type == "moov" || box.type == "udta" ->
                    visit(data, box.payload, box.end, depth + 1, wanted, found)
                box.type == "meta" -> {
                    visit(data, box.payload, box.end, depth + 1, wanted, found)
                    if (!found.containsKey(wanted) && box.payload + 4 < box.end) {
                        visit(data, box.payload + 4, box.end, depth + 1, wanted, found)
                    }
                }
            }
            if (found.containsKey(wanted)) return
            offset = box.end
        }
    }

    private fun findType(data: ByteArray, type: String): Box? {
        val needle = type.encodeToByteArray()
        if (needle.size != 4 || data.size < 8) return null
        var i = 0
        while (i + 8 <= data.size) {
            if (
                data[i + 4] == needle[0] &&
                    data[i + 5] == needle[1] &&
                    data[i + 6] == needle[2] &&
                    data[i + 7] == needle[3]
            ) {
                val box = nextBox(data, i, data.size)
                if (box != null && box.type == type) return box
            }
            i++
        }
        return null
    }

    private fun nextBox(data: ByteArray, offset: Int, limit: Int): Box? {
        if (offset + 8 > limit) return null
        val size32 = u32(data, offset)
        val type = fourCC(data, offset + 4)
        var header = 8
        var size = size32.toLong() and 0xFFFF_FFFFL
        if (size32 == 1) {
            if (offset + 16 > limit) return null
            size = u64(data, offset + 8)
            header = 16
        } else if (size32 == 0) {
            size = (limit - offset).toLong()
        }
        if (size < header || offset + size > limit) return null
        return Box(type, offset + header, offset + size.toInt())
    }

    private fun parseKeys(data: ByteArray, payload: Int, end: Int): List<String> {
        if (payload + 8 > end) return emptyList()
        val count = u32(data, payload + 4)
        if (count !in 1..64) return emptyList()
        var offset = payload + 8
        val names = ArrayList<String>(count)
        repeat(count) {
            if (offset + 8 > end) return names
            val size = u32(data, offset)
            if (size < 8 || offset.toLong() + size > end) return names
            names += String(data, offset + 8, size - 8, Charsets.UTF_8)
            offset += size
        }
        return names
    }

    private fun parseIlst(data: ByteArray, payload: Int, end: Int): Map<Int, String> {
        val values = LinkedHashMap<Int, String>()
        var offset = payload
        while (offset + 8 <= end) {
            val box = nextBox(data, offset, end) ?: break
            val index = u32(data, box.payload - 4)
            var child = box.payload
            while (child + 8 <= box.end) {
                val dataBox = nextBox(data, child, box.end) ?: break
                if (dataBox.type == "data" && dataBox.end - dataBox.payload >= 8) {
                    val start = dataBox.payload + 8
                    var stop = dataBox.end
                    while (stop > start && data[stop - 1] == 0.toByte()) stop--
                    values[index] = String(data, start, stop - start, Charsets.UTF_8)
                    break
                }
                child = dataBox.end
            }
            offset = box.end
        }
        return values
    }

    private fun u32(data: ByteArray, offset: Int): Int =
        ByteBuffer.wrap(data, offset, 4).order(ByteOrder.BIG_ENDIAN).int

    private fun u64(data: ByteArray, offset: Int): Long =
        ByteBuffer.wrap(data, offset, 8).order(ByteOrder.BIG_ENDIAN).long

    private fun fourCC(data: ByteArray, offset: Int): String =
        String(data, offset, 4, Charsets.ISO_8859_1)
}
