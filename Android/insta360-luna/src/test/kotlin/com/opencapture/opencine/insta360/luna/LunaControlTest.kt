package com.opencapture.opencine.insta360.luna

import com.opencapture.opencine.insta360.shell.CameraFocusMode
import kotlin.test.*
import org.junit.Test

/** Fixtures copied from Adapters/Insta360Protocol LunaControlTests / ProtocolTests (captured official-app bytes). */
class LunaControlTest {
    /** SIMULATED encoding of source-backed paging; original captured request fixtures stay exact. */
    @Test fun storageInventoryAndPagingWire() {
        assertEquals("0802103218322003", hex(LunaControl.fileList(location = 3, start = 50, count = 50).body))
        assertEquals("0803", hex(LunaControl.fileInfoList(3).body))
        assertEquals("0a04b001b101", hex(LunaControl.storageListRequest.body))
    }

    /** The official remaining-record-time poll (option 99), per function mode; Swift `remainingTimeRequest`. */
    @Test fun remainingTimeRequestMatchesTheSwiftEncoder() {
        assertEquals("0a01631007", hex(LunaControl.remainingTimeRequest().body))
        assertEquals("0a01631043", hex(LunaControl.remainingTimeRequest(67).body))
    }

    private fun hex(bytes: ByteArray) = bytes.joinToString("") { "%02x".format(it) }
    private fun f(bits: Int) = java.lang.Float.intBitsToFloat(bits).toDouble()

    @Test fun zoomMatchesSwiftEncoder() {
        assertEquals("0a01351216a20100aa0100f80101a903000000000000f03fc005011807", hex(LunaControl.zoom(1.0).body))
        assertEquals("0a01351216a20100aa0100f80101a9030000000000001840c005011807", hex(LunaControl.zoom(6.0).body))
        assertEquals(LunaControl.SET_PHOTOGRAPHY_OPTIONS, LunaControl.zoom(2.0).code)
        assertFailsWith<IllegalArgumentException> { LunaControl.zoom(15.5) }
    }

    /** Swift `testAutofocusAndMeteringSets` (fw 1.1.15 verified on the camera). */
    @Test fun autofocusAndMeteringSets() {
        assertEquals("0a015d120fa20100aa0100f80101c00501e805011807", hex(LunaControl.afMode(1).body))
        assertEquals("0a015d120fa20100aa0100f80101c00501e805031807", hex(LunaControl.afMode(3).body))
        assertEquals("0a015d120fa20100aa0100f80101c00501e805061806", hex(LunaControl.afMode(6, LunaControl.FUNCTION_MODE_PHOTO).body))
        assertEquals("0a012e120fa20100aa0100f80101f00201c005011807", hex(LunaControl.faceMetering(true).body))
        // Matrix is an explicit 0; the camera stores it.
        assertEquals("0a012e120fa20100aa0100f80101f00200c005011807", hex(LunaControl.faceMetering(false).body))
        // A requested 46 that proto3 omits reads as Matrix; an unrequested one stays unknown.
        assertEquals(false, LunaPhotographySettings.parse(LunaWire.hex("082e1200")).faceMetering)
        assertNull(LunaPhotographySettings.parse(LunaWire.hex("085d1200")).faceMetering)
        val showcase = LunaPhotographySettings.parse(LunaWire.hex("082e085d1206f00200e80506"))
        assertEquals(CameraFocusMode.PRODUCT_SHOWCASE, LunaReadout.readout(showcase, null, null).focusMode)
        assertEquals(false, LunaReadout.readout(showcase, null, null).faceMetering)
        // Values the official app never offers (2 MACRO) read as unknown.
        assertNull(LunaReadout.readout(showcase.copy(afMode = 2), null, null).focusMode)
        with(LunaReadout) { for ((wire, mode) in focusModes) assertEquals(wire, focusModes.key(mode)) }
    }

        @Test fun clockMatchesSwiftEncoder() {
        // official-fw1115/01-connect: types 12, 13, 175 and 12:1790315162 13:7200 175:'Europe/Stockholm'.
        val set = LunaControl.setClock(1_790_315_162, 7200, "Europe/Stockholm")
        assertEquals(LunaControl.SET_OPTIONS, set.code)
        assertEquals("0a040c0daf01121c609a95d8d50668a038fa0a10" + hex("Europe/Stockholm".toByteArray()), hex(set.body))
        // West of GMT is a negative int32: ten-byte two's-complement varint.
        assertEquals("0a040c0daf011210600168f0e3ffffffffffffff01fa0a00", hex(LunaControl.setClock(1, -3600, "").body))
        val first = LunaControl.syncTimeAccurate(1_790_758_255_639, 0)
        assertEquals(214, first.code)
        assertEquals("0a0908ef9af3d50610ff04", hex(first.body))
        assertEquals("0a0908ef9af3d50610ff041001", hex(LunaControl.syncTimeAccurate(1_790_758_255_639, 1).body))
    }

    @Test fun gimbalAbsoluteAngleMatchesSwift() {
        assertEquals("08052a0a15000020411d0000a0c1", hex(LunaControl.gimbalSetAngle(pitch = 10f, yaw = -20f).body))
        assertEquals("08052a00", hex(LunaControl.gimbalSetAngle(0f, 0f).body))
        assertEquals("0806", hex(LunaControl.gimbalGetAngle.body))
        assertEquals(LunaControl.GIMBAL_CONTROL, LunaControl.gimbalGetAngle.code)
        val reply = LunaControl.gimbalAngle(LunaWire.hex("080015000000001da57100c125738a04c0"))
        assertEquals(0, reply.grf)
        assertEquals(0f, reply.roll)
        assertEquals(-8.03f, reply.pitch, 0.01f)
        assertEquals(-2.07f, reply.yaw, 0.01f)
        assertFailsWith<IllegalArgumentException> { LunaControl.gimbalSetAngle(Float.NaN, 0f) }
    }

    @Test fun gimbalMatchesSwiftEncoder() {
        // fw 1.1.15: stick moves and the release carry field 4 = 4.
        assertEquals("0801120310c6012004", hex(LunaControl.gimbalStick(1.0, 0.0).body))
        assertEquals("0801120308c6012004", hex(LunaControl.gimbalStick(0.0, 1.0).body))
        assertEquals("0801120308c5012004", hex(LunaControl.gimbalStick(0.0, -1.0).body))
        assertEquals("080112002004", hex(LunaControl.gimbalStick(0.0, 0.0).body))
        assertEquals("0801120308c6012004", hex(LunaControl.gimbal(1, upDown = 99, field4 = 4).body))
        assertEquals("0801120308c501", hex(LunaControl.gimbal(1, upDown = -99).body))
        assertEquals("08021200", hex(LunaControl.gimbal(2).body))
        assertEquals(LunaControl.GIMBAL_CONTROL, LunaControl.gimbal(3).code)
        assertFailsWith<IllegalArgumentException> { LunaControl.gimbal(1, upDown = 100) }
    }

    @Test fun tapFocusMatchesSwiftEncoder() {
        val request = LunaControl.tapFocus(f(0x3ED8_6FB6), f(0x3D5E_0A00), f(0x3E1E_412A), f(0x3E8C_ABB3))
        assertEquals("0a015e1225a20100aa0100f80101c00501f20516080115b66fd83e1d000a5e3d252a411e3e2db3ab8c3e1807", hex(request.body))
        val zeroY = LunaControl.tapFocus(f(0x3E8B_A2E9), 0.0, f(0x3E1E_412A), f(0x3E32_4079))
        assertEquals("0a015e1220a20100aa0100f80101c00501f20511080115e9a28b3e252a411e3e2d7940323e1807", hex(zeroY.body))
    }

    @Test fun trackingMatchesSwiftEncoder() {
        val track = LunaControl.openTracking(f(0x3F05_3C82), 0.0, f(0x3E04_A790), f(0x3E68_09A7), nowMillis = 1_789_558_454_687)
        assertEquals(LunaControl.OPEN_TRACKING, track.code)
        assertEquals("089ff3fbcf8a3415823c053f2590a7043e2da709683e", hex(track.body))
        assertEquals(0, LunaControl.cancelTracking.body.size)
    }

    private fun h(value: String) = LunaWire.hex(value.filterNot(Char::isWhitespace))

    /** Swift `testPhotographySetsMatchOfficialBytes`. */
    @Test fun photographySetsMatchOfficialBytes() {
        val cases = listOf(
            LunaControl.gimbalFollowSpeed(3) to "0a015b1211a20100aa0100f80101c00501da050210031807",
            LunaControl.gimbalMode(1) to "0a015b1211a20100aa0100f80101c00501da050220011807",
            LunaControl.gimbalMode(2) to "0a015b1211a20100aa0100f80101c00501da050220021807",
            LunaControl.gimbalMode(3) to "0a015b1211a20100aa0100f80101c00501da050220031807",
            LunaControl.gimbalMode(4) to "0a015b1211a20100aa0100f80101c00501da050220041807",
            LunaControl.videoExposure(1, iso = 160) to "0a0215641214a20100aa0105080110a001f80101c00501a006021807",
            LunaControl.videoExposure(0) to "0a021564120fa20100aa0100f80101c00501a006021807",
            LunaControl.videoExposure(2, shutterSeconds = 0.02) to "0a031518641221a20100aa010b0802197b14ae47e17a943fc00180e7ffff0ff80101c00501a006021807",
            LunaControl.videoExposure(2, shutterSeconds = 1.0 / 5000) to "0a031518641221a20100aa010b0802192d431cebe2362a3fc00180e7ffff0ff80101c00501a006021807",
            LunaControl.videoExposure(3, shutterSeconds = 0.02) to "0a031518641221a20100aa010b0803197b14ae47e17a943fc00180e7ffff0ff80101c00501a006021807",
            LunaControl.exposureBias(0.3) to "0a0107120e3806a20100aa0100f80101c005011807",
            LunaControl.colorMode(1) to "0a0123120fa20100aa0100f80101980201c005011807",
            LunaControl.colorMode(2) to "0a0123120fa20100aa0100f80101980202c005011807",
            LunaControl.colorMode(5) to "0a0123120fa20100aa0100f80101980205c005011807",
            LunaControl.zoom(3.0) to "0a01351216a20100aa0100f80101a9030000000000000840c005011807",
            LunaControl.recordResolution(52) to "0a021f3f120ca20100aa0100f80134c005011807",
            LunaControl.recordResolution(48) to "0a021f3f120ca20100aa0100f80130c005011807",
            LunaControl.recordResolution(24) to "0a021f3f120ca20100aa0100f80118c005011807",
            LunaControl.recordResolution(454) to "0a021f3f120da20100aa0100f801c603c005011807",
            LunaControl.recordResolution(211) to "0a021f3f120da20100aa0100f801d301c005011807",
            LunaControl.whiteBalanceKelvin(2000) to "0a01271210a20100aa0100f80101b802d00fc005011807",
            LunaControl.whiteBalanceKelvin(2400) to "0a01271210a20100aa0100f80101b802e012c005011807",
            LunaControl.whiteBalanceAuto() to "0a0127120ca20100aa0100f80101c005011807",
            LunaControl.photographyValue(6, 2) to "0a0106120e3002a20100aa0100f80101c005011807",
            // Source-backed shapes and fw 1.1.15 fixes.
            LunaControl.photographyValue(18, 17) to "0a0112120f900111a20100aa0100f80101c005011807",
            LunaControl.photographyValue(33, 0) to "0a0121120fa20100aa0100f80101880200c005011807",
            LunaControl.videoExposure(3, iso = 400, shutterSeconds = 0.02) to "0a021564121da20100aa010e0803109003197b14ae47e17a943ff80101c00501a006021807",
        )
        for ((request, expected) in cases) {
            assertEquals(LunaControl.SET_PHOTOGRAPHY_OPTIONS, request.code)
            assertEquals(expected, hex(request.body))
        }
        // The bank follows the shooting mode: field 3 is the function mode.
        assertTrue(hex(LunaControl.colorMode(2, functionMode = 21).body).endsWith("1815"))
        assertFailsWith<IllegalArgumentException> { LunaControl.exposureBias(5.0) }
        assertFailsWith<IllegalArgumentException> { LunaControl.videoExposure(2, shutterSeconds = 0.0) }
        assertFailsWith<IllegalArgumentException> { LunaControl.whiteBalanceKelvin(1500) }
        assertFailsWith<IllegalArgumentException> { LunaControl.tapFocus(1.5, 0.0) }
    }

    /** Negative EV is zigzag sint32, read back through the reply parser. */
    @Test fun exposureRoundTripsThroughTheReplyParser() {
        fun nested(request: LunaControl.Request) = LunaPhotographySettings.parse(LunaWire.blob(2, LunaWire.bytes(request.body, 2)))
        assertEquals(-10, nested(LunaControl.exposureBias(-1.0)).exposureBiasTenths)
        assertEquals(-3, nested(LunaControl.exposureBias(-0.3)).exposureBiasTenths)
        assertEquals(3, nested(LunaControl.exposureBias(1 / 3.0)).exposureBiasTenths)
        val manual = nested(LunaControl.videoExposure(3, iso = 400, shutterSeconds = 0.01))
        assertEquals(LunaExposure(3, 400, 0.01), manual.videoExposure)
        assertNull(manual.isoTopLimit)
        assertEquals(15.0, nested(LunaControl.zoom(15.0)).zoom)
        assertEquals(listOf(0, 1, 2, 3), listOf(null to null, 400L to null, null to 0.02, 400L to 0.02).map { (i, s) -> LunaControl.exposureProgram(i, s) })
    }

    /** Swift `testShootingModesMatchOfficialDeviceSets`. */
    @Test fun shootingModesMatchOfficialDeviceSets() {
        val cases = mapOf(
            LunaShootingMode.VIDEO to "0a0129120c08012880f702d00201900503",
            LunaShootingMode.TIMELAPSE to "0a0129120f08012880f702c80202d00201900503",
            LunaShootingMode.TIME_SHIFT to "0a0129120f08012880f702c80204d00201900503",
            LunaShootingMode.SLOW_MOTION to "0a0129120f08012880f702c80209d00201900503",
            LunaShootingMode.PURE_VIDEO to "0a0129120f08012880f702c8020bd00201900503",
            LunaShootingMode.PHOTO to "0a0128120c08012880f702d00201900503",
            LunaShootingMode.PANO to "0a0128120f08012880f702c00208d00201900503",
        )
        for ((mode, expected) in cases) {
            assertEquals(LunaControl.SET_OPTIONS, mode.request().code)
            assertEquals(expected, hex(mode.request().body), mode.name)
        }
        assertEquals(12, LunaShootingMode.TIME_SHIFT.functionMode)
        assertEquals(67, LunaShootingMode.PANO.functionMode)
        assertEquals(LunaShootingMode.SLOW_MOTION, LunaShootingMode.from(100, 9))
        assertEquals(LunaShootingMode.PHOTO, LunaShootingMode.from(0, 100))
        assertNull(LunaShootingMode.from(100, 7))
    }

    /** Swift `testFirmware1115CaptureBodiesPerMode`. */
    @Test fun firmware1115CaptureBodiesPerMode() {
        val stop = "0a196a0230019a0100aa0100ba0100d20100e20200ba0400820a00"
        assertEquals("0801", hex(LunaControl.startCapture(LunaShootingMode.VIDEO).body))
        assertEquals(4, LunaControl.startCapture(LunaShootingMode.VIDEO).code)
        assertEquals("0801", hex(LunaControl.startCapture(LunaShootingMode.PURE_VIDEO).body))
        assertEquals("0804", hex(LunaControl.startCapture(LunaShootingMode.TIME_SHIFT).body))
        assertEquals("0809", hex(LunaControl.startCapture(LunaShootingMode.SLOW_MOTION).body))
        assertEquals(stop + "1001", hex(LunaControl.stopCapture(LunaShootingMode.VIDEO).body))
        assertEquals(stop + "1009", hex(LunaControl.stopCapture(LunaShootingMode.SLOW_MOTION).body))
        assertEquals(5, LunaControl.stopCapture(LunaShootingMode.VIDEO).code)
        val lapseStart = LunaControl.startCapture(LunaShootingMode.TIMELAPSE)
        assertEquals(22, lapseStart.code)
        assertEquals("0801", hex(lapseStart.body))
        val lapseStop = LunaControl.stopCapture(LunaShootingMode.TIMELAPSE)
        assertEquals(23, lapseStop.code)
        assertEquals("080112196a0230019a0100aa0100ba0100d20100e20200ba0400820a00", hex(lapseStop.body))
    }

    /** Swift `testFirmware1115PhotoModeWrites`. */
    @Test fun firmware1115PhotoModeWrites() {
        val photo = LunaControl.FUNCTION_MODE_PHOTO
        fun types(request: LunaControl.Request) = hex(LunaWire.bytes(request.body, 1))
        val still = LunaControl.videoExposure(2, shutterSeconds = 1.0 / 8000, functionMode = photo)
        assertEquals("14151864", types(still))
        assertEquals("151864", types(LunaControl.videoExposure(2, shutterSeconds = 1.0 / 8000)))
        // Field 20 carries the same exposure message as 21.
        val nested = LunaWire.bytes(still.body, 2)
        assertContentEquals(LunaWire.bytes(nested, 21), LunaWire.bytes(nested, 20))
        assertEquals("074d", types(LunaControl.exposureBias(1.0, functionMode = photo)))
        assertEquals(1L, LunaWire.number(LunaWire.bytes(LunaControl.exposureBias(1.0, functionMode = photo).body, 2), 77))
        assertEquals("1f3f23", types(LunaControl.recordResolution(27)))
        assertEquals(1L, LunaWire.number(LunaWire.bytes(LunaControl.recordResolution(27).body, 2), 35))
        assertEquals(30.0, LunaVideoResolution.of(443)?.framesPerSecond)
        assertEquals(2688, LunaVideoResolution.of(444)?.height)
        assertTrue(listOf(443L, 444L, 119L, 120L, 121L, 446L, 447L, 448L).all { it in LunaReadout.videoFormatValues })
    }

    /** Swift `testGimbalTrackingCaptureAndMediaRequests` and `testOfficialStatusPollsArePacked`. */
    @Test fun captureMediaAndStatusRequests() {
        assertEquals("0805", hex(LunaControl.takePicture(5).body))
        assertEquals("", hex(LunaControl.takePicture().body))
        assertEquals(3, LunaControl.takePicture().code)
        assertEquals("", hex(LunaControl.stopLive.body))
        val jpg = "/storage_internal/DCIM/Camera01/IMG_20260916_133503_003.jpg"
        assertEquals("0a3b2f73746f726167655f696e7465726e616c2f4443494d2f43616d65726130312f494d475f32303236303931365f3133333530335f3030332e6a7067", hex(LunaControl.deleteFiles(jpg).body))
        assertEquals(12, LunaControl.deleteFiles(jpg).code)
        assertEquals(hex(LunaWire.blob(1, jpg.toByteArray())) + "1002", hex(LunaControl.fileExtra(jpg, extraType = 2).body))
        assertEquals("080218ffffffff072002", hex(LunaControl.fileList().body))
        assertEquals("080218ffffffff072003", hex(LunaControl.fileList(location = 3).body))
        assertEquals("080618ffffffff072002", hex(LunaControl.fileList(mediaType = 6).body))
        assertEquals("0802", hex(LunaControl.fileInfoList(2).body))
        assertEquals(38, LunaControl.fileInfoList().code)
        assertEquals("", hex(LunaControl.fileInfoList().body))
        assertEquals("0a050b1455b401", hex(LunaControl.statusRequest.body))
        assertEquals("0a0d2928417c8401528701a901ad01", hex(LunaControl.shootingModeRequest.body))
        val fullGet = "0a381f15070d271848531217212b221c262a12122e474735361d373a253b3f3e06493d4b4c464e4f51565758595a5b6a6d23645b5c5d65030468100c"
        val types = LunaWire.schemes(h(fullGet).copyOfRange(0, h(fullGet).size - 2)).map { it.toInt() }
        assertEquals(fullGet, hex(LunaControl.getPhotographyOptions(types, functionMode = 12, packed = true).body))
    }
}
