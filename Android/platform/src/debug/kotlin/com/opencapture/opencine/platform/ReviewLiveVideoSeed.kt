package com.opencapture.opencine.platform

import android.content.Context
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.flowOn

/** Procedural SIMULATED moving picture, Debug only; no camera, network or decoder ownership. */
public object ReviewLiveVideoSeed {
    private const val ASSET = "SIMULATED-live-640x360-24.h264"
    private const val FPS = 24
    private const val FRAME_COUNT = 48
    private const val MAX_BYTES = 2 * 1024 * 1024

    /**
     * Cold, backpressured Annex-B input for the existing decoder. Its collector owns cancellation;
     * there is no detached producer, synthetic picture callback or presentation-state assignment.
     * The two-second baseline H264 pattern has AUDs and repeated SPS/PPS at each one-second IDR.
     */
    public fun frames(context: Context): Flow<ByteArray> = flow {
        val bytes = context.assets.open(ASSET).use { it.readBytes() }
        require(bytes.size in 1..MAX_BYTES) { "SIMULATED live fixture exceeds its encoded bound" }
        val boundaries = mutableListOf<Int>()
        var offset = 0
        while (offset + 3 < bytes.size) {
            val prefix = when {
                bytes[offset] == 0.toByte() && bytes[offset + 1] == 0.toByte() &&
                    bytes[offset + 2] == 1.toByte() -> 3
                offset + 4 < bytes.size && bytes[offset] == 0.toByte() &&
                    bytes[offset + 1] == 0.toByte() && bytes[offset + 2] == 0.toByte() &&
                    bytes[offset + 3] == 1.toByte() -> 4
                else -> 0
            }
            if (prefix > 0) {
                if (bytes[offset + prefix].toInt() and 0x1f == 9) boundaries += offset
                offset += prefix + 1
            } else {
                offset += 1
            }
        }
        require(boundaries.size == FRAME_COUNT && boundaries.first() == 0) {
            "SIMULATED live fixture requires exactly 48 AUD-delimited access units"
        }
        val accessUnits = boundaries.mapIndexed { index, start ->
            bytes.copyOfRange(start, boundaries.getOrElse(index + 1) { bytes.size })
        }
        while (true) {
            val began = System.nanoTime()
            for ((index, unit) in accessUnits.withIndex()) {
                currentCoroutineContext().ensureActive()
                emit(unit)
                val remaining = began + (index + 1L) * 1_000_000_000L / FPS - System.nanoTime()
                if (remaining > 0) delay((remaining + 999_999L) / 1_000_000L)
            }
        }
    }.flowOn(Dispatchers.Default)
}
