package com.opencapture.opencine.insta360.luna

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Which Insta360 bodies the Luna integration connects to, what each is called and what its lenses
 * can do. Swift twin: `LunaModelTests`, same method names.
 */
class LunaModelTest {
    @Test fun theLunaUltraAndLunaProAreSupported() {
        assertEquals(LunaModel.ULTRA, LunaModel.identify("Insta360 Luna Ultra"))
        assertEquals(LunaModel.PRO, LunaModel.identify("Insta360 Luna Pro"))
        // The Pro's string is unconfirmed on hardware: case, spacing and the brand prefix do not matter.
        assertEquals(LunaModel.PRO, LunaModel.identify("  insta360  LUNA pro "))
        assertEquals(LunaModel.PRO, LunaModel.identify("Luna Pro"))
        assertEquals(listOf(LunaModel.ULTRA, LunaModel.PRO), LunaModel.supported)
    }

    @Test fun otherCamerasAndUnknownLunaVariantsAreRefused() {
        for (reported in listOf("Insta360 ONE RS", "Insta360 X4", "", "Insta360", "Insta360 Luna", "Insta360 Luna Max", "Insta360 Luna Ultra 2")) {
            assertNull(LunaModel.identify(reported), reported)
        }
        assertFalse(LunaModel.isLunaFamily("Insta360 ONE RS"))
        assertFalse(LunaModel.isLunaFamily("Insta360 Lunar"))
        assertTrue(LunaModel.isLunaFamily("Insta360 Luna Max"))
    }

    @Test fun theRefusalNamesTheCameraAndTheSupportedBodies() {
        assertEquals(
            "This camera is Insta360 ONE RS. OpenInstaCine currently supports the Insta360 Luna Ultra and Luna Pro.",
            LunaModel.unsupportedMessage("Insta360 ONE RS", "OpenInstaCine"),
        )
        assertEquals(
            "This camera is Insta360 Luna Max, a Luna model OpenInstaCine does not support yet. " +
                "OpenInstaCine currently supports the Insta360 Luna Ultra and Luna Pro.",
            LunaModel.unsupportedMessage("Insta360  Luna Max", "OpenInstaCine"),
        )
        assertEquals(
            "This camera did not report its model. This app currently supports the Insta360 Luna Ultra and Luna Pro.",
            LunaModel.unsupportedMessage(" ", "This app"),
        )
    }

    @Test fun eachBodyHasItsNameAndLenses() {
        assertEquals("Luna Ultra", LunaModel.ULTRA.name)
        assertEquals("Luna Pro", LunaModel.PRO.name)
        assertEquals("Luna", LunaModel.FAMILY_NAME)
        // Ultra: unchanged from before the Pro (presets of fw 1.1.15, 15x, tele at 3x).
        assertTrue(LunaModel.ULTRA.hasTelephoto)
        assertEquals(listOf(1.0, 2.0, 3.0, 6.0, 15.0), LunaModel.ULTRA.zoomPresets)
        assertEquals(LunaControl.MAXIMUM_ZOOM, LunaModel.ULTRA.maximumZoom)
        assertEquals(listOf(1.0, 3.0), LunaModel.ULTRA.opticalZoomStops)
        assertTrue(LunaModel.ULTRA.hardwareQualified)
        // Pro: one main camera, so no 3x stop and nothing past its 4x.
        assertFalse(LunaModel.PRO.hasTelephoto)
        assertEquals(listOf(1.0, 2.0, 4.0), LunaModel.PRO.zoomPresets)
        assertEquals(4.0, LunaModel.PRO.maximumZoom)
        assertEquals(listOf(1.0), LunaModel.PRO.opticalZoomStops)
        assertFalse(3.0 in LunaModel.PRO.zoomPresets)
        assertFalse(LunaModel.PRO.hardwareQualified, "untested until a Luna Pro connects")
        for (model in LunaModel.supported) {
            assertEquals(1.0, model.zoomPresets.first())
            assertEquals(model.maximumZoom, model.zoomPresets.last())
        }
    }
}
