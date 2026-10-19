package com.opencapture.opencine.appkit

import android.content.Intent
import android.net.Uri
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.opencapture.opencine.media.MonitorMediaShareStagingPolicy
import java.io.File
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test
import org.junit.runner.RunWith

/**
 * IA-552: Pocket and Insta cache delivered originals under `noBackupFilesDir`, which FileProvider
 * cannot name, so sharing two or more clips found no URI and failed ("Couldn't share these clips.").
 */
@RunWith(AndroidJUnit4::class)
class MediaShareProviderTest {
    private val context = InstrumentationRegistry.getInstrumentation().targetContext
    private val root = File(context.noBackupFilesDir, "OpenPocketCine/media/SIMULATED")

    @After fun cleanUp() {
        root.deleteRecursively()
        File(context.cacheDir, "share").deleteRecursively()
    }

    @Test fun severalPrivateCacheClipsShareThroughTheProvider() {
        val files = listOf("DJI_0001.MP4", "DJI_0002.MP4").mapIndexed { index, name ->
            File(root, "files/$name").apply { parentFile!!.mkdirs(); writeBytes(ByteArray(32) { (it + index).toByte() }) }
        }
        val chooser = MediaShare("SIMULATED").chooserIntent(context, files, { "video/mp4" })
        assertNotNull("several clips must reach the chooser", chooser)
        @Suppress("DEPRECATION")
        val send = chooser!!.getParcelableExtra<Intent>(Intent.EXTRA_INTENT)!!
        assertEquals(Intent.ACTION_SEND_MULTIPLE, send.action)
        @Suppress("DEPRECATION")
        val uris = send.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)!!
        assertEquals(2, uris.size)
        uris.forEachIndexed { index, uri ->
            assertEquals("${context.packageName}.mediafileprovider", uri.authority)
            val bytes = context.contentResolver.openInputStream(uri)!!.use { it.readBytes() }
            assertEquals(files[index].readBytes().toList(), bytes.toList())
        }
    }

    /** A selected clip that cannot be staged fails the whole share instead of silently dropping out. */
    @Test fun aClipThatCannotBeStagedFailsTheWholeShare() {
        val files = listOf("DJI_0001.MP4" to 16, "DJI_0002.MP4" to 64).map { (name, size) ->
            File(root, "files/$name").apply { parentFile!!.mkdirs(); writeBytes(ByteArray(size)) }
        }
        val tight = MonitorMediaShareStagingPolicy(maximumReadyBytes = 48, maximumReadyArtifacts = 4,
            grantRetentionMillis = 0, copyBufferBytes = 16)
        assertNull("a partial batch must not reach the chooser",
            MediaShare("SIMULATED", staging = tight).chooserIntent(context, files, { "video/mp4" }))
    }
}
