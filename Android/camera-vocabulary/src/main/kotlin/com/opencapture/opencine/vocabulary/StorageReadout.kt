package com.opencapture.opencine.vocabulary

public typealias StorageReadout = com.opencapture.opencine.media.StorageReadout

/**
 * The one volume-selection rule for the DJI-wire status, whose storage fields are MiB (as DJI
 * reports them and the Luna mapping publishes them): the aggregate store when it reports, else the
 * SD card; null when neither reports anything.
 */
val CameraStatus.storageReadout: StorageReadout?
    get() {
        val aggregate = storageTotalMb > 0 || storageFreeMb > 0
        val free = if (aggregate) storageFreeMb else sdFreeMb
        val total = if (aggregate) storageTotalMb else sdTotalMb
        if (free < 0 || (free == 0 && total <= 0) || (total > 0 && free > total)) return null
        return StorageReadout(free.coerceAtLeast(0) * MIB, if (total > 0) total * MIB else null)
    }

private const val MIB = 1_048_576L
