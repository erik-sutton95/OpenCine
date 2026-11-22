package com.opencapture.opencine.appkitnative

import android.content.ContextWrapper
import android.graphics.Bitmap
import androidx.test.platform.app.InstrumentationRegistry
import com.opencapture.opencine.runtime.MonitorReferenceFrame
import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertTrue
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext

class MonitorReferenceStoreTest {
    @Test fun failedReplacementKeepsTheUprightReferenceAcrossStoreRecreation() = runBlocking {
        val target = InstrumentationRegistry.getInstrumentation().targetContext
        val folder = File(target.cacheDir, "reference-store-test").apply { mkdirs() }
        val context = object : ContextWrapper(target) {
            override fun getNoBackupFilesDir(): File = folder
        }
        try {
            withContext(Dispatchers.Main) {
                val original = MonitorReferenceStore(context)
                val bitmap = Bitmap.createBitmap(160, 90, Bitmap.Config.ARGB_8888)
                assertTrue(original.save { MonitorReferenceFrame(bitmap, 9f / 16f, 90) })
                assertFalse(original.save { null })
                val restarted = MonitorReferenceStore(context)
                restarted.load()
                val image = assertNotNull(restarted.reference)
                assertEquals(9f / 16f, image.aspect)
                assertEquals(90, image.bitmap.width)
                assertEquals(160, image.bitmap.height)
                assertFalse(restarted.shown)
            }
        } finally {
            folder.deleteRecursively()
        }
    }
}
