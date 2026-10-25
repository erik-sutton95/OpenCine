package com.opencapture.opencine.dji

import com.opencapture.opencine.core.ObservationOrigin
import com.opencapture.opencine.core.ObservedValue
import com.opencapture.opencine.core.StorageStatus
import com.opencapture.opencine.core.StorageVolume
import com.opencapture.opencine.vocabulary.CameraStatus
import com.opencapture.opencine.vocabulary.storageReadout
import kotlin.time.Duration.Companion.seconds

/**
 * The DJI wire status as the common storage observation: the selected volume's exact bytes and
 * capacity, and the camera's own remaining recording time. Unknown when neither reports. Swift
 * twin: `DJICameraSessionAdapter.storage(_:)`.
 */
internal fun djiStorageStatus(status: CameraStatus): StorageStatus {
    val storage = status.storageReadout
    if (storage == null && status.recordRemainingSec <= 0) return ObservedValue.unknown
    return ObservedValue(listOf(StorageVolume(
        "active",
        freeBytes = storage?.let { ObservedValue(it.freeBytes, ObservationOrigin.CAMERA_REPORTED, null) } ?: ObservedValue.unknown,
        totalBytes = storage?.totalBytes?.let { ObservedValue(it, ObservationOrigin.CAMERA_REPORTED, null) } ?: ObservedValue.unknown,
        remainingRecordingTime = status.recordRemainingSec.takeIf { it > 0 }?.let {
            ObservedValue(it.seconds, ObservationOrigin.CAMERA_REPORTED, null)
        } ?: ObservedValue.unknown,
    )), ObservationOrigin.CAMERA_REPORTED, null)
}
