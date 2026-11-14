package com.opencapture.opencine.core

import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse

/** The Multiview seams' shared behavior. Swift twin: `MultiviewSeamTests`. */
class MultiviewSeamTest {
    @Test
    fun aCommissionerThatCannotScanSaysSoWithoutCancelling() = runTest {
        val commissioner = MenuOnlyCommissioner()
        assertFalse(commissioner.scansNetworks)
        assertFailsWith<StationScanUnsupported> {
            commissioner.scanNetworks("camera", beforeStationChange = {}, onRestored = {}, onFound = {})
        }
    }

    /** A commissioner with no network scan of its own. */
    private class MenuOnlyCommissioner : StationCommissioner<String> {
        override fun record(camera: String) = StationCameraRecord(camera, camera, null)

        override suspend fun connect(camera: String, progress: (String) -> Unit): StationCommission =
            throw StationScanUnsupported()

        override fun closeCommissions() {}

        override suspend fun restoreAccessPoint(record: StationCameraRecord): StationRestoreResult = StationRestoreResult.Failed
    }
}
