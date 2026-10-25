package com.opencapture.opencine.dji

import com.opencapture.opencine.core.StorageStatus
import com.opencapture.opencine.media.StorageReadoutCycle
import com.opencapture.opencine.vocabulary.CameraStatus
import kotlin.test.Test
import kotlin.test.assertEquals

class DjiStorageStatusTest {
    /**
     * Hardware pass 7.5 and 8.4: the shared storage cycle reads the DJI wire storage as every app
     * does: whole-unit free space, percentage, then the camera's own remaining time. Swift twin:
     * `DJICameraSessionAdapterPortTests.storageReadsTheSharedStorageCycle`.
     */
    @Test
    fun storageReadsTheSharedStorageCycle() {
        val status = CameraStatus(storageTotalMb = 128_000, storageFreeMb = 109_568, recordRemainingSec = 3_000)
        assertEquals(listOf("115GB", "86%", "50 Min"), storageCycle(djiStorageStatus(status), photo = false))
        assertEquals(listOf("115GB", "86%"), storageCycle(djiStorageStatus(status), photo = true))
        assertEquals(listOf("115GB", "86%"),
            storageCycle(djiStorageStatus(status.copy(recordRemainingSec = 0)), photo = false))
    }

    private fun storageCycle(storage: StorageStatus, photo: Boolean) =
        StorageReadoutCycle.forms(storage, photo)
}
