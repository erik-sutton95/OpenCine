package com.opencapture.opencine.appkitnative

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import android.util.AtomicFile
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.runtime.staticCompositionLocalOf
import com.opencapture.monitorui.MonitorReferenceMode
import com.opencapture.monitorui.MonitorReferenceSide
import com.opencapture.opencine.runtime.MonitorReferenceFrame
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.File
import kotlin.math.roundToInt
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

/** App-local reference and its session-only comparison controls. */
class MonitorReferenceStore(context: Context) {
    data class Image(val bitmap: Bitmap, val aspect: Float)

    private val file = AtomicFile(File(context.noBackupFilesDir, "monitor-reference.v1"))
    private val lock = Mutex()
    var isLoaded: Boolean by mutableStateOf(false)
        private set
    var reference: Image? by mutableStateOf(null)
        private set
    var shown: Boolean by mutableStateOf(false)
    var mode: MonitorReferenceMode by mutableStateOf(MonitorReferenceMode.BLEND)
    var opacity: Float by mutableStateOf(0.5f)
    var split: Float by mutableStateOf(0.5f)
    var splitSide: MonitorReferenceSide by mutableStateOf(MonitorReferenceSide.LEFT)
    var isBusy: Boolean by mutableStateOf(false)
        private set

    suspend fun load() {
        lock.withLock {
            if (isLoaded) return
            reference = withContext(Dispatchers.IO) {
                runCatching {
                    DataInputStream(file.openRead()).use { input ->
                        val aspect = input.readFloat()
                        if (!aspect.isFinite() || aspect <= 0f) null
                        else BitmapFactory.decodeStream(input)?.let { Image(it, aspect) }
                    }
                }.getOrNull()
            }
            isLoaded = true
        }
    }

    /** Capture first and replace the old file only after a complete JPEG write. */
    suspend fun save(capture: suspend () -> MonitorReferenceFrame?): Boolean {
        if (isBusy) return false
        isBusy = true
        try {
            load()
            val frame = capture() ?: return false
            if (!frame.aspect.isFinite() || frame.aspect <= 0f) return false
            return lock.withLock {
                withContext(NonCancellable) {
                    val image = withContext(Dispatchers.IO) {
                        runCatching {
                            val bitmap = normalized(frame)
                            val output = file.startWrite()
                            try {
                                DataOutputStream(output).writeFloat(frame.aspect)
                                check(bitmap.compress(Bitmap.CompressFormat.JPEG, 92, output))
                                file.finishWrite(output)
                                Image(bitmap, frame.aspect)
                            } catch (error: Exception) {
                                file.failWrite(output)
                                throw error
                            }
                        }.getOrNull()
                    } ?: return@withContext false
                    reference = image
                    true
                }
            }
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Exception) {
            return false
        } finally {
            isBusy = false
        }
    }

    private fun normalized(frame: MonitorReferenceFrame): Bitmap {
        val bitmap = frame.bitmap
        val scale = minOf(1f, 1920f / maxOf(bitmap.width, bitmap.height))
        val upright = if (scale == 1f && frame.rotationDegrees == 0) bitmap else {
            val matrix = Matrix().apply {
                setScale(scale, scale)
                postRotate(frame.rotationDegrees.toFloat())
            }
            Bitmap.createBitmap(bitmap, 0, 0, bitmap.width, bitmap.height, matrix, true)
        }
        // Write square pixels at the admitted display aspect, including an OES pixel ratio,
        // the vertical Vulkan bake's packing, or the operator's desqueeze.
        val longEdge = maxOf(upright.width, upright.height)
        val width = if (frame.aspect >= 1f) longEdge else (longEdge * frame.aspect).roundToInt().coerceAtLeast(1)
        val height = if (frame.aspect < 1f) longEdge else (longEdge / frame.aspect).roundToInt().coerceAtLeast(1)
        return Bitmap.createScaledBitmap(upright, width, height, true)
    }
}

/** A monitor host opts in by providing its local store. */
val LocalMonitorReferenceStore = staticCompositionLocalOf<MonitorReferenceStore?> { null }
