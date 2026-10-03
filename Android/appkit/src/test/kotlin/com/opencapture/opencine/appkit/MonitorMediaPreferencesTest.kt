package com.opencapture.opencine.appkit

import android.content.SharedPreferences
import com.opencapture.opencine.media.MediaTransferReceipt
import kotlinx.coroutines.test.runTest
import java.lang.reflect.Proxy
import java.nio.file.Files
import kotlin.test.*

class MonitorMediaPreferencesTest {
    @Test fun legacyFavoritesAndLastCameraLoadWithoutWritesAndSaveSorted() {
        val memory = MediaPreferencesMemory()
        memory.values["legacy.favorites"] = "z\u001fa"; memory.values["legacy.last"] = "camera-A"
        memory.values["unrelated"] = "unknown-17"
        val prior = memory.values.toMap()
        val store = MonitorMediaPreferences(memory.storage, "legacy.favorites", "legacy.last", "\u001f")
        assertEquals(setOf("a", "z"), store.favorites()); assertEquals("camera-A", store.lastCamera)
        assertEquals(prior, memory.values)
        store.saveFavorites(setOf("b", "a"))
        assertEquals("a\u001fb", memory.values["legacy.favorites"]); assertEquals("unknown-17", memory.values["unrelated"])
    }
    @Test fun favoriteNamespacesAndStorageDomainsStayIndependent() {
        val first = MediaPreferencesMemory(); val second = MediaPreferencesMemory()
        val a = MonitorMediaPreferences(first.storage, "favorites.A", "last", "\u001f")
        val b = MonitorMediaPreferences(first.storage, "favorites.B", "last", "\u001f")
        val otherApp = MonitorMediaPreferences(second.storage, "favorites.A", "last", "\u001f")
        a.saveFavorites(setOf("take.mov")); a.lastCamera = "A"
        assertTrue(b.favorites().isEmpty() && otherApp.favorites().isEmpty()); assertNull(otherApp.lastCamera)
        b.saveFavorites(setOf("other.mov"))
        assertEquals(setOf("take.mov"), a.favorites()); assertEquals(setOf("other.mov"), b.favorites())
    }
    @Test fun retiredModelWriterSharesRootGenerationWithReplacementCache() = runTest {
        val root = Files.createTempDirectory("opencine-media-storage-").toFile()
        try {
            val storage = MonitorMediaCacheStorage(); val old = storage.directory(root)
            val writer = old.beginWrite("files/take.mov"); writer.write(byteArrayOf(1))
            val replacement = storage.directory(java.io.File(root, "."))
            replacement.clear(emptyList()); replacement.write(byteArrayOf(2), "files/take.mov")
            assertEquals(MonitorMediaCacheFailure.RETIRED, assertFailsWith<MonitorMediaCacheException> {
                writer.commit(MediaTransferReceipt(1))
            }.failure)
            writer.abort(); assertContentEquals(byteArrayOf(2), replacement.read("files/take.mov"))
        } finally { root.deleteRecursively() }
    }
}

private class MediaPreferencesMemory {
    val values = mutableMapOf<String, String>()
    val storage: SharedPreferences = Proxy.newProxyInstance(SharedPreferences::class.java.classLoader,
        arrayOf(SharedPreferences::class.java)) { _, method, args ->
        when (method.name) {
            "getString" -> values[args!![0] as String] ?: args[1]
            "edit" -> editor()
            else -> error("Unexpected preferences call ${method.name}")
        }
    } as SharedPreferences
    private fun editor(): SharedPreferences.Editor = Proxy.newProxyInstance(SharedPreferences.Editor::class.java.classLoader,
        arrayOf(SharedPreferences.Editor::class.java)) { proxy, method, args ->
        when (method.name) {
            "putString" -> { values[args!![0] as String] = args[1] as String; proxy }
            "remove" -> { values.remove(args!![0] as String); proxy }
            "apply" -> null
            else -> error("Unexpected editor call ${method.name}")
        }
    } as SharedPreferences.Editor
}
