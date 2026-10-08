package com.opencapture.opencine.dji

import com.opencapture.opencine.vocabulary.*
import kotlin.test.Test
import kotlin.test.assertEquals

class DjiCameraLUTProfileTest {
    private data class AutoCase(
        val name: String,
        val selection: String,
        val colorMode: Int,
        val family: String,
        val cameraName: String?,
        val expected: LutLookSource,
    )

    @Test
    fun `auto selections pick the official cube for the body`() {
        val cases =
            listOf(
                AutoCase(
                    "built-in auto follows pocket D-Log2",
                    LutCatalog.AUTO, CameraCommands.COLOR_DLOG2, "pocket", null,
                    LutLookSource.Asset("DJI_Official_Pocket4P_DLog2_Rec709_33.cube"),
                ),
                AutoCase(
                    "built-in auto follows pocket D-Log",
                    LutCatalog.AUTO, CameraCommands.COLOR_DLOG, "pocket", null,
                    LutLookSource.Asset("DJI_Official_Pocket4P_DLog_Rec709_33.cube"),
                ),
                AutoCase(
                    "built-in auto leaves pocket normal ungraded",
                    LutCatalog.AUTO, CameraCommands.COLOR_NORMAL, "pocket", null,
                    LutLookSource.Off,
                ),
                AutoCase(
                    "built-in auto grades nano with the Nano D-Log M cube",
                    LutCatalog.AUTO, CameraCommands.COLOR_DLOG2, "nano", "Osmo Nano",
                    LutLookSource.Asset("DJI_Official_Nano_DLogM_Rec709_33.cube"),
                ),
                AutoCase(
                    "dji auto picks the Pocket 4 Pro cube",
                    LutCatalog.OFFICIAL_AUTO, CameraCommands.COLOR_DLOG2, "pocket", "Pocket 4 Pro",
                    LutLookSource.Asset("DJI_Official_Pocket4P_DLog2_Rec709_33.cube"),
                ),
                AutoCase(
                    "dji auto picks the Nano cube",
                    LutCatalog.OFFICIAL_AUTO, CameraCommands.COLOR_DLOG2, "nano", "Osmo Nano",
                    LutLookSource.Asset("DJI_Official_Nano_DLogM_Rec709_33.cube"),
                ),
                AutoCase(
                    "dji auto picks the Action 6 cube",
                    LutCatalog.OFFICIAL_AUTO, 0x00, "nano", "Osmo Action 6",
                    LutLookSource.Asset("DJI_Official_Action6_DLogM_Rec709_33.cube"),
                ),
            )
        for (case in cases) {
            assertEquals(
                case.expected,
                LutLookResolver.resolve(
                    case.selection,
                    lutOn = true,
                    colorMode = case.colorMode,
                    profile = DjiCameraLUTProfile.make(case.family, case.cameraName),
                ),
                case.name,
            )
        }
    }

}
