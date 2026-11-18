package com.opencapture.opencine.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Swift suite `CameraSettingsPresetTests`, same method names and the same stored text: saving and
 * storing exposure and white balance presets.
 */
class CameraSettingsPresetTest {
    private fun snapshot(
        descriptors: List<SettingDescriptor>, values: List<SettingValue>, invalid: Set<SettingKey> = emptySet(),
    ) = CameraSnapshot(
        CameraSessionID(), connection = ConnectionState.Ready, authority = ControlAuthority.Owner,
        capabilities = CapabilitySnapshot(descriptors = descriptors.associateBy { it.key }),
        settings = values.associate {
            it.key to ObservedValue(it, ObservationOrigin.CAMERA_REPORTED, null,
                if (it.key in invalid) ObservationValidity.Invalid("stale") else ObservationValidity.Valid)
        },
    )

    @Test fun captureKeepsOnlySettableReportedValuesInRecallOrder() {
        val reported = snapshot(
            listOf(
                SettingDescriptor(SettingKey.ISO, domain = SettingDomain(listOf(SettingValue.Iso(ISOValue.Manual(800))))),
                SettingDescriptor(SettingKey.SHUTTER, domain = SettingDomain(listOf(SettingValue.Shutter(ShutterValue.Angle(180.0)))),
                    availability = Availability.Unavailable(UnavailableReason.Mode)),
                SettingDescriptor(SettingKey.APERTURE, SettingAccess.READ_ONLY, SettingDomain(listOf(SettingValue.Aperture(2.0)))),
                SettingDescriptor(SettingKey.WHITE_BALANCE, domain = SettingDomain(range = 2000.0..10000.0, step = 100.0)),
                SettingDescriptor(SettingKey.WHITE_BALANCE_TINT, domain = SettingDomain(range = -10.0..10.0, step = 1.0)),
                SettingDescriptor(SettingKey.EXPOSURE_COMPENSATION,
                    domain = SettingDomain(listOf(SettingValue.ExposureCompensation(Rational(1, 3))))),
                SettingDescriptor(SettingKey.ZOOM, domain = SettingDomain(range = 1.0..2.0)),
            ),
            listOf(
                SettingValue.Iso(ISOValue.Manual(800)), SettingValue.Shutter(ShutterValue.Angle(180.0)),
                SettingValue.Aperture(2.0), SettingValue.WhiteBalance(WhiteBalanceValue.Kelvin(5600)),
                SettingValue.WhiteBalanceTint(3.0), SettingValue.ExposureCompensation(Rational(2, 3)),
                SettingValue.Zoom(1.5),
            ),
            invalid = setOf(SettingKey.WHITE_BALANCE_TINT),
        )
        val preset = assertNotNull(CameraSettingsPreset.capture("Day", reported, id = "a"))
        // Shutter is unavailable in this mode, aperture read-only, tint stale, EV off its domain
        // and zoom is not an exposure or white balance setting.
        assertEquals(listOf(SettingValue.WhiteBalance(WhiteBalanceValue.Kelvin(5600)), SettingValue.Iso(ISOValue.Manual(800))),
            preset.values)
        assertEquals("Day", preset.name)
        assertNull(CameraSettingsPreset.capture("None", snapshot(emptyList(), listOf(SettingValue.Iso(ISOValue.Manual(800))))))
    }

    @Test fun storedTextRoundTripsAndMatchesTheTwin() {
        val presets = listOf(
            CameraSettingsPreset("p1", "Day\texterior", listOf(
                SettingValue.ExposureCompensation(Rational(-1, 3)), SettingValue.Iso(ISOValue.Manual(800)),
                SettingValue.Shutter(ShutterValue.Duration(Rational(1, 50))), SettingValue.Aperture(2.8),
                SettingValue.WhiteBalance(WhiteBalanceValue.Kelvin(5600)), SettingValue.WhiteBalanceTint(-3.0),
            )),
            CameraSettingsPreset("p2", "Night", listOf(
                SettingValue.Iso(ISOValue.AutoLimited(6400)), SettingValue.Shutter(ShutterValue.Angle(172.8)),
                SettingValue.WhiteBalance(WhiteBalanceValue.Preset("tungsten")),
            )),
            CameraSettingsPreset("p3", "Auto", listOf(
                SettingValue.Iso(ISOValue.Auto), SettingValue.Shutter(ShutterValue.Auto),
                SettingValue.WhiteBalance(WhiteBalanceValue.Auto),
            )),
        )
        val text = CameraSettingsPresetCodec.encode(presets)
        assertEquals(
            "opencine-presets 1\n" +
                "p1\tDay exterior\twb=5600K\ttint=-3.0\tiso=800\tshutter=1/50\taperture=2.8\tev=-1/3\n" +
                "p2\tNight\twb=preset:tungsten\tiso=auto:6400\tshutter=172.8deg\n" +
                "p3\tAuto\twb=auto\tiso=auto\tshutter=auto",
            text,
        )
        val expected = listOf(presets[0].copy(name = "Day exterior")) + presets.drop(1)
        assertEquals(expected, CameraSettingsPresetCodec.decode(text))
    }

    @Test fun storedTextSkipsWhatItDoesNotUnderstand() {
        val text = "opencine-presets 1\n" +
            "p1\tKept\tiso=400\tfocus=near\tshutter=1/0\tev=x\n" +
            "p1\tDuplicate id\tiso=800\n" +
            "\tNo id\tiso=800\n" +
            "p2\tNothing known\tlut=rec709\n" +
            "p3\tLater\twb=6500K"
        assertEquals(
            listOf(
                CameraSettingsPreset("p1", "Kept", listOf(SettingValue.Iso(ISOValue.Manual(400)))),
                CameraSettingsPreset("p3", "Later", listOf(SettingValue.WhiteBalance(WhiteBalanceValue.Kelvin(6500)))),
            ),
            CameraSettingsPresetCodec.decode(text),
        )
        assertTrue(CameraSettingsPresetCodec.decode("opencine-presets 2\np1\tNew\tiso=400").isEmpty())
        assertTrue(CameraSettingsPresetCodec.decode("").isEmpty())
    }

    @Test fun aRejectionNamesASkipOnlyForWhatTheCameraCannotDo() {
        assertEquals(CameraSettingsPresetSkip.Unsupported, CameraSettingsPresetSkip.of(CommandRejection.Unsupported))
        assertEquals(CameraSettingsPresetSkip.Unsupported, CameraSettingsPresetSkip.of(CommandRejection.SupportUnknown))
        assertEquals(CameraSettingsPresetSkip.ReadOnly, CameraSettingsPresetSkip.of(CommandRejection.ReadOnly))
        assertEquals(CameraSettingsPresetSkip.Unavailable(UnavailableReason.Mode),
            CameraSettingsPresetSkip.of(CommandRejection.Unavailable(UnavailableReason.Mode)))
        assertEquals(CameraSettingsPresetSkip.OutOfDomain, CameraSettingsPresetSkip.of(CommandRejection.OutOfDomain))
        assertNull(CameraSettingsPresetSkip.of(CommandRejection.NoAuthority))
        assertNull(CameraSettingsPresetSkip.of(CommandRejection.StaleCapabilities))
        assertNull(CameraSettingsPresetSkip.of(CommandRejection.CameraRefused))
    }
}
