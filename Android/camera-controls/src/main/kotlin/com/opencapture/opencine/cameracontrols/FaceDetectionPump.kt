package com.opencapture.opencine.cameracontrols

import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import com.opencapture.opencine.media.FaceDetectFlight
import com.opencapture.opencine.vocabulary.FaceStructurePolicy
import com.opencapture.opencine.vocabulary.TrackingBox
import java.util.concurrent.Executor
import java.util.concurrent.Executors

/** One detector input of [width] x [height] pixels; [release] frees it once the backend is done reading it. */
interface FaceDetectionFrame {
    val width: Int
    val height: Int

    fun release()
}

/** A face the backend found, in frame pixels; eye positions are frame x, null when the backend found none. */
data class DetectedFace(
    val left: Int,
    val top: Int,
    val right: Int,
    val bottom: Int,
    val leftEyeX: Float?,
    val rightEyeX: Float?,
    val hasNose: Boolean,
)

/** The detector engine the app supplies (ML Kit on Android, Vision on iOS). */
interface FaceDetectionBackend<F : FaceDetectionFrame> {
    /**
     * Starts reading [frame] and calls [done] on [executor] once it is finished with it: the faces, or null
     * when detection failed. Returns false when it could not start (nothing reads the frame then).
     */
    fun detect(frame: F, executor: Executor, done: (List<DetectedFace>?) -> Unit): Boolean

    /** Frees the engine; called once after the last detection finished. */
    fun close()
}

/**
 * Swift `LiveFaceDetector`'s pump: latest-frame-wins on a 40 ms cadence, 100 ms after about a second
 * without a face (see [pace]). Boxes are camera/identity space; Compose mirrors them at draw time.
 *
 * Frame ownership: a frame handed to the backend is released **only once the backend is done** (ML Kit
 * reads bitmap pixels off-thread; freeing one early aborts the process, #348). A hung detection may
 * unstick Face AF via a watchdog that posts empty boxes and schedules the next frame; the watchdog never
 * releases, only the completion does.
 */
open class FaceDetectionPump<F : FaceDetectionFrame>(private val backend: FaceDetectionBackend<F>) {
    private val lock = Any()
    private val main = Handler(Looper.getMainLooper())
    private val exec = Executors.newSingleThreadExecutor { Thread(it, "opc.face-af") }
    private val flight = FaceDetectFlight()
    private var finished = false
    private var busy = false
    private var closed = false
    private var lastRun = 0L
    private var emptyRuns = 0
    private var pending: F? = null
    private var pendingDone: ((List<TrackingBox>) -> Unit)? = null

    /** Whether a frame offered now would be detected; skip the readback otherwise. */
    fun wantsFrame(): Boolean =
        synchronized(lock) {
            !closed && wantsFrame(emptyRuns, SystemClock.elapsedRealtime() - lastRun)
        }

    fun consider(src: F, done: (List<TrackingBox>) -> Unit) {
        synchronized(lock) {
            if (closed) {
                src.release()
                return
            }
            pending?.release()
            pending = src
            pendingDone = done
            if (!busy) {
                busy = true
                exec.execute { pump() }
            }
        }
    }

    fun shutdown() {
        main.removeCallbacksAndMessages(null)
        val abandoned: F?
        val stopNow: Boolean
        synchronized(lock) {
            closed = true
            flight.invalidate()
            abandoned = pending
            pending = null
            pendingDone = null
            stopNow = !busy
        }
        abandoned?.release()
        // With no detection in flight nothing else owns pixels, so tear down now.
        // Otherwise the in-flight completion finishes the shutdown, because the
        // backend may still be reading that frame.
        if (stopNow) finishShutdown()
    }

    private fun pump() {
        val frame: F?
        val done: ((List<TrackingBox>) -> Unit)?
        val abortClosed: Boolean
        synchronized(lock) {
            val next = pending
            val cb = pendingDone
            pending = null
            pendingDone = null
            if (closed) {
                busy = false
                next?.release()
                abortClosed = true
                frame = null
                done = null
            } else if (next == null || cb == null) {
                busy = false
                next?.release()
                abortClosed = false
                frame = null
                done = null
            } else {
                lastRun = SystemClock.elapsedRealtime()
                abortClosed = false
                frame = next
                done = cb
            }
        }
        if (abortClosed) {
            finishShutdown()
            return
        }
        if (frame == null || done == null) return
        val width = frame.width
        val height = frame.height
        if (width < 16 || height < 16) {
            frame.release()
            main.post { done(emptyList()) }
            scheduleNext()
            return
        }
        val flightId =
            synchronized(lock) {
                if (closed) -1 else flight.begin()
            }
        val timeout =
            Runnable {
                val timedOut = synchronized(lock) { !closed && flightId >= 0 && flight.take(flightId) }
                if (!timedOut) return@Runnable
                // Unstick Face AF only. The backend may still be reading [frame].
                main.post { done(emptyList()) }
                scheduleNext()
            }
        val started =
            runCatching {
                backend.detect(frame, exec) { faces ->
                    main.removeCallbacks(timeout)
                    frame.release()
                    complete(flightId, faces, width, height, done)
                }
            }.getOrDefault(false)
        if (!started) {
            synchronized(lock) { if (flightId >= 0) flight.take(flightId) }
            frame.release()
            main.post { done(emptyList()) }
            scheduleNext()
            return
        }
        if (flightId >= 0) main.postDelayed(timeout, DETECT_TIMEOUT_MS)
    }

    private fun complete(flightId: Int, faces: List<DetectedFace>?, width: Int, height: Int, done: (List<TrackingBox>) -> Unit) {
        val deliver: Boolean
        val stop: Boolean
        synchronized(lock) {
            if (closed) {
                busy = false
                deliver = false
                stop = true
            } else if (flightId < 0 || !flight.take(flightId)) {
                deliver = false
                stop = false
            } else {
                deliver = true
                stop = false
            }
        }
        if (stop) {
            finishShutdown()
            return
        }
        if (!deliver) return
        val hits = faces?.let { project(it, width, height) } ?: emptyList()
        synchronized(lock) { emptyRuns = if (hits.isEmpty()) emptyRuns + 1 else 0 }
        main.post { done(hits) }
        scheduleNext()
    }

    private fun scheduleNext() {
        val delay = synchronized(lock) { pace(emptyRuns) } - (SystemClock.elapsedRealtime() - lastRun)
        val stop: Boolean
        synchronized(lock) {
            if (closed) {
                busy = false
                stop = true
            } else {
                stop = false
                exec.execute {
                    if (delay > 0) runCatching { Thread.sleep(delay) }
                    pump()
                }
            }
        }
        if (stop) finishShutdown()
    }

    private fun finishShutdown() {
        synchronized(lock) {
            if (finished) return
            finished = true
        }
        runCatching { backend.close() }
        exec.shutdown()
    }

    companion object {
        const val INTERVAL_MS = 40L

        /** No face for about a second: look at 10 Hz until one appears (iOS parity). */
        const val IDLE_INTERVAL_MS = 100L
        const val IDLE_AFTER_EMPTY_RUNS = 25
        const val DETECT_TIMEOUT_MS = 2_000L

        fun pace(emptyRuns: Int): Long = if (emptyRuns >= IDLE_AFTER_EMPTY_RUNS) IDLE_INTERVAL_MS else INTERVAL_MS

        /**
         * Tracking takes every frame (latest wins while busy). Idle takes one within
         * a feed tick of its next run, so the pump skips readbacks that would be dropped.
         */
        fun wantsFrame(emptyRuns: Int, sinceLastRunMs: Long): Boolean =
            sinceLastRunMs >= pace(emptyRuns) - INTERVAL_MS

        /** Faces with eye and nose structure as tracking boxes; tiny boxes are dropped. */
        fun project(faces: List<DetectedFace>, width: Int, height: Int): List<TrackingBox> {
            val hits = ArrayList<TrackingBox>(faces.size)
            for (face in faces) {
                val w = face.right - face.left
                val h = face.bottom - face.top
                if (w < 8 || h < 8) continue
                if (
                    !FaceStructurePolicy.hasFaceLandmarks(
                        leftEyeX = relativeX(face.leftEyeX, face.left, w),
                        rightEyeX = relativeX(face.rightEyeX, face.left, w),
                        hasNose = face.hasNose,
                    )
                ) {
                    continue
                }
                val box = TrackingBox.fromImageRect(face.left, face.top, face.right, face.bottom, width, height) ?: continue
                if (box.isTooSmall) continue
                hits.add(box)
            }
            return hits
        }

        private fun relativeX(x: Float?, left: Int, width: Int): Double? {
            val bw = width.toDouble()
            if (bw < 1.0) return null
            return ((x ?: return null) - left) / bw
        }
    }
}
