package com.opencapture.opencine.nikon

/** Grouping facts from this integration's existing movie token; the original token remains authority. */
data class NikonRecordingFormatPresentation(
    val token: String,
    val imageArea: String?,
    val resolution: String?,
    val frameRate: String?,
) {
    companion object {
        // Mirrors MonitorTextFormat's integer-width/marketing class plus integer p-rate output.
        // Unknown tokens stay unclassified and are never discarded or rewritten.
        private val formatted = Regex("^(?:\\[(FX|DX)\\] )?(8K|6K|4K|[0-9]+) · ([0-9]+p)$")
        fun fromToken(token: String): NikonRecordingFormatPresentation {
            val match = formatted.matchEntire(token)
                ?: return NikonRecordingFormatPresentation(token, null, null, null)
            val size = match.groupValues[2]
            val rate = match.groupValues[3].removeSuffix("p").toIntOrNull()
            if (rate == null || rate !in 1..240 || (size !in setOf("8K", "6K", "4K") && (size.toIntOrNull()?.let { it in 640..8192 } != true))) {
                return NikonRecordingFormatPresentation(token, null, null, null)
            }
            return NikonRecordingFormatPresentation(token,
                match.groupValues[1].takeIf { it.isNotEmpty() }, match.groupValues[2], match.groupValues[3])
        }
    }
}
