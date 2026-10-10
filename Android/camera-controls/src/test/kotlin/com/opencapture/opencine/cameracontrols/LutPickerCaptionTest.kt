package com.opencapture.opencine.cameracontrols

import com.opencapture.opencine.vocabulary.CameraCommands
import com.opencapture.opencine.vocabulary.LutCatalog
import com.opencapture.opencine.vocabulary.CameraLUTProfile
import com.opencapture.opencine.vocabulary.LutLookSource
import kotlin.test.Test
import kotlin.test.assertEquals

/** The picker captions with each shipping app's copy, as on its main. */
class LutPickerCaptionTest {
    private val sourceProfile = CameraLUTProfile(automatic = mapOf(
        CameraCommands.COLOR_DLOG to LutLookSource.Asset("DJI_Official_Pocket4P_DLog_Rec709_33.cube")))

    private val official = LutPickerCopy(
        cameraTab = "DJI",
        autoId = LutCatalog.OFFICIAL_AUTO,
        customHint = "Imported looks land here. Auto stays on Built-in or DJI.",
        noLookCaption = "No matching look for this color / camera",
        officialCubeCaption = "Official DJI Rec.709 cube",
        cameraLooksCaption = "Official DJI looks for this color / camera",
    )
    private val looks = LutPickerCopy(
        cameraTab = "Camera",
        autoId = LutCatalog.AUTO,
        customHint = "Imported looks land here. Auto keeps the Rec.709 preview unchanged.",
        noLookCaption = "Rec.709 preview · no conversion needed",
        officialCubeCaption = "Camera looks for this color profile",
        cameraLooksCaption = "Camera looks for this color profile",
    )

    private fun camera(copy: LutPickerCopy, selection: String, colorMode: Int = CameraCommands.COLOR_NORMAL, isPhoto: Boolean = false) =
        cameraCaption(copy, selection, colorMode, sourceProfile, isPhoto)

    @Test fun autoSaysWhatItApplies() {
        assertEquals("No matching look for this color / camera", camera(official, LutCatalog.OFFICIAL_AUTO))
        assertEquals("Rec.709 preview · no conversion needed", camera(looks, LutCatalog.AUTO))
        for (copy in listOf(official, looks)) {
            assertEquals("Applying official D-Log → Rec.709", camera(copy, copy.autoId, CameraCommands.COLOR_DLOG))
        }
    }

    @Test fun manualSelectionsUseTheAppCopy() {
        assertEquals("Official DJI Rec.709 cube", camera(official, "djiDLog2"))
        assertEquals("Official DJI looks for this color / camera", camera(official, "creativeMono"))
        assertEquals("Camera looks for this color profile", camera(looks, "djiDLog2"))
        assertEquals("Camera looks for this color profile", camera(looks, "creativeMono"))
        assertEquals("Manual camera conversion", camera(looks, "camera:unknown"))
    }

    @Test fun photoLiveViewAndCreativeCaptionsAreShared() {
        for (copy in listOf(official, looks)) {
            assertEquals(LutCatalog.PHOTO_REC709_CAPTION, camera(copy, copy.autoId, CameraCommands.COLOR_DLOG, isPhoto = true))
            assertEquals("Applying Mono", creativeCaption(copy, "creativeMono", CameraCommands.COLOR_NORMAL, null, false))
            assertEquals("Looks for the displayed picture", creativeCaption(copy, copy.autoId, CameraCommands.COLOR_NORMAL, null, false))
        }
    }
}
