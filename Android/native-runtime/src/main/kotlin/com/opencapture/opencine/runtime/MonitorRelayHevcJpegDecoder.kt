package com.opencapture.opencine.runtime

import android.graphics.ImageFormat
import android.graphics.Rect
import android.graphics.YuvImage
import android.media.MediaCodec
import android.media.MediaFormat
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.util.UUID

/** Actual source codec facts. No wire schema, relay policy or camera vocabulary enters this leaf. */
public data class MonitorHevcJpegDecodePolicy(
    public val width: Int = 1920,
    public val height: Int = 1080,
    public val inputTimeoutMicros: Long = 20_000L,
    public val firstDrainTimeoutMicros: Long = 12_000L,
    public val frameStepMicros: Long = 40_000L,
    public val softwareFallbackFedFrames: Int = 75,
    public val maximumConsecutiveSoftwareRebuilds: Int = 3,
    public val softwareDecoderName: String = "c2.android.hevc.decoder",
    public val jpegQuality: Int = 88,
) {
    init {
        require(width > 0 && height > 0 && inputTimeoutMicros >= 0 && firstDrainTimeoutMicros >= 0)
        require(frameStepMicros > 0 && softwareFallbackFedFrames >= 0)
        require(maximumConsecutiveSoftwareRebuilds > 0 && jpegQuality in 0..100)
    }
}

/** The owned SDK image. JPEG conversion remains below UI; close always releases its native image. */
public interface MonitorHevcJpegOutput {
    public fun jpeg(quality: Int): ByteArray?
    public fun close(): Unit
}

/** Small native port, including nullable input/image behavior and the actual format-change code. */
public interface MonitorHevcJpegCodec {
    public val name: String
    public fun dequeueInputBuffer(timeoutMicros: Long): Int
    public fun inputBuffer(index: Int): ByteBuffer?
    public fun queueInputBuffer(index: Int, byteCount: Int, presentationMicros: Long): Unit
    /** Nonnegative is an output buffer; -2 is a format change; other negative values end a drain. */
    public fun dequeueOutputBuffer(timeoutMicros: Long): Int
    public fun outputImage(index: Int): MonitorHevcJpegOutput?
    public fun releaseOutputBuffer(index: Int): Unit
    public fun stop(): Unit
    public fun release(): Unit
}

public fun interface MonitorHevcJpegCodecFactory {
    public fun create(software: Boolean, policy: MonitorHevcJpegDecodePolicy): MonitorHevcJpegCodec
}

public enum class MonitorHevcDecodeLogLevel { INFO, WARNING }

/**
 * Original synchronous native HEVC-to-JPEG monitor owner. Feed and drain are independent,
 * parameter sets ride in-band, output is newest-only and fallback retains its deployed bounds.
 * Capture sourceToken before queuing work. Release retires queued work and keeps fallback facts;
 * close is terminal. A retired native completion cannot publish into a successor source.
 */
public class MonitorRelayHevcJpegDecoder(
    private val policy: MonitorHevcJpegDecodePolicy = MonitorHevcJpegDecodePolicy(),
    private val factory: MonitorHevcJpegCodecFactory = FrameworkHevcJpegCodecFactory,
    private val log: (MonitorHevcDecodeLogLevel, String, Throwable?) -> Unit = { level, text, error ->
        if (level == MonitorHevcDecodeLogLevel.INFO) android.util.Log.i("RelayHEVC", text)
        else android.util.Log.w("RelayHEVC", text, error)
    },
) {
    private val sourceLock: Any = Any()
    private val nativeLock: Any = Any()
    private var source: UUID = UUID.randomUUID()
    private var closed: Boolean = false
    public val sourceToken: UUID get() = synchronized(sourceLock) { source }
    private fun admits(token: UUID): Boolean = synchronized(sourceLock) { !closed && token == source }

    private var codec: MonitorHevcJpegCodec? = null
    private var codecSource: UUID? = null
    private var configuredCsd: ByteArray? = null
    private var awaitingKeyframe: Boolean = false
    private var presentationMicros: Long = 0L
    private var submitted: Int = 0
    private var fed: Int = 0
    private var fedSinceOutput: Int = 0
    private var usingSoftwareDecoder: Boolean = false
    private var decoded: Int = 0
    private var consecutiveRebuilds: Int = 0
    private var inBandParameterSets: ByteArray? = null
    private var disabledForCsd: ByteArray? = null
    public val isPausedForStream: Boolean get() = synchronized(nativeLock) { disabledForCsd != null }

    public fun decodeToJpeg(
        frame: ByteArray,
        isKeyframe: Boolean,
        parameterSets: List<ByteArray>?,
        source: UUID = sourceToken,
    ): ByteArray? = synchronized(nativeLock) {
        if (!admits(source)) return@synchronized null
        val csd = parameterSets?.takeIf(List<ByteArray>::isNotEmpty)?.let(MonitorHevcJpegBytes::annexBParameterSets)
        val active = try { ensureCodec(csd, source) } catch (_: Exception) { null }
            ?: return@synchronized null
        if (!admits(source)) return@synchronized null
        if (awaitingKeyframe) {
            if (!isKeyframe) return@synchronized null
            awaitingKeyframe = false
        }
        try {
            val inBand = inBandParameterSets
            val annexB = if (isKeyframe && inBand != null) inBand + MonitorHevcJpegBytes.annexBFrame(frame)
                else MonitorHevcJpegBytes.annexBFrame(frame)
            val inputIndex = active.dequeueInputBuffer(policy.inputTimeoutMicros)
            if (!admits(source)) return@synchronized null
            if (inputIndex >= 0) {
                fed += 1
                val buffer = active.inputBuffer(inputIndex)
                if (!admits(source)) return@synchronized null
                if (buffer != null) {
                    buffer.clear()
                    buffer.put(annexB)
                    presentationMicros += policy.frameStepMicros
                    active.queueInputBuffer(inputIndex, annexB.size, presentationMicros)
                    if (!admits(source)) return@synchronized null
                }
            }
            var jpeg = drainNewestJpeg(active, source)
            if (!admits(source)) return@synchronized null
            submitted += 1
            if (jpeg != null) {
                decoded += 1
                fedSinceOutput = 0
                consecutiveRebuilds = 0
            } else {
                fedSinceOutput += 1
                if (!usingSoftwareDecoder && fedSinceOutput > policy.softwareFallbackFedFrames) {
                    log(MonitorHevcDecodeLogLevel.WARNING,
                        "no output after $fedSinceOutput frames; switching to software decoder", null)
                    if (!admits(source)) return@synchronized null
                    usingSoftwareDecoder = true
                    releaseNative()
                    fedSinceOutput = 0
                    jpeg = null
                }
            }
            if (submitted % 50 == 1) {
                val head = frame.take(8).joinToString(" ") { String.format("%02X", it) }
                log(MonitorHevcDecodeLogLevel.INFO,
                    "submitted=$submitted decoded=$decoded fed=$fed key=$isKeyframe " +
                        "bytes=${frame.size} head=[$head]", null)
            }
            if (admits(source)) jpeg else null
        } catch (error: Exception) {
            if (!admits(source)) return@synchronized null
            consecutiveRebuilds += 1
            if (usingSoftwareDecoder && consecutiveRebuilds >= policy.maximumConsecutiveSoftwareRebuilds) {
                log(MonitorHevcDecodeLogLevel.WARNING,
                    "decode failed $consecutiveRebuilds times on the software decoder; " +
                        "pausing until the stream's parameters change", error)
                if (!admits(source)) return@synchronized null
                disabledForCsd = configuredCsd
            } else {
                log(MonitorHevcDecodeLogLevel.WARNING, "decode failed; rebuilding on next keyframe", error)
                if (!admits(source)) return@synchronized null
            }
            releaseNative()
            null
        }
    }

    private fun ensureCodec(csd: ByteArray?, source: UUID): MonitorHevcJpegCodec? {
        val current = codec
        if (current != null && codecSource == source && (csd == null || csd.contentEquals(configuredCsd))) return current
        val disabled = disabledForCsd
        if (disabled != null) {
            if (csd == null || csd.contentEquals(disabled)) return null
            disabledForCsd = null
            consecutiveRebuilds = 0
        }
        releaseNative()
        val newCsd = csd ?: return null
        val created = factory.create(usingSoftwareDecoder, policy)
        if (!admits(source)) {
            runCatching { created.stop(); created.release() }
            return null
        }
        codec = created
        codecSource = source
        configuredCsd = newCsd
        inBandParameterSets = newCsd
        awaitingKeyframe = true
        log(MonitorHevcDecodeLogLevel.INFO,
            "decoder configured (${created.name}, csd ${newCsd.size} bytes)", null)
        return if (admits(source)) created else null
    }

    private fun drainNewestJpeg(active: MonitorHevcJpegCodec, source: UUID): ByteArray? {
        var newest = -1
        var timeout = policy.firstDrainTimeoutMicros
        try {
            while (admits(source)) {
                val index = active.dequeueOutputBuffer(timeout)
                timeout = 0
                when {
                    index == -2 -> continue
                    index >= 0 -> {
                        if (newest >= 0) active.releaseOutputBuffer(newest)
                        newest = index
                    }
                    else -> break
                }
            }
            if (newest < 0 || !admits(source)) return null
            val image = active.outputImage(newest) ?: return null
            try { return image.jpeg(policy.jpegQuality).takeIf { admits(source) } }
            finally { image.close() }
        } finally { if (newest >= 0) active.releaseOutputBuffer(newest) }
    }

    /** Compatibility reset: retain original PTS, in-band values, counters and software verdict. */
    public fun release(): Unit {
        val retired = synchronized(sourceLock) { val old = source; source = UUID.randomUUID(); old }
        // A queued retirement cannot release a codec already created for the successor token.
        synchronized(nativeLock) { if (codecSource == retired) releaseNative() }
    }
    /** A producer supplies its captured source identity before queuing native input. */
    public fun beginSource(token: UUID): Boolean {
        val retired = synchronized(sourceLock) {
            if (closed) return false
            val old = source
            source = token
            old
        }
        synchronized(nativeLock) { if (codecSource == retired) releaseNative() }
        return admits(token)
    }
    /** Closing an old peer must not reset the picture belonging to a replacement peer. */
    public fun retireSource(token: UUID): Boolean {
        synchronized(sourceLock) {
            if (closed || token != source) return false
            source = UUID.randomUUID()
        }
        synchronized(nativeLock) { if (codecSource == token) releaseNative() }
        return true
    }
    public fun close(): Unit {
        synchronized(sourceLock) { closed = true; source = UUID.randomUUID() }
        synchronized(nativeLock) { releaseNative() }
    }
    private fun releaseNative(): Unit {
        runCatching { codec?.stop(); codec?.release() }
        codec = null
        codecSource = null
        configuredCsd = null
    }
}

/** Borrowed native plane bytes; valid only while their owned image remains open. */
public data class MonitorHevcYuvPlane(public val bytes: ByteBuffer, public val rowStride: Int, public val pixelStride: Int)

/** Exact original AVCC/start-code and 8-bit/P010 conversion; no integration wire helper. */
public object MonitorHevcJpegBytes {
    private val startCode: ByteArray = byteArrayOf(0, 0, 0, 1)
    public fun annexBParameterSets(sets: List<ByteArray>): ByteArray = ByteArrayOutputStream().use { out ->
        sets.forEach { out.write(startCode); out.write(it) }
        out.toByteArray()
    }
    public fun annexBFrame(frame: ByteArray): ByteArray = ByteArrayOutputStream(frame.size + 16).use { out ->
        var offset = 0
        while (offset + 4 <= frame.size) {
            val length = ((frame[offset].toInt() and 0xFF) shl 24) or
                ((frame[offset + 1].toInt() and 0xFF) shl 16) or
                ((frame[offset + 2].toInt() and 0xFF) shl 8) or (frame[offset + 3].toInt() and 0xFF)
            offset += 4
            if (length <= 0 || offset + length > frame.size) break
            out.write(startCode)
            out.write(frame, offset, length)
            offset += length
        }
        out.toByteArray()
    }
    public fun yuv420ToNv21(width: Int, height: Int, y: MonitorHevcYuvPlane,
        u: MonitorHevcYuvPlane, v: MonitorHevcYuvPlane): ByteArray {
        val out = ByteArray(width * height * 3 / 2)
        val yWide = y.pixelStride >= 2
        val yHigh = if (yWide) 1 else 0
        var position = 0
        for (row in 0 until height) {
            val base = row * y.rowStride
            for (column in 0 until width) out[position++] = y.bytes.get(base + column * y.pixelStride + yHigh)
        }
        val cHigh = if (u.pixelStride >= 2 && v.pixelStride >= 2 && yWide) 1 else 0
        for (row in 0 until height / 2) {
            val uBase = row * u.rowStride
            val vBase = row * v.rowStride
            for (column in 0 until width / 2) {
                out[position++] = v.bytes.get(vBase + column * v.pixelStride + cHigh)
                out[position++] = u.bytes.get(uBase + column * u.pixelStride + cHigh)
            }
        }
        return out
    }
}

/** Framework construction is fully provided; generated or consuming apps need no SDK factory. */
private object FrameworkHevcJpegCodecFactory : MonitorHevcJpegCodecFactory {
    override fun create(software: Boolean, policy: MonitorHevcJpegDecodePolicy): MonitorHevcJpegCodec {
        val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_HEVC, policy.width, policy.height)
        // No csd-0 or forced color format: the original Main10 path supplies in-band parameters.
        val native = if (software) MediaCodec.createByCodecName(policy.softwareDecoderName)
            else MediaCodec.createDecoderByType(MediaFormat.MIMETYPE_VIDEO_HEVC)
        try { native.configure(format, null, null, 0); native.start() }
        catch (error: Exception) { runCatching { native.release() }; throw error }
        return FrameworkHevcJpegCodec(native)
    }
}

private class FrameworkHevcJpegCodec(private val native: MediaCodec) : MonitorHevcJpegCodec {
    private val info: MediaCodec.BufferInfo = MediaCodec.BufferInfo()
    override val name: String get() = native.name
    override fun dequeueInputBuffer(timeoutMicros: Long): Int = native.dequeueInputBuffer(timeoutMicros)
    override fun inputBuffer(index: Int): ByteBuffer? = native.getInputBuffer(index)
    override fun queueInputBuffer(index: Int, byteCount: Int, presentationMicros: Long): Unit {
        native.queueInputBuffer(index, 0, byteCount, presentationMicros, 0)
    }
    override fun dequeueOutputBuffer(timeoutMicros: Long): Int = native.dequeueOutputBuffer(info, timeoutMicros)
    override fun outputImage(index: Int): MonitorHevcJpegOutput? = native.getOutputImage(index)?.let { image ->
        object : MonitorHevcJpegOutput {
            override fun jpeg(quality: Int): ByteArray {
                val planes = image.planes.map { MonitorHevcYuvPlane(it.buffer, it.rowStride, it.pixelStride) }
                val nv21 = MonitorHevcJpegBytes.yuv420ToNv21(image.width, image.height, planes[0], planes[1], planes[2])
                return ByteArrayOutputStream().use { output ->
                    YuvImage(nv21, ImageFormat.NV21, image.width, image.height, null)
                        .compressToJpeg(Rect(0, 0, image.width, image.height), quality, output)
                    output.toByteArray()
                }
            }
            override fun close(): Unit = image.close()
        }
    }
    override fun releaseOutputBuffer(index: Int): Unit = native.releaseOutputBuffer(index, false)
    override fun stop(): Unit = native.stop()
    override fun release(): Unit = native.release()
}
