package com.opencapture.opencine.insta360.luna

import com.opencapture.opencine.insta360.shell.CameraColorProfile
import com.opencapture.opencine.insta360.shell.CameraFocusMode
import com.opencapture.opencine.insta360.shell.CameraGimbalMode
import com.opencapture.opencine.insta360.shell.CameraGimbalSpeed
import com.opencapture.opencine.insta360.shell.CameraShootingMode
import kotlin.test.*
import org.junit.Test

/** Replies copied from Adapters/Insta360Protocol `LunaStatusDecodeTests` (captured official-app takes). */
class LunaStatusTest {
    private fun h(value: String) = LunaWire.hex(value.filterNot(Char::isWhitespace))

    private val videoReply = h("""
        081f08150807080d0827081808480853081208170821082b0822081c0826082a08120812082e0847084708350836081d0837083a08
        25083b083f083e08060849083d084b084c0846084e084f08510856085708580859085a085b086a086d08230864085b085c085d0865
        080308040868129e0130013800900100aa010d08001000190000000000000000c00180e7ffff0fe8013cf801d301880200900201980202
        a80200b80200f00201a903000000000000f03fb00300d00301d80300e80300f00300f80300b80400c00400b00501ba05040800100
        0c80500d2050c0d0000000015000000002000da05080802100218032002e20512080010001800200028003000380040004800e80503
        a00601c00603
        """)

    @Test fun nativeRecordingReadoutWithdrawsAnExplicitMissingOptionAndPreservesPartialReplies() {
        val known = LunaPhotographySettings(types = listOf(31, 35), recordResolution = 48L, colorMode = 2L)
        val partial = known.merge(LunaPhotographySettings(types = listOf(39), whiteBalanceKelvin = 5600L))
        assertEquals(48L, partial.recordResolution)
        assertEquals(2L, partial.colorMode)
        val formatMissing = partial.merge(LunaPhotographySettings(types = listOf(31)))
        assertNull(LunaReadout.readout(formatMissing, null, null).recordFormat)
        assertEquals(CameraColorProfile.LOG, LunaReadout.readout(formatMissing, null, null).color)
        val profileMissing = partial.merge(LunaPhotographySettings(types = listOf(35)))
        assertNull(LunaReadout.readout(profileMissing, null, null).color)
        assertEquals(48L, LunaReadout.readout(profileMissing, null, null).recordFormat?.id)
    }

    @Test fun videoModePhotographyReply() {
        val s = LunaPhotographySettings.parse(videoReply)
        assertEquals(31, s.types.first())
        assertEquals(1L, s.sharpness)
        assertEquals(0, s.exposureBiasTenths)
        assertEquals(0L, s.filter)
        assertEquals(LunaExposure(0, 0, 0.0), s.videoExposure)
        assertEquals(LunaControl.OFFICIAL_ISO_TOP_LIMIT, s.isoTopLimit)
        assertEquals(211L, s.recordResolution)
        assertEquals(7680, s.videoResolution?.width)
        assertEquals("16:9", s.videoResolution?.aspectLabel)
        assertEquals(0L, s.fov)
        assertEquals(2L, s.colorMode)
        assertEquals(0L, s.whiteBalanceKelvin)
        assertEquals(1.0, s.zoom)
        assertEquals(false, s.iLog)
        assertNull(s.colorRecovery)
        assertEquals(LunaGimbalOptions(2, 2, 3, 2), s.gimbal)
        assertEquals(false, s.gimbalStatus?.stall)
        assertEquals(3L, s.afMode)
        assertEquals(true, s.faceMetering)
        assertEquals(1L, s.iq3AMode)
        assertEquals(3L, s.filterStrength)
        assertNull(s.functionMode)
    }

    @Test fun photoModeReplyRemainingTimeAndSetReply() {
        val photo = LunaPhotographySettings.parse(h("""
            081a08140807082708180819081b082e083508360822083b083f084d0847085508590846085b08230864085d0865080308040828126538
            00a2010d08001000190000000000000000c00180e7ffff0fc80100d00100d80101900201980202b80200c0021ff00201a90300000000
            0000f03fb00300d80300f80300b80400e80401aa050408001001c80500da05080802100218032002e80503a00601
            """))
        assertEquals(0L, photo.stillExposure?.program)
        assertEquals(2L, photo.colorMode)
        assertEquals(31L, photo.photoResolution)
        assertEquals(7680, LunaPhotoSize.of(31)?.width)
        assertEquals("4:3", LunaPhotoSize.of(34)?.aspectLabel)
        assertNull(photo.videoExposure)
        val remaining = LunaPhotographySettings.parse(h("0863120f9a060508b91710029a060408001003"))
        assertEquals(listOf(3001L to 2L, 0L to 3L), remaining.remainingRecordTime)
        assertEquals(listOf(21, 24, 100), LunaPhotographySettings.parse(h("081508180864")).types)
    }

    /** Option 99 rides its own poll: a reply that carries it replaces the last report, others keep it. */
    @Test fun remainingTimeMergesOnlyFromAReplyThatCarriesIt() {
        val first = LunaPhotographySettings.parse(h("0863120f9a060508b91710029a060408001003"))
        val settingsPoll = LunaPhotographySettings.parse(h("081508180864"))
        assertEquals(listOf(3001L to 2L, 0L to 3L), first.merge(settingsPoll).remainingRecordTime)
        assertEquals(listOf(3001L to 2L, 0L to 3L), settingsPoll.merge(first).remainingRecordTime)
        val later = LunaPhotographySettings.parse(h("086312079a060408001003"))
        assertEquals(listOf(0L to 3L), first.merge(later).remainingRecordTime)
    }

    @Test fun resolutionTable() {
        val expected = mapOf(
            24L to listOf(3840, 2160, 30, "16:9"), 43L to listOf(1280, 720, 30, "16:9"), 48L to listOf(3840, 2160, 25, "16:9"),
            52L to listOf(1920, 1080, 25, "16:9"), 211L to listOf(7680, 4320, 25, "16:9"), 214L to listOf(3840, 2160, 120, "16:9"),
            454L to listOf(1728, 3072, 25, "9:16"), 31L to listOf(4000, 3000, 30, "4:3"), 1L to listOf(2560, 1280, 30, "2:1"),
            // II-089: the aspect tab names the 2.35:1 sizes as the resolution readout does, not 21:9.
            110L to listOf(3840, 1634, 25, "2.35:1"), 408L to listOf(2688, 1136, 25, "2.35:1"),
        )
        for ((raw, e) in expected) {
            val r = assertNotNull(LunaVideoResolution.of(raw))
            assertEquals(listOf(r.width, r.height, r.framesPerSecond.toInt(), r.aspectLabel), e, "$raw")
        }
        assertEquals(478, LunaVideoResolution.index.size) // pinned schema + 443/444 from fw 1.1.15
        assertNull(LunaVideoResolution.of(503))
        assertEquals(48L, LunaVideoResolution.rawValue(3840, 2160, 25.0))
        assertEquals(454L, LunaVideoResolution.rawValue(1728, 3072, 25.0))
    }

    @Test fun deviceStatusBatteryStorageAndMode() {
        val reconnect = LunaDeviceStatus.parse(h("080b0814085508b40112265a06080010102000a201120800108080b0d9bb01188080f88bbc012002a20b06080010421801"))
        assertEquals(16L, reconnect.battery?.percent)
        assertEquals(false, reconnect.battery?.isCharging)
        assertEquals(50_384_863_232L, reconnect.storage?.freeBytes)
        assertEquals(50_490_900_480L, reconnect.storage?.totalBytes)
        assertEquals(2L, reconnect.storage?.location)
        assertEquals(true, reconnect.storage?.isUsable)
        assertEquals(66L, reconnect.screenBattery?.percent)
        assertEquals(1L, reconnect.screenConnection)
        val charging = LunaDeviceStatus.parse(h("080b0814085508b40112265a06080110642000a201120800108080b0d9bb01188080f88bbc012002a20b06080110631801"))
        assertEquals(LunaBattery.parse(h("080110642000")), charging.battery)
        assertEquals(true, charging.battery?.isCharging)
        assertEquals(99L, charging.screenBattery?.percent)
        val list = LunaDeviceStatus.parse(h("""
            080b0814085508440861085208b00108b10112495a06080010102000a201120800108080b0d9bb01188080f88bbc012002a00400900503
            880601820b120800108080b0d9bb01188080f88bbc012002820b080801100018002003880b02
            """))
        assertEquals(2, list.storageList.size)
        assertEquals(1L, list.storageList[1].cardState)
        assertEquals(3L, list.storageList[1].location)
        assertFalse(list.storageList[1].isUsable)
        assertEquals(2L, list.cardLocationLastUpdate)
        val video = LunaDeviceStatus.parse(h("082908280841087c08840108520887011221c00264c80200880401900503e2070c080010001800200028003000a00801b80800"))
        assertEquals(LunaShootingMode.VIDEO, video.shootingMode)
        val photo = LunaDeviceStatus.parse(h("082908280841087c08840108520887011221c00200c80264880401900503e2070c080010001800200028003000a00801b80800"))
        assertEquals(LunaShootingMode.PHOTO, photo.shootingMode)
        // A battery poll does not forget the mode the probe read.
        assertEquals(LunaShootingMode.PHOTO, photo.merge(reconnect).shootingMode)
        assertEquals(16L, photo.merge(reconnect).battery?.percent)
    }

    @Test fun captureStatus() {
        val idle = LunaCaptureStatus.fromResponse(h("0a06080010005000"))
        assertTrue(idle.isIdle); assertFalse(idle.isRecording)
        val recording = LunaCaptureStatus.fromResponse(h("0a06080110005005"))
        assertTrue(recording.isRecording); assertEquals(5L, recording.submode); assertEquals(0L, recording.captureSeconds)
        val photo = LunaCaptureStatus.fromResponse(h("0a06080410005000"))
        assertFalse(photo.isRecording); assertFalse(photo.isIdle)
        assertTrue(LunaCaptureStatus.fromResponse(ByteArray(0)).isIdle)
    }

    @Test fun notifications() {
        fun n(code: Int, body: String) = LunaNotification.parse(code, h(body))
        assertEquals(LunaNotification.Storage(0, 2), n(8198, "08001002"))
        val timeShift = n(8275, "086410041803") as LunaNotification.SubMode
        assertEquals(LunaShootingMode.TIME_SHIFT, timeShift.shootingMode)
        assertEquals(LunaShootingMode.PANO, (n(8275, "080810641801") as LunaNotification.SubMode).shootingMode)
        assertEquals(LunaNotification.Tracking(4, 2), n(8315, "0804100218052000"))
        val change = (n(8293, "081f1204f801c6031807") as LunaNotification.PhotographyChanged).settings
        assertEquals(listOf(31), change.types); assertEquals(454L, change.recordResolution); assertEquals(7, change.functionMode)
        val filter = (n(8334, "081208681206900101c006021807") as LunaNotification.PhotographyChanged).settings
        assertEquals(listOf(18, 104), filter.types); assertEquals(1L, filter.filter); assertEquals(2L, filter.filterStrength)
        val pano = (n(8208, "08203800880113900105") as LunaNotification.Capture).status
        assertEquals(32L, pano.state); assertEquals(19L, pano.panoFramesTotal); assertEquals(5L, pano.panoFramesDone)
        val saving = (n(8208, "080110003802") as LunaNotification.Capture).status
        assertTrue(saving.isRecording); assertEquals(2L, saving.submode)
        assertEquals(LunaNotification.Battery(LunaBattery.parse(h("08011032"))), n(8195, "0a0408011032"))
        val gimbal = (n(8302, "080110011800200028003000380040004800") as LunaNotification.Gimbal).status
        assertTrue(gimbal.rollLimit && gimbal.pitchLimit); assertFalse(gimbal.yawLimit)
        assertEquals(LunaNotification.Unknown(8199), n(8199, "0801"))
    }

    @Test fun mediaListInfoAndThumbnail() {
        val (uris, total) = LunaMediaFile.list(h("""
            0a3b2f73746f726167655f696e7465726e616c2f4443494d2f43616d65726130312f4c52565f32303236303931365f3132343232395f
            3030322e6c72760a3b2f73746f726167655f696e7465726e616c2f4443494d2f43616d65726130312f5649445f32303236303931365f
            3132343232395f3030322e6d70340a3b2f73746f726167655f696e7465726e616c2f4443494d2f43616d65726130312f494d475f3230
            3236303931365f3133333530335f3030332e6a70670a3b2f73746f726167655f696e7465726e616c2f4443494d2f43616d6572613031
            2f494d475f32303236303931365f3132343231395f3030312e6a70671004
            """))
        assertEquals(4L, total)
        assertEquals("/storage_internal/DCIM/Camera01/VID_20260916_124229_002.mp4", uris[1])
        assertEquals(emptyList(), LunaMediaFile.list(h("1000")).first)
        val video = LunaMediaFile(uris[1])
        assertEquals(uris[0], video.proxyUri)
        assertTrue(LunaMediaFile(uris[0]).isProxy)
        assertNull(LunaMediaFile(uris[2]).proxyUri)

        val path = h("0a3b2f73746f726167655f696e7465726e616c2f4443494d2f43616d65726130312f5649445f32303236303931365f3132343232395f3030322e6d7034")
        val metadata = h("""
            38c5b4d5e5d5cd0448ecf3f37d50139a010608803c10e021a00119b201087374616e64617264d20132080010001a2a2f4443494d2f4361
            6d65726130312f5649445f32303236303931365f3132343232395f3030322e6d70342000e805b89901a00802
            """)
        val files = LunaMediaFile.infoList(LunaWire.blob(1, path + LunaWire.blob(2, metadata)))
        assertEquals(video.uri, files.single().uri)
        val m = assertNotNull(files.single().metadata)
        assertEquals(20_260_916_124_229L, m.creationStamp)
        assertEquals(264_042_988L, m.fileSize)
        assertEquals(19L, m.durationSeconds)
        assertEquals(19_640L, m.durationMilliseconds)
        assertEquals(7680 to 4320, m.width to m.height)
        assertEquals(25L, m.frameRate)
        assertEquals("standard", m.gammaMode)
        assertEquals(0L, m.subMediaType)
        assertEquals(2L, m.codec)
        val item = LunaReadout.mediaItem(files.single())
        assertEquals(20, item.durationSeconds) // 19 640 ms rounds to 20 s, as on iOS
        assertEquals(uris[0], item.proxyPath)
        assertEquals(264_042_988L, item.sizeBytes)
        assertEquals("standard", item.gamma)

        // Real 40-byte header of a 1280x720 video thumbnail; pixels zero-filled.
        val header = h("0100000028181500010000000100000000050000d0020000" + "00".repeat(16))
        val thumbnail = LunaThumbnail.parse(header + ByteArray(1280 * 720 * 3 / 2))
        assertEquals(1280 to 720, thumbnail.width to thumbnail.height)
        assertEquals(1_382_400, thumbnail.nv12.size)
        assertFails { LunaThumbnail.parse(header + ByteArray(10)) }
        assertFails { LunaThumbnail.parse(metadata) }
        // The camera sends this reply as content type 1 (raw), not 2 (protobuf).
        val reply = LunaWire.request(200, 24, header + ByteArray(1280 * 720 * 3 / 2)).also { it[2] = 1 }
        val message = LunaWire.Parser().feed(LunaWire.encode(1, reply)).single().message(null)!!
        assertEquals(1280, LunaThumbnail.parse(message.body).width)
        val unknownType = LunaWire.request(200, 24, ByteArray(0)).also { it[2] = 7 }
        assertFails { LunaWire.Parser().feed(LunaWire.encode(1, unknownType)).single().message(null) }
    }

    @Test fun thumbnailDecodesBt709LimitedRange() {
        fun pixel(y: Int, cb: Int, cr: Int) = LunaThumbnail(2, 2, byteArrayOf(y.toByte(), y.toByte(), y.toByte(), y.toByte(), cb.toByte(), cr.toByte())).argb()[0]
        assertEquals(0xFF000000.toInt(), pixel(16, 128, 128))
        assertEquals(0xFFFFFFFF.toInt(), pixel(235, 128, 128))
        // BT.709 75% red: Y 51, Cb 109, Cr 212 decodes to about (191, 0, 0); BT.601 would tint it.
        val red = pixel(51, 109, 212)
        assertTrue((red shr 16 and 255) in 188..194 && (red shr 8 and 255) < 4 && (red and 255) < 4, Integer.toHexString(red))
    }

    @Test fun readoutMapsSettingsDeviceAndCapture() {
        val settings = LunaPhotographySettings.parse(videoReply)
        val device = LunaDeviceStatus.parse(h("082908280841087c08840108520887011221c00264c80200880401900503e2070c080010001800200028003000a00801b80800"))
            .merge(LunaDeviceStatus.parse(h("080b0814085508b40112265a06080110642000a201120800108080b0d9bb01188080f88bbc012002a20b06080110631801")))
        val r = LunaReadout.readout(settings, device, LunaCaptureStatus.fromResponse(h("0a06080110005005")))
        assertEquals(100, r.batteryPercent); assertEquals(true, r.charging)
        assertEquals(50_490_900_480L, r.storages.single().totalBytes)
        assertEquals(CameraShootingMode.VIDEO, r.shootingMode)
        assertEquals(true, r.recording)
        assertEquals(CameraColorProfile.LOG, r.color)
        assertEquals(0, r.whiteBalanceKelvin)
        assertEquals(211L, r.recordFormat?.id); assertEquals(7680, r.recordFormat?.width); assertEquals(25.0, r.recordFormat?.fps)
        assertEquals(LunaReadout.videoFormatValues.size, r.recordFormats.size)
        assertEquals(CameraGimbalMode.ROLL_LOCK, r.gimbalMode); assertEquals(CameraGimbalSpeed.MEDIUM, r.gimbalSpeed)
        assertEquals(0, r.videoExposure?.program)
        assertEquals(CameraFocusMode.CONTINUOUS, r.focusMode)
        assertEquals(true, r.faceMetering)
        // Before the first settings read the picker has nothing to offer.
        assertTrue(LunaReadout.readout(null, device, null).recordFormats.isEmpty())
        // Every neutral enum value maps back to the wire number it came from.
        with(LunaReadout) {
            for ((wire, profile) in colors) assertEquals(wire, colors.key(profile))
            for ((wire, mode) in gimbalModes) assertEquals(wire, gimbalModes.key(mode))
            for ((luna, mode) in shootingModes) assertEquals(luna, shootingModes.key(mode))
        }
    }

    /** ExtraMetadata 61 from a fw 1.1.15 clip; Wind Reduction observed, the others schema-inferred. */
    @Test
    fun clipAudioMode() {
        assertEquals(LunaAudioMode.WIND_REDUCTION, LunaFileMetadata.parse(h("e80314")).audioMode)
        assertEquals(LunaAudioMode.VOICE_ENHANCEMENT, LunaFileMetadata.parse(h("e80315")).audioMode)
        assertEquals(LunaAudioMode.ORIGINAL_AUDIO, LunaFileMetadata.parse(h("e80318")).audioMode)
        val other = LunaFileMetadata.parse(h("e80302"))
        assertEquals(2L, other.audioModeRaw)
        assertNull(other.audioMode)
        assertNull(LunaFileMetadata.parse(ByteArray(0)).audioModeRaw)
        assertEquals(listOf("Wind Reduction", "Voice Enhancement", "Original Audio"), LunaAudioMode.entries.map { it.label })
    }
}
