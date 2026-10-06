package com.opencapture.opencine.vocabulary

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class MediaModelsTest {
    @Test fun timestampsReadBothFilenameForms() {
        assertEquals("20260814125250", MediaFile("/DCIM/DJI_20260814125250_0034_D.MP4", "").filenameTimestamp)
        assertEquals("20260916123456", MediaFile("/DCIM/VID_20260916_123456_00_001.mp4", "").filenameTimestamp)
        assertEquals("20260916", MediaFile("/DCIM/VID_20260916_123456_00_001.mp4", "").dateKey)
        assertNull(MediaFile("/DCIM/IMG_0001.JPG", "").filenameTimestamp)
    }

    @Test fun routesAddressByStoreOrByPath() {
        assertEquals("http://192.168.2.1/v2?storage=1&path=/a.MP4", MediaRoute.CAMERA_SOFT_AP.pathUrlString(1, "/a.MP4"))
        assertEquals(MediaHTTP.pathUrlString(1, "/a.MP4"), MediaRoute.CAMERA_SOFT_AP.pathUrlString(1, "/a.MP4"))
        assertEquals("http://10.0.0.1/DCIM/a.mp4", MediaRoute("10.0.0.1", directPath = true).pathUrlString(0, "DCIM/a.mp4"))
    }

    @Test fun idsQualifyTheStore() {
        assertEquals("1:/a.MP4", MediaFile("/a.MP4", "", handle = 0x40000005L).id)
        assertEquals("0:/a.MP4", MediaFile("/a.MP4", "", handle = 5L).id)
        assertEquals("1:/a.MP4", MediaFile("/a.MP4", "", handle = 5L, storage = 1, storageKnown = true).id)
    }
}
