package com.opencapture.opencine.appkit

import java.io.File
import java.nio.file.Files
import kotlinx.coroutines.test.runTest
import kotlin.test.*

class MonitorMediaCacheScopeTest {
    @Test fun bothOwnersCountLiveAndRetiredOnlyNamespacesOnceAndRetryClear() = runTest {
        for (useStorage in listOf(false, true)) {
            val parent = Files.createTempDirectory("opencine-cache-scope-").toFile()
            try {
                val root = MonitorMediaCacheRoot(parent)
                val storage = MonitorMediaCacheStorage()
                fun discover() = if (useStorage) storage.directories(parent) else root.cachedDirectories()
                val retired = File(parent, ".clearing-camera-with-hyphens-01234567-89AB-CDEF-0123-456789ABCDEF")
                File(retired, "clip.mov").apply { parentFile!!.mkdirs(); writeBytes(ByteArray(3072)) }
                val second = File(parent, ".clearing-camera-with-hyphens-FEDCBA98-7654-3210-FEDC-BA9876543210")
                File(second, "clip.mov").apply { parentFile!!.mkdirs(); writeBytes(ByteArray(1024)) }
                val discovered = discover()
                assertEquals(listOf("camera-with-hyphens"), discovered.map { it.root.name })
                val directory = discovered.single()
                assertEquals(4096L, directory.totalByteCount())
                directory.write(ByteArray(2048), "files/new.mov")
                assertEquals(1, discover().size)
                assertEquals(6144L, directory.totalByteCount())
                directory.clear(emptyList())
                assertTrue(discover().isEmpty())
                assertFalse(retired.exists()); assertFalse(second.exists())
            } finally { parent.deleteRecursively() }
        }
    }

    @Test fun bothOwnersRejectMalformedRetirementsAndLinksAndAccountUnpreparedRoots() = runTest {
        for (useStorage in listOf(false, true)) {
            val parent = Files.createTempDirectory("opencine-cache-scope-").toFile()
            val outside = Files.createTempDirectory("opencine-cache-outside-").toFile()
            try {
                File(outside, "keep.mov").writeBytes(ByteArray(2048))
                for (name in listOf(".clearing-camera-stale", ".hidden",
                    ".clearing-camera-01234567-89AB-CDEF-0123-456789ABCDEF-extra",
                    ".clearing-..-01234567-89AB-CDEF-0123-456789ABCDEF")) File(parent, name).mkdirs()
                Files.createSymbolicLink(File(parent, "camera-link").toPath(), outside.toPath())
                Files.createSymbolicLink(File(parent, ".clearing-retired-link-01234567-89AB-CDEF-0123-456789ABCDEF").toPath(), outside.toPath())
                Files.createSymbolicLink(File(parent, "camera").toPath(), outside.toPath())
                val unprepared = File(parent, ".retiring-camera-01234567-89AB-CDEF-0123-456789ABCDEF")
                File(unprepared, "index.json").apply { parentFile!!.mkdirs(); writeBytes(ByteArray(1024)) }
                val directories = if (useStorage) MonitorMediaCacheStorage().directories(parent)
                    else MonitorMediaCacheRoot(parent).cachedDirectories()
                assertEquals(listOf("camera"), directories.map { it.root.name })
                assertEquals(1024L, directories.single().totalByteCount())
                directories.single().clear(emptyList())
                assertEquals(1024, File(unprepared, "index.json").readBytes().size)
                assertEquals(2048, File(outside, "keep.mov").readBytes().size)
                assertTrue(Files.isSymbolicLink(File(parent, "camera").toPath()))
            } finally { parent.deleteRecursively(); outside.deleteRecursively() }
        }
    }
    @Test fun preparedRetirementBesideALiveAliasRetainsOwnershipWithoutFollowingTheAlias() = runTest {
        for (useStorage in listOf(false, true)) {
            val parent = Files.createTempDirectory("opencine-cache-alias-").toFile()
            val outside = Files.createTempDirectory("opencine-cache-outside-").toFile()
            try {
                val sentinel = File(outside, "keep.mov").apply { writeBytes(byteArrayOf(1, 2, 3)) }
                val retired = File(parent, ".clearing-camera-01234567-89AB-CDEF-0123-456789ABCDEF")
                File(retired, "owned.mov").apply { parentFile!!.mkdirs(); writeBytes(ByteArray(4096)) }
                val live = File(parent, "camera")
                Files.createSymbolicLink(live.toPath(), outside.toPath())
                val directories = if (useStorage) MonitorMediaCacheStorage().directories(parent)
                    else MonitorMediaCacheRoot(parent).cachedDirectories()
                val directory = directories.single()
                assertEquals("camera", directory.root.name)
                assertEquals(4096L, directory.totalByteCount())
                directory.clear(emptyList())
                assertContentEquals(byteArrayOf(1, 2, 3), sentinel.readBytes())
                assertFalse(retired.exists())
                assertTrue(Files.isSymbolicLink(live.toPath()))
            } finally { parent.deleteRecursively(); outside.deleteRecursively() }
        }
    }

}
