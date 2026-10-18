package com.opencapture.opencine.cameracontrols

import com.opencapture.opencine.vocabulary.MediaFile
import java.io.File
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

/** The gallery cell asks the cache first, then the source, then the camera; nothing is decoded here. */
class MonitorMediaThumbnailsTest {
    private class Source(private val bytes: ByteArray? = null) : MonitorMediaThumbnailSource {
        val calls = mutableListOf<String>()
        override fun thumbnailFile(file: MediaFile): File? { calls += "thumbnailFile"; return null }
        override fun localFile(file: MediaFile): File? { calls += "localFile"; return null }
        override fun isDownloaded(file: MediaFile): Boolean { calls += "isDownloaded"; return false }
        override suspend fun ensureThumbnail(file: MediaFile) { calls += "ensureThumbnail" }
        override suspend fun cameraThumbnailBytes(file: MediaFile): ByteArray? { calls += "camera"; return bytes }
    }

    private val clip = MediaFile(path = "/DCIM/CLIP0001.MP4", thumbPath = "/DCIM/CLIP0001.JPG")

    @Test
    fun cacheThenSourceThenCameraWhenNothingIsCached() = runTest {
        val source = Source()
        assertNull(MonitorMediaThumbnails.load(clip, source, maxPx = 64))
        assertEquals(listOf("thumbnailFile", "ensureThumbnail", "thumbnailFile", "camera", "isDownloaded"), source.calls)
    }

    @Test
    fun aSourceWithoutCameraThumbnailsSkipsTheCameraRead() = runTest {
        val source = object : MonitorMediaThumbnailSource {
            override fun thumbnailFile(file: MediaFile): File? = null
            override fun localFile(file: MediaFile): File? = null
            override fun isDownloaded(file: MediaFile): Boolean = false
            override suspend fun ensureThumbnail(file: MediaFile) = Unit
        }
        assertNull(source.cameraThumbnailBytes(clip))
        assertNull(MonitorMediaThumbnails.load(clip, source, maxPx = 64))
    }

    @Test
    fun durationComesFromTheListingWhenKnown() = runTest {
        assertEquals(null, MonitorMediaThumbnails.durationLabel(clip.copy(durationSeconds = 0), Source()))
    }
}
