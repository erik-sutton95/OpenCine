package com.opencapture.opencine.gyro

import java.io.File
import java.io.IOException
import java.nio.file.Files
import kotlin.coroutines.EmptyCoroutineContext
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent

/**
 * One coordinator over the test fixtures on virtual time: [FakeGyroNative] (realish),
 * [FakeGyroCameraAdapter], [FakeMotionSensors], in-memory preferences and a temporary log root.
 * [advance] feeds a gyro sample every 10 ms so armed capture never stalls unless a test stops it.
 */
@OptIn(ExperimentalCoroutinesApi::class)
internal class GyroCaptureHarness(
    val test: TestScope,
    val root: File = Files.createTempDirectory("gyro-capture-test").toFile(),
    val prefs: MemorySharedPreferences = MemorySharedPreferences(),
    val native: FakeGyroNative = FakeGyroNative(),
    val sensors: FakeMotionSensors = FakeMotionSensors(),
    val adapter: FakeGyroCameraAdapter = FakeGyroCameraAdapter(),
) {
    val keys = GyroPreferenceKeys.namespaced("gyro.test.")
    val host = GyroHostConfiguration("ExampleApp", root, "gyro-test", keys)

    /** Set true to make every partial-file write throw. */
    var failWrites = false

    val scope = CoroutineScope(
        test.backgroundScope.coroutineContext +
            SupervisorJob(test.backgroundScope.coroutineContext[Job]),
    )

    val coordinator = GyroCaptureCoordinator(
        host = host,
        prefs = prefs,
        native = native,
        sensors = sensors,
        scope = scope,
        now = { test.testScheduler.currentTime / 1000.0 },
        ingress = EmptyCoroutineContext,
        storeFactory = { dir, api ->
            GyroLogStore(dir, api) { file, bytes ->
                if (failWrites) throw IOException("disk full")
                file.write(bytes)
            }
        },
    ).also { test.runCurrent() }

    val state: GyroCaptureState get() = coordinator.state.value

    val nowSeconds: Double get() = test.testScheduler.currentTime / 1000.0

    fun settle() = test.runCurrent()

    /** Advances virtual time, delivering one gyro sample every 10 ms (100 Hz) while the gyro runs. */
    fun advance(millis: Long) {
        var left = millis
        while (left > 0) {
            val step = minOf(10L, left)
            sensors.emitSample(nowSeconds)
            test.advanceTimeBy(step)
            test.runCurrent()
            left -= step
        }
    }

    /** Advances virtual time without any sensor sample. */
    fun advanceSilently(millis: Long) {
        test.advanceTimeBy(millis)
        test.runCurrent()
    }

    /** Toggle on, host eligible, adapter bound and connected with [stabilization]. */
    fun arm(
        stabilization: GyroStabilizationState? = GyroStabilizationState(mapOf("ibis" to "ON"), null),
        recording: Boolean? = false,
        videoMode: Boolean? = true,
    ) {
        coordinator.setEnabled(true)
        coordinator.setHostEligible(true)
        coordinator.bind(adapter)
        settle()
        adapter.connect(stabilization = stabilization, recording = recording, videoMode = videoMode)
        settle()
        advance(200)
    }

    /** Steady phone readings with a fresh camera level, each processed before the next. */
    fun steady(readings: Int, level: GyroVector3? = GyroVector3(-1.0, 0.0, 0.0)) {
        repeat(readings) {
            adapter.emitLevel(level, nowSeconds)
            settle()
            sensors.emitSteady(nowSeconds)
            settle()
            advance(50)
        }
    }

    /** Saves the default calibration for the fake camera, as an earlier session would have. */
    fun saveCalibration() {
        GyroPreferences(prefs, keys, null, native)
            .saveCalibration(adapter.camera.id, FakeGyroNative.DEFAULT_CALIBRATION)
    }

    fun reasons(): List<Any?> = native.calls("loggingFinish").map { it.args[1] }

    fun cleanup() {
        coordinator.close()
        settle()
        root.deleteRecursively()
    }
}

internal val IBIS_OFF = GyroStabilizationState(mapOf("ibis" to "OFF"), null)
internal val IBIS_SPORT = GyroStabilizationState(mapOf("ibis" to "SPORT"), null)
