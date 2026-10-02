package com.opencapture.opencine.media

/**
 * Prefer a silicon HEVC/AVC decoder. `createDecoderByType` can still pick `c2.android.*`.
 * The `MediaCodecList` walk lives in the app (`LiveHevcCodec.createDecoder`).
 */
object LiveHevcCodec {
    fun isSoftwareName(name: String): Boolean {
        val n = name.lowercase()
        return n.contains("omx.google.") ||
            n.contains("c2.android.") ||
            n.contains(".google.") ||
            n.contains("swdecoder") ||
            n.endsWith(".sw")
    }
}
