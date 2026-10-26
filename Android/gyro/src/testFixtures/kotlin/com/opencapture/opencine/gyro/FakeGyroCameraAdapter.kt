package com.opencapture.opencine.gyro

import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

/**
 * A scriptable [GyroCameraAdapter] for coordinator and UI tests (Swift twin:
 * OpenCineCoreTestSupport's FakeGyroCameraAdapter). Every observation is a mutable flow the test
 * sets; writes are recorded and, when accepted, reflected into [stabilization] the way a camera
 * reports the new value back.
 */
class FakeGyroCameraAdapter(
    /** The body [connect] reports. */
    val camera: GyroCameraIdentity = GyroCameraIdentity("fake-1", "Test camera"),
    override val providesLevel: Boolean = true,
    override val stabilizationSettings: List<GyroStabilizationSetting> =
        listOf(GyroStabilizationSetting("ibis", "IBIS", "OFF")),
) : GyroCameraAdapter {
    /** The connected body; null while disconnected. */
    override val identity: MutableStateFlow<GyroCameraIdentity?> = MutableStateFlow(null)

    /** Camera recording; null when unknown. */
    override val recording: MutableStateFlow<Boolean?> = MutableStateFlow(null)

    /** Movie mode; null when unknown. */
    override val videoMode: MutableStateFlow<Boolean?> = MutableStateFlow(null)

    /** Current stabilization values; null when unreported. */
    override val stabilization: MutableStateFlow<GyroStabilizationState?> = MutableStateFlow(null)

    private val levels = MutableSharedFlow<GyroCameraLevel>(extraBufferCapacity = 256)

    /** Level readings sent with [emitLevel]. */
    override val level: Flow<GyroCameraLevel> = levels

    /** Every [writeStabilization] call, in order. */
    val writes: MutableList<Map<String, String>> = java.util.concurrent.CopyOnWriteArrayList()

    /** False makes the camera refuse every write. */
    var acceptsWrites: Boolean = true

    /** Virtual milliseconds each write takes before it answers. */
    var writeDelayMillis: Long = 0

    /** True makes every write hang until it is cancelled, like a camera that never answers. */
    var writeNeverReturns: Boolean = false

    /** Called at the start of every write with its values, before the write answers. */
    var beforeWrite: ((Map<String, String>) -> Unit)? = null

    /** Connects [camera] with these observations in one step. */
    fun connect(
        stabilization: GyroStabilizationState? = GyroStabilizationState(mapOf("ibis" to "ON"), null),
        recording: Boolean? = false,
        videoMode: Boolean? = true,
        identity: GyroCameraIdentity = camera,
    ) {
        this.stabilization.value = stabilization
        this.recording.value = recording
        this.videoMode.value = videoMode
        this.identity.value = identity
    }

    /** Drops the link: no body, unknown observations. */
    fun disconnect() {
        identity.value = null
        recording.value = null
        videoMode.value = null
        stabilization.value = null
    }

    /** Sends one level reading; a null [down] means the camera has no level right now. */
    fun emitLevel(down: GyroVector3?, timestampSeconds: Double) {
        check(levels.tryEmit(GyroCameraLevel(down, timestampSeconds))) { "level buffer full" }
    }

    /** Records the write, waits [writeDelayMillis], then answers [acceptsWrites]. */
    override suspend fun writeStabilization(values: Map<String, String>): Boolean {
        writes += values
        beforeWrite?.invoke(values)
        if (writeNeverReturns) awaitCancellation()
        if (writeDelayMillis > 0) delay(writeDelayMillis)
        if (!acceptsWrites) return false
        val current = stabilization.value
        stabilization.value =
            GyroStabilizationState(
                (current?.values ?: emptyMap()) + values,
                current?.lensHasVRSwitch,
            )
        return true
    }
}
