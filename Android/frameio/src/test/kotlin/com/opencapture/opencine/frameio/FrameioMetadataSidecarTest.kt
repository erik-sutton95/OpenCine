package com.opencapture.opencine.frameio

import java.nio.file.Files
import kotlin.io.path.createTempDirectory
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertTrue
import kotlinx.coroutines.test.runTest

class FrameioMetadataSidecarTest {
    @Test
    fun `metadata sidecar records approved delivery context without cloud identifiers`() = runTest {
        val root = createTempDirectory("frameio-metadata")
        try {
            val destination =
                FrameioDestination(
                    accountID = "private-account-id",
                    workspaceID = "private-workspace-id",
                    projectID = "private-project-id",
                    projectName = "Dailies",
                    folderID = "private-folder-id",
                )
            val writer = AndroidFrameioMetadataSidecarWriter(root, fallbackStem = "OpenCine", clock = { 123_000L })

            writer.recordSuccessfulDelivery(
                FrameioSidecarFacts("camera-unit", "20260715T120000", "C0001.MOV", "Unit LUT"),
                deliveryFilename = "C0001.mp4",
                byteCount = 9,
                destination = destination,
            )

            val sidecar =
                Files.list(root).use { paths ->
                    paths.iterator().asSequence().firstOrNull { path -> path.fileName.toString().endsWith(".meta.json") }
                }
            assertNotNull(sidecar)
            assertTrue(sidecar.fileName.toString().startsWith("C0001-123000-"))
            val body = String(Files.readAllBytes(sidecar), Charsets.UTF_8)
            assertTrue(body.contains("\"originalFilename\": \"C0001.MOV\""))
            assertTrue(body.contains("\"deliveryFilename\": \"C0001.mp4\""))
            assertTrue(body.contains("\"projectName\": \"Dailies\""))
            assertTrue(body.contains("\"lutName\": \"Unit LUT\""))
            assertTrue(body.contains("\"cameraID\": \"camera-unit\""))
            assertTrue(body.contains("\"sizeBytes\": 9"))
            assertFalse(body.contains("private-account-id"))
            assertFalse(body.contains("private-workspace-id"))
            assertFalse(body.contains("private-project-id"))
            assertFalse(body.contains("private-folder-id"))
        } finally {
            root.toFile().deleteRecursively()
        }
    }

    @Test
    fun `an unusable original name falls back to the app stem and history stays bounded`() = runTest {
        val root = createTempDirectory("frameio-metadata")
        try {
            var now = 0L
            val writer = AndroidFrameioMetadataSidecarWriter(root, fallbackStem = "OpenCine", clock = { now })
            val facts = FrameioSidecarFacts("camera", "", ".MOV", null)
            repeat(101) {
                now += 1
                writer.recordSuccessfulDelivery(facts, "clip.mov", 1, SAVED_DESTINATION)
            }

            val names = Files.list(root).use { paths -> paths.iterator().asSequence().map { it.fileName.toString() }.toList() }
            assertEquals(100, names.size)
            assertTrue(names.all { it.startsWith("OpenCine-") && it.endsWith(".meta.json") })
        } finally {
            root.toFile().deleteRecursively()
        }
    }

    @Test
    fun `codec escapes control characters and writes a null look`() {
        val body = FrameioMetadataSidecarCodec.encode(
            FrameioMetadataSidecar("cam\"era", "", "2026-10-12T00:00:00Z", "a\nb", null, "c\u0001", "Dailies", 4))

        assertTrue(body.contains("\"cameraID\": \"cam\\\"era\""))
        assertTrue(body.contains("\"deliveryFilename\": \"a\\nb\""))
        assertTrue(body.contains("\"originalFilename\": \"c\\u0001\""))
        assertTrue(body.contains("\"lutName\": null"))
        assertTrue(body.endsWith("\"version\": 1\n}"))
    }
}
