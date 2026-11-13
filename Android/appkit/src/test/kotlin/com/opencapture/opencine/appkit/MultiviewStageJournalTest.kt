package com.opencapture.opencine.appkit

import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class MultiviewStageJournalTest {
    private fun camera(
        slot: Int = 0,
        id: String = "id-$slot",
        name: String = "Camera",
        address: String = "",
    ) = MultiviewStageJournal.Camera(
        slot = slot, id = id, name = name, modelId = null, identity = null, deviceAddress = null,
        address = address, experimental = false, lutEnabled = false,
    )

    private fun stage(
        ssid: String = "Test",
        focusedIndex: Int = 0,
        cameras: List<MultiviewStageJournal.Camera> = emptyList(),
        pendingReset: List<MultiviewStageJournal.Camera>? = null,
    ) = MultiviewStageJournal.Stage(
        ssid = ssid, hotspot = false, layout = "Grid", focusedIndex = focusedIndex,
        cameras = cameras, pendingReset = pendingReset,
    )

    @Test fun aStageSavedByPocketIOSDecodes() {
        // iOS writes no device address and no identity for a camera without one.
        val json = """{"version":1,"ssid":"Test network","hotspot":true,"layout":"Grid","focusedIndex":2,""" +
            """"cameras":[{"slot":1,"id":"0F8FAD5B-D9CB-469F-A165-70867728950E","name":"OsmoPocket3-Test",""" +
            """"modelId":32,"address":"192.168.1.31","experimental":false,"lutEnabled":true}],""" +
            """"pendingReset":[],"returnedToCameraWiFi":true,"fill":true}"""
        val decoded = assertNotNull(MultiviewStageJournal.decode(json))
        assertEquals("0F8FAD5B-D9CB-469F-A165-70867728950E", decoded.cameras[0].id)
        assertEquals(32, decoded.cameras[0].modelId)
        assertNull(decoded.cameras[0].deviceAddress)
        assertNull(decoded.cameras[0].identity)
        assertEquals(true, decoded.fill)
    }

    @Test fun aStageSavedByPocketAndroidDecodes() {
        val json = """{"version":1,"ssid":"Test","hotspot":false,"layout":"Center stage","focusedIndex":0,""" +
            """"cameras":[{"slot":0,"id":"a","name":"OsmoPocket3-a","bleAddress":"AA:BB:CC:DD:EE:00",""" +
            """"address":"192.168.1.30","experimental":false,"lutEnabled":false,"modelId":32,"identity":"000541"}]}"""
        val decoded = assertNotNull(MultiviewStageJournal.decode(json))
        assertEquals("AA:BB:CC:DD:EE:00", decoded.cameras[0].deviceAddress)
        assertContentEquals(byteArrayOf(0, 5, 0x41), decoded.cameras[0].identity)
        assertNull(decoded.pendingReset)
    }

    @Test fun encodeThenDecodeKeepsEveryField() {
        val full = camera(slot = 2, id = "a", name = "Test", address = "192.168.1.20").copy(
            modelId = 0x20, identity = byteArrayOf(0, 4, 84), deviceAddress = "AA:BB",
            experimental = true, lutEnabled = true,
        )
        val original = MultiviewStageJournal.Stage(
            ssid = "Test network", hotspot = true, layout = "Grid", focusedIndex = 2,
            cameras = listOf(full), pendingReset = listOf(full), returnedToCameraWiFi = false, fill = true,
        )
        assertEquals(original, MultiviewStageJournal.decode(MultiviewStageJournal.encode(original)))
        assertFalse(MultiviewStageJournal.encode(original).contains("password"))
    }

    @Test fun aStageWithoutOptionalFieldsOmitsThem() {
        val text = MultiviewStageJournal.encode(stage(cameras = listOf(camera())))
        assertFalse(text.contains("fill") || text.contains("pendingReset") || text.contains("bleAddress"))
        assertNull(MultiviewStageJournal.decode(text)!!.fill)
    }

    @Test fun moreCamerasThanTilesIsInvalid() {
        val cameras = (0 until 3).map { camera(slot = it) }
        assertNotNull(stage(cameras = cameras).validated(tileCount = 3))
        assertNull(stage(cameras = cameras).validated(tileCount = 2))
    }

    @Test fun duplicateSlotsOrIdsAreInvalid() {
        val first = camera(slot = 0)
        assertNull(stage(cameras = listOf(first, camera(slot = 0, id = "other"))).validated(4))
        assertNull(stage(cameras = listOf(first, camera(slot = 1, id = first.id))).validated(4))
        assertNull(stage(cameras = listOf(camera(slot = 4))).validated(4))
        assertNull(stage(cameras = listOf(camera(slot = -1))).validated(4))
        assertNull(stage(pendingReset = listOf(first, first)).validated(4))
    }

    @Test fun emptyNamesAreInvalid() {
        assertNull(stage(cameras = listOf(camera(name = ""))).validated(4))
        assertNull(stage(pendingReset = listOf(camera(name = ""))).validated(4))
    }

    @Test fun focusOutsideTheTilesIsInvalid() {
        assertNotNull(stage(focusedIndex = 3).validated(4))
        assertNull(stage(focusedIndex = 4).validated(4))
        assertNull(stage(focusedIndex = -1).validated(4))
        assertNull(stage(focusedIndex = 3).validated(3))
    }

    @Test fun anUnknownVersionIsInvalid() {
        assertNull(stage().copy(version = 99).validated(4))
    }

    @Test fun anEmptyNetworkIsValidOnlyForCleanupWithoutCameras() {
        val cleanup = (0 until 6).map { camera(slot = 0, id = "s$it", name = "Scan $it") }
        assertNotNull(stage(ssid = "", pendingReset = cleanup).validated(4))
        assertNull(stage(ssid = "", cameras = listOf(camera()), pendingReset = cleanup).validated(4))
        assertNull(stage(ssid = "", pendingReset = emptyList()).validated(4))
        assertNull(stage(ssid = "").validated(4))
    }

    @Test fun unreadableStoredTextDecodesToNull() {
        assertNull(MultiviewStageJournal.decode("not json"))
        assertNull(MultiviewStageJournal.decode("""{"version":1}"""))
    }

    @Test fun cleanupTargetsReplaceByIdAndAppendNewCameras() {
        val merged = MultiviewStageJournal.cleanupTargets(
            listOf(camera(slot = 0, id = "a"), camera(slot = 1, id = "b")),
            listOf(camera(slot = 3, id = "a").copy(lutEnabled = true), camera(slot = 2, id = "c")),
        )
        assertEquals(listOf("a", "b", "c"), merged.map { it.id })
        assertTrue(merged.first().lutEnabled)
    }
}
