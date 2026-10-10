package com.opencapture.opencine.vocabulary

import com.opencapture.opencine.media.MonitorTransfer
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertIs

class LutLookResolverTest {
    private val declaredLooks = CameraLUTProfile(automatic = mapOf(
        CameraCommands.COLOR_DLOG to LutLookSource.Asset("DJI_Official_Pocket4P_DLog_Rec709_33.cube"),
        CameraCommands.COLOR_DLOG2 to LutLookSource.Asset("DJI_Official_Pocket4P_DLog2_Rec709_33.cube"),
    ))

    @Test fun `unknown profile never invents a camera cube`() {
        assertEquals(LutLookSource.Off,
            LutLookResolver.resolve(LutCatalog.AUTO, true, CameraCommands.COLOR_DLOG2))
        assertEquals(LutLookSource.Off,
            LutLookResolver.resolve("djiDLogM", true, CameraCommands.COLOR_DLOG_M))
    }

    private val iLogLook =
        LutEntry(
            id = "camera:ilog",
            title = "I-Log → Rec.709",
            category = LutCategory.CAMERA,
            fileName = "Luna_I-Log_to_Rec709_BT1886_s33_v2.cube",
            inputTransfer = MonitorTransfer.ILOG,
        )

    @Test
    fun `Auto picks the camera look matching the live transfer`() {
        fun auto(colorMode: Int) =
            LutLookResolver.resolve(LutCatalog.AUTO, true, colorMode, cameraLooks = listOf(iLogLook))
        val iLog = auto(CameraCommands.COLOR_ILOG)
        assertEquals(
            LutLookSource.Asset("Luna_I-Log_to_Rec709_BT1886_s33_v2.cube", MonitorTransfer.ILOG, "I-Log → Rec.709"),
            iLog,
        )
        assertEquals("Auto · I-Log → Rec.709", LutLookResolver.statusLabel(true, LutCatalog.AUTO, iLog))
        assertEquals(LutLookSource.Off, auto(CameraCommands.COLOR_NORMAL))
        assertEquals(LutLookSource.Off, auto(CameraCommands.COLOR_DOLBY_VISION))
        assertEquals(LutLookSource.Off, auto(-1))
    }

    @Test
    fun `chip off drops the cube`() {
        assertEquals(
            LutLookSource.Off,
            LutLookResolver.resolve(
                selection = LutCatalog.AUTO,
                lutOn = false,
                colorMode = CameraCommands.COLOR_DLOG2,
                profile = declaredLooks,
            ),
        )
    }

    @Test
    fun `custom selection keeps the stored file`() {
        val source =
            LutLookResolver.resolve(
                LutCatalog.customId("Look.cube"),
                lutOn = true,
                colorMode = CameraCommands.COLOR_DLOG2,
                profile = declaredLooks,
            )
        val custom = assertIs<LutLookSource.Custom>(source)
        assertEquals("Look.cube", custom.fileName)
    }

    @Test
    fun `status label matches iOS Auto cube copy`() {
        val autoDlog2 =
            LutLookResolver.resolve(
                LutCatalog.AUTO,
                lutOn = true,
                colorMode = CameraCommands.COLOR_DLOG2,
                profile = declaredLooks,
            )
        assertEquals(
            "Auto · D-Log2 → Rec.709",
            LutLookResolver.statusLabel(enabled = true, selection = LutCatalog.AUTO, source = autoDlog2),
        )
        assertEquals(
            "Auto · Off",
            LutLookResolver.statusLabel(
                enabled = true,
                selection = LutCatalog.AUTO,
                source = LutLookSource.Off,
            ),
        )
        assertEquals(
            "Off · Auto",
            LutLookResolver.statusLabel(enabled = false, selection = LutCatalog.AUTO, source = autoDlog2),
        )
        assertEquals(
            "Auto · D-Log2 → Rec.709",
            LutLookResolver.statusLabel(
                enabled = true,
                selection = LutCatalog.OFFICIAL_AUTO,
                source =
                    LutLookResolver.resolve(
                        LutCatalog.OFFICIAL_AUTO,
                        lutOn = true,
                        colorMode = CameraCommands.COLOR_DLOG2,
                        profile = declaredLooks,
                    ),
            ),
        )
    }

    @Test
    fun `photo live view bypasses auto and manual log conversions`() {
        assertEquals(
            LutLookSource.Off,
            LutLookResolver.resolve(
                LutCatalog.OFFICIAL_AUTO,
                lutOn = true,
                colorMode = CameraCommands.COLOR_DLOG2,
                profile = declaredLooks,
                isPhoto = true,
            ),
        )
        assertEquals(
            LutLookSource.Off,
            LutLookResolver.resolve(
                "djiDLog2",
                lutOn = true,
                colorMode = CameraCommands.COLOR_DLOG2,
                profile = declaredLooks,
                isPhoto = true,
            ),
        )
        assertEquals(
            LutLookSource.Off,
            LutLookResolver.resolve(
                "customDLog",
                lutOn = true,
                colorMode = CameraCommands.COLOR_DLOG,
                profile = declaredLooks,
                isPhoto = true,
            ),
        )
        assertIs<LutLookSource.Creative>(
            LutLookResolver.resolve(
                "creativeWarm",
                lutOn = true,
                colorMode = CameraCommands.COLOR_DLOG2,
                profile = declaredLooks,
                isPhoto = true,
            ),
        )
        val custom =
            assertIs<LutLookSource.Custom>(
                LutLookResolver.resolve(
                    LutCatalog.customId("Look.cube"),
                    lutOn = true,
                    colorMode = CameraCommands.COLOR_DLOG2,
                    profile = declaredLooks,
                    isPhoto = true,
                ),
            )
        assertEquals("Look.cube", custom.fileName)
        assertEquals(
            LutLookSource.Asset("DJI_Official_Pocket4P_DLog2_Rec709_33.cube"),
            LutLookResolver.resolve(
                LutCatalog.OFFICIAL_AUTO,
                lutOn = true,
                colorMode = CameraCommands.COLOR_DLOG2,
                profile = declaredLooks,
                isPhoto = false,
            ),
        )
    }
}
