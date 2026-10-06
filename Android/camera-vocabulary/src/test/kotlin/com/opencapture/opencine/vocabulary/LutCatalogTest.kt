package com.opencapture.opencine.vocabulary

import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class LutCatalogTest {
    private val shipped =
        listOf(
            "DJI_Official_Action6_DLogM_Rec709_33.cube",
            "DJI_Official_Nano_DLogM_Rec709_33.cube",
            "DJI_Official_Pocket4P_DLog2_Rec709_33.cube",
            "DJI_Official_Pocket4P_DLog_Rec709_33.cube",
            "DJI_Pocket4P_DLog2_Rec709_33.cube",
            "DJI_Pocket4P_DLog_Rec709_33.cube",
        )

    @Test
    fun creativeLooksAreMonoContrastWarmCool() {
        assertEquals(
            listOf("creativeMono", "creativeContrast", "creativeWarm", "creativeCool"),
            LutCatalog.creative.map { it.id },
        )
        assertEquals(listOf("Mono", "Contrast", "Warm", "Cool"), LutCatalog.creative.map { it.title })
        assertEquals(LutCategory.CREATIVE, LutCatalog.categoryOf("creativeWarm"))
        assertEquals("djiAuto", LutCatalog.migratedToOfficialCatalog("auto"))
        assertEquals("djiDLog2", LutCatalog.migratedToOfficialCatalog("officialDLog2"))
    }

    @Test
    fun djiTabListsAutoThenOfficialCubesNotBuiltInLooks() {
        val dji = LutCatalog.officialEntries(shipped)
        assertEquals(
            listOf("djiAuto", "djiDLog", "djiDLog2", "djiDLogM", "djiAction6DLogM"),
            dji.map { it.id },
        )
        assertEquals("Auto", dji.first().title)
        assertFalse(dji.any { it.id == "officialDLog" || it.id == "officialDLog2" })
        val photo = LutCatalog.officialEntries(shipped, isPhotoLive = true)
        assertEquals(listOf("djiAuto"), photo.map { it.id })
    }

    @Test
    fun djiTabKeepsUnknownAssetCubes() {
        val dji = LutCatalog.officialEntries(listOf("DJI_Official_Pocket4P_DLog_Rec709_33.cube", "Film.cube"))
        assertEquals(listOf("djiAuto", "djiDLog", "asset:Film.cube"), dji.map { it.id })
        assertEquals("Film", dji.last().title)
    }

    @Test
    fun customIndexSortsAndStripsExtension() {
        val stored = LutCatalog.storedCustom(listOf("B.cube", "a.CUBE", "notes.txt", "../escape.cube"))
        assertEquals(listOf("a.CUBE", "B.cube"), stored.map { it.fileName })
        assertEquals(listOf("a", "B"), stored.map { it.title })
        assertEquals(listOf("custom:a.CUBE", "custom:B.cube"), stored.map { it.id })
    }

    @Test
    fun safeFileNameRejectsPathEscape() {
        assertTrue(LutCatalog.isSafeFileName("Look.cube"))
        assertFalse(LutCatalog.isSafeFileName("../Look.cube"))
        assertFalse(LutCatalog.isSafeFileName("dir/Look.cube"))
        assertFalse(LutCatalog.isSafeFileName("Look:cube.cube"))
        assertNull(LutCatalog.normalizedCubeFileName("../x.cube"))
        assertEquals("Look.cube", LutCatalog.normalizedCubeFileName("Look"))
    }

    @Test
    fun titleAndCategoryCoverPickerIds() {
        assertEquals("Auto", LutCatalog.titleFor("auto"))
        assertEquals("Auto", LutCatalog.titleFor("djiAuto"))
        assertEquals("D-Log2 → Rec.709", LutCatalog.titleFor("officialDLog2"))
        assertEquals("Action 6 D-Log M → Rec.709", LutCatalog.titleFor("djiAction6DLogM"))
        assertEquals("Look", LutCatalog.titleFor("custom:Look.cube"))
        assertEquals("Custom", LutCatalog.titleFor("customFile"))
        assertEquals(LutCategory.CAMERA, LutCatalog.categoryOf("off"))
        assertEquals(LutCategory.CAMERA, LutCatalog.categoryOf("djiDLog"))
        assertEquals(LutCategory.CUSTOM, LutCatalog.categoryOf("custom:Look.cube"))
        assertEquals(LutCategory.CUSTOM, LutCatalog.categoryOf("customFile"))
    }
}
