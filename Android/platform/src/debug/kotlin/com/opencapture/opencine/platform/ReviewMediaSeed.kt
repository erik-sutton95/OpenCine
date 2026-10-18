package com.opencapture.opencine.platform

import android.graphics.Bitmap
import android.media.MediaMetadataRetriever
import java.io.File
import java.time.LocalDateTime
import java.time.format.DateTimeFormatter
import kotlin.math.roundToInt

/** SIMULATED Debug fixture bytes and observations; callers retain their cache and catalog owners. */
public object ReviewMediaSeed {
    public data class Clip(
        public val ordinal: Int,
        public val filename: String,
        public val captureDate: String,
        public val byteCount: Long,
        public val durationSeconds: Int,
        public val width: Int,
        public val height: Int,
        public val frameRate: Int?,
    )

    /** Typed host addresses; this helper never chooses an app namespace or grants source admission. */
    public data class Destination(public val original: File, public val thumbnail: File? = null)

    /** Blocking fixture IO; call off the main thread, before presenting the real gallery. */
    public fun write(workDirectory: File, count: Int, destination: (Clip) -> Destination): List<Clip> {
        require(count > 0)
        workDirectory.mkdirs()
        val prototype = File.createTempFile("fixture-", ".mp4", workDirectory)
        try {
            ReviewClip.write(prototype)
            val reader = MediaMetadataRetriever()
            try {
                reader.setDataSource(prototype.path)
                val width = requireNotNull(reader.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)?.toIntOrNull())
                val height = requireNotNull(reader.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)?.toIntOrNull())
                val duration = requireNotNull(reader.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toDoubleOrNull())
                val frameRate = reader.extractMetadata(MediaMetadataRetriever.METADATA_KEY_CAPTURE_FRAMERATE)?.toDoubleOrNull()?.roundToInt()
                val origin = LocalDateTime.of(2026, 10, 13, 12, 0)
                val filenameClock = DateTimeFormatter.ofPattern("yyyyMMdd_HHmmss")
                val captureClock = DateTimeFormatter.ofPattern("yyyyMMdd'T'HHmmss")
                val thumbnail = reader.getFrameAtTime(0)
                try {
                    return List(count) { offset ->
                        // Independent recordings have separate capture times, outside a continuous series.
                        val stamp = origin.plusMinutes(offset.toLong())
                        val clip = Clip(offset + 1, "SIMULATED_${stamp.format(filenameClock)}_00.MP4",
                            stamp.format(captureClock), prototype.length(), (duration / 1_000).roundToInt(), width, height, frameRate)
                        val target = destination(clip)
                        target.original.parentFile?.mkdirs()
                        prototype.copyTo(target.original, overwrite = true)
                        target.thumbnail?.let { file ->
                            thumbnail?.let { bitmap ->
                                file.parentFile?.mkdirs()
                                file.outputStream().use { stream -> check(bitmap.compress(Bitmap.CompressFormat.JPEG, 85, stream)) }
                            }
                        }
                        clip
                    }
                } finally { thumbnail?.recycle() }
            } finally { reader.release() }
        } finally { prototype.delete() }
    }
}
