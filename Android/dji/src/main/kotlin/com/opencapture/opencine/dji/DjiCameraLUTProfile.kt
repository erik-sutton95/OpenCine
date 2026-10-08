package com.opencapture.opencine.dji

import com.opencapture.opencine.vocabulary.CameraCommands
import com.opencapture.opencine.vocabulary.CameraLUTProfile
import com.opencapture.opencine.vocabulary.CameraModel
import com.opencapture.opencine.vocabulary.LutLookSource

/** Manufacturer catalogue and body-specific cube policy stay in the camera integration. */
object DjiCameraLUTProfile {
    fun make(model: CameraModel): CameraLUTProfile = make(model.family, model.name)

    fun make(family: String, cameraName: String?): CameraLUTProfile {
        val n = cameraName.orEmpty().lowercase().replace(" ", "")
        val logM = LutLookSource.Asset(if ("action6" in n)
            "DJI_Official_Action6_DLogM_Rec709_33.cube" else "DJI_Official_Nano_DLogM_Rec709_33.cube")
        val log = LutLookSource.Asset("DJI_Official_Pocket4P_DLog_Rec709_33.cube")
        val log2 = LutLookSource.Asset("DJI_Official_Pocket4P_DLog2_Rec709_33.cube")
        val nano = family.equals("nano", ignoreCase = true)
        return CameraLUTProfile(automatic = mapOf(
            CameraCommands.COLOR_DLOG to if (nano) logM else log,
            CameraCommands.COLOR_DLOG2 to if (nano) logM else log2,
            CameraCommands.COLOR_DLOG_M to logM,
        ), selections = mapOf("djiDLogM" to logM))
    }
}
