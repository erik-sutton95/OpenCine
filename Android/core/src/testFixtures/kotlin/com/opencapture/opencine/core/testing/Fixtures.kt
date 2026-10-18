package com.opencapture.opencine.core.testing

import com.opencapture.opencine.core.AudioLevels
import com.opencapture.opencine.core.Availability
import com.opencapture.opencine.core.CameraSessionID
import com.opencapture.opencine.core.CameraTimecode
import com.opencapture.opencine.core.CameraTimecodeReading
import com.opencapture.opencine.core.CaptureMode
import com.opencapture.opencine.core.CaptureMode.Role.PHOTO
import com.opencapture.opencine.core.CaptureMode.Role.VIDEO
import com.opencapture.opencine.core.ControlAuthority
import com.opencapture.opencine.core.FocusMode
import com.opencapture.opencine.core.ISOValue
import com.opencapture.opencine.core.IntegrationID
import com.opencapture.opencine.core.MonitorEntryDescriptor
import com.opencapture.opencine.core.ObservationOrigin.CLOCK_DERIVED
import com.opencapture.opencine.core.PictureHealth
import com.opencapture.opencine.core.PictureSourceDescriptor
import com.opencapture.opencine.core.Rational
import com.opencapture.opencine.core.SettingAccess
import com.opencapture.opencine.core.SettingDescriptor
import com.opencapture.opencine.core.SettingDomain
import com.opencapture.opencine.core.SettingKey.APERTURE
import com.opencapture.opencine.core.SettingKey.EXPOSURE_COMPENSATION
import com.opencapture.opencine.core.SettingKey.FOCUS_MODE
import com.opencapture.opencine.core.SettingKey.FOCUS_POINT
import com.opencapture.opencine.core.SettingKey.FRAME_RATE
import com.opencapture.opencine.core.SettingKey.ISO
import com.opencapture.opencine.core.SettingKey.RECORDING
import com.opencapture.opencine.core.SettingKey.SHUTTER
import com.opencapture.opencine.core.SettingKey.WHITE_BALANCE
import com.opencapture.opencine.core.SettingKey.ZOOM
import com.opencapture.opencine.core.SettingSemantics
import com.opencapture.opencine.core.SettingValue
import com.opencapture.opencine.core.ShutterValue
import com.opencapture.opencine.core.SupportStatus.SUPPORTED
import com.opencapture.opencine.core.SupportStatus.UNSUPPORTED
import com.opencapture.opencine.core.TelemetrySource
import com.opencapture.opencine.core.TimecodeCapability
import com.opencapture.opencine.core.TimecodePrecision
import com.opencapture.opencine.core.UnavailableReason
import com.opencapture.opencine.core.WhiteBalanceValue
import com.opencapture.opencine.core.testing.FakeCameraBehavior.RecordWire
import kotlin.time.Duration.Companion.milliseconds
import kotlin.time.Duration.Companion.seconds

private fun <T> choices(values: List<T>, make: (T) -> SettingValue) = SettingDomain(values.map(make))

private fun settings(vararg values: SettingValue) = values.associateBy { it.key }

private fun isoValue(value: Int) = SettingValue.Iso(ISOValue.Manual(value))

private fun durationValue(denominator: Int) = SettingValue.Shutter(ShutterValue.Duration(Rational(1, denominator)))

private fun kelvinValue(value: Int) = SettingValue.WhiteBalance(WhiteBalanceValue.Kelvin(value))

private fun fpsValue(rate: Int) = SettingValue.FrameRate(Rational(rate))

private val shutterAuto = SettingValue.Shutter(ShutterValue.Auto)
private val wbAuto = SettingValue.WhiteBalance(WhiteBalanceValue.Auto)
private val zeroEV = SettingValue.ExposureCompensation(Rational(0))
private val thirds = (-9..9).map { SettingValue.ExposureCompensation(Rational(it, 3)) }

/**
 * DJI-like: raw status mode bytes map to common modes whose domains differ, recording is a
 * toggle on the wire, every change is confirmed by the next status push 0.5 s later, and video
 * modes report timecode and live audio levels (photo mode reports neither).
 */
public fun FakeCameraSession.Companion.djiLike(): FakeCameraSession {
    val video = CaptureMode(VIDEO, "test.dji-like.video", "Video")
    val slow = CaptureMode(VIDEO, "test.dji-like.slow-motion", "Slow Motion")
    val photo = CaptureMode(PHOTO, "test.dji-like.photo", "Photo")
    val iso = SettingDescriptor(ISO, domain = choices(listOf(100, 200, 400, 800, 1600, 3200), ::isoValue))
    val ev = SettingDescriptor(EXPOSURE_COMPENSATION, domain = SettingDomain(thirds))
    val wb = SettingDescriptor(WHITE_BALANCE, domain = SettingDomain(listOf(wbAuto), 2000.0..10000.0, 100.0))
    val zoom = SettingDescriptor(ZOOM, domain = SettingDomain(range = 1.0..4.0, step = 0.1))
    fun shutter(vararg denominators: Int) =
        SettingDescriptor(SHUTTER, domain = SettingDomain(listOf(shutterAuto) + denominators.map(::durationValue)))
    fun fps(vararg rates: Int) = SettingDescriptor(FRAME_RATE, domain = choices(rates.toList(), ::fpsValue))
    val modes = mapOf(
        0x01 to FakeMode(
            video,
            listOf(iso, shutter(50, 100, 200, 400), ev, wb, fps(24, 25, 30, 48, 50, 60), zoom, SettingDescriptor(RECORDING)),
            unsupported = setOf(APERTURE), timecodeCapability = TimecodeCapability.supported(TimecodePrecision.Seconds), audioLevels = SUPPORTED,
        ),
        0x02 to FakeMode(
            slow,
            listOf(iso, shutter(250, 500, 1000), ev, wb, fps(120, 240), zoom, SettingDescriptor(RECORDING)),
            unsupported = setOf(APERTURE), timecodeCapability = TimecodeCapability.supported(TimecodePrecision.Seconds), audioLevels = SUPPORTED,
        ),
        0x05 to FakeMode(
            photo,
            listOf(
                iso, shutter(50, 100, 200, 400), ev, wb, zoom,
                SettingDescriptor(RECORDING, availability = Availability.Unavailable(UnavailableReason.Mode)),
            ),
            unsupported = setOf(APERTURE, FRAME_RATE), timecodeCapability = TimecodeCapability.unsupported, audioLevels = UNSUPPORTED,
        ),
    )
    return FakeCameraSession(
        FakeCameraBehavior(
            IntegrationID("test.dji-like"), reportDelay = 500.milliseconds, observationTimeout = 2.seconds,
            recordWire = RecordWire.TOGGLE, modes = modes,
        ),
        FakeDevice(
            rawMode = 0x01,
            settings = settings(isoValue(800), durationValue(50), zeroEV, kelvinValue(5600), fpsValue(24), SettingValue.Zoom(1.0)),
            batteryPercent = 76,
            freeBytes = 64_000_000_000,
            timecode = CameraTimecode(1, 2, 3, 4),
            audioLevels = AudioLevels(AudioLevels.Channel(-20.0, -12.0), AudioLevels.Channel(-18.0, -10.0)),
        ),
    )
}

/**
 * Nikon-like: shutter in native angle mode, explicit record commands that need the camera's
 * own live view, an acknowledgement-only focus point, control that does not depend on which
 * picture is displayed, and audio levels without held peaks.
 */
public fun FakeCameraSession.Companion.nikonLike(): FakeCameraSession {
    val iso = choices(listOf(100, 200, 400, 800, 1600, 3200, 6400), ::isoValue).let {
        it.copy(choices = it.choices + SettingValue.Iso(ISOValue.AutoLimited(6400)))
    }
    val presets = listOf("daylight", "cloudy", "tungsten").map { SettingValue.WhiteBalance(WhiteBalanceValue.Preset(it)) }
    val wb = SettingDomain(listOf(wbAuto) + presets, 2500.0..10000.0, 10.0)
    val movie = FakeMode(
        CaptureMode(VIDEO, "test.nikon-like.movie", "Movie"),
        listOf(
            SettingDescriptor(ISO, domain = iso),
            SettingDescriptor(
                SHUTTER,
                domain = choices(listOf(45.0, 90.0, 180.0, 270.0, 360.0)) { SettingValue.Shutter(ShutterValue.Angle(it)) },
            ),
            SettingDescriptor(APERTURE, domain = choices(listOf(2.8, 4.0, 5.6, 8.0, 11.0)) { SettingValue.Aperture(it) }),
            SettingDescriptor(EXPOSURE_COMPENSATION, domain = SettingDomain(thirds)),
            SettingDescriptor(WHITE_BALANCE, domain = wb),
            SettingDescriptor(
                FRAME_RATE,
                domain = SettingDomain(
                    listOf(Rational(24000, 1001), Rational(24), Rational(25), Rational(30000, 1001), Rational(50))
                        .map { SettingValue.FrameRate(it) },
                ),
            ),
            SettingDescriptor(
                FOCUS_MODE,
                domain = choices(listOf(FocusMode.SINGLE, FocusMode.CONTINUOUS, FocusMode.MANUAL)) { SettingValue.FocusMode(it) },
            ),
            SettingDescriptor(
                FOCUS_POINT,
                semantics = SettingSemantics(confirmation = SettingSemantics.Confirmation.ACKNOWLEDGEMENT_ONLY),
            ),
            SettingDescriptor(RECORDING),
        ),
        unsupported = setOf(ZOOM), audioLevels = SUPPORTED,
        timecodeCapability = TimecodeCapability.supported(TimecodePrecision.Frames(Rational(24), dropFrame = false)),
    )
    return FakeCameraSession(
        FakeCameraBehavior(
            IntegrationID("test.nikon-like"), reportDelay = 200.milliseconds, observationTimeout = 3.seconds,
            recordWire = RecordWire.EXPLICIT, recordNeedsLiveView = true, modes = mapOf(0x01 to movie),
        ),
        FakeDevice(
            rawMode = 0x01,
            settings = settings(
                isoValue(400), SettingValue.Shutter(ShutterValue.Angle(180.0)), SettingValue.Aperture(4.0), zeroEV,
                SettingValue.WhiteBalance(WhiteBalanceValue.Preset("daylight")), fpsValue(24),
                SettingValue.FocusMode(FocusMode.CONTINUOUS),
            ),
            batteryPercent = 90,
            freeBytes = 128_000_000_000,
            timecode = CameraTimecode(10, 0, 0, 0, dropFrame = false),
            audioLevels = AudioLevels(AudioLevels.Channel(-30.0), AudioLevels.Channel(-31.0)),
        ),
    )
}

/**
 * Luna-like: settings settle for 2.5 s before readback, an accepted write may not stick,
 * the fixed aperture is read-only, storage is never reported, timecode is time of day derived
 * from a clock, and there are no live audio levels.
 */
public fun FakeCameraSession.Companion.lunaLike(): FakeCameraSession {
    val video = FakeMode(
        CaptureMode(VIDEO, "test.luna-like.video", "Video"),
        listOf(
            SettingDescriptor(
                ISO,
                domain = SettingDomain(listOf(SettingValue.Iso(ISOValue.Auto)) + listOf(100, 200, 400, 800, 1600, 3200, 6400).map(::isoValue)),
            ),
            SettingDescriptor(SHUTTER, domain = SettingDomain(listOf(shutterAuto) + listOf(30, 60, 120, 240).map(::durationValue))),
            SettingDescriptor(APERTURE, access = SettingAccess.READ_ONLY, domain = SettingDomain(listOf(SettingValue.Aperture(2.0)))),
            SettingDescriptor(
                EXPOSURE_COMPENSATION,
                domain = SettingDomain((-6..6).map { SettingValue.ExposureCompensation(Rational(it, 3)) }),
            ),
            SettingDescriptor(WHITE_BALANCE, domain = SettingDomain(listOf(wbAuto), 2700.0..6500.0, 100.0)),
            SettingDescriptor(FRAME_RATE, domain = choices(listOf(24, 30, 60), ::fpsValue)),
            SettingDescriptor(ZOOM, domain = SettingDomain(range = 1.0..2.0, step = 0.1)),
            SettingDescriptor(
                FOCUS_MODE,
                domain = choices(listOf(FocusMode.SINGLE, FocusMode.CONTINUOUS)) { SettingValue.FocusMode(it) },
            ),
            SettingDescriptor(RECORDING),
        ),
        unsupported = emptySet(), timecodeCapability = TimecodeCapability.supported(TimecodePrecision.Seconds), audioLevels = UNSUPPORTED,
    )
    return FakeCameraSession(
        FakeCameraBehavior(
            IntegrationID("test.luna-like"), reportDelay = 2500.milliseconds, observationTimeout = 6.seconds,
            recordWire = RecordWire.EXPLICIT, modes = mapOf(0x01 to video), timecodeOrigin = CLOCK_DERIVED,
        ),
        FakeDevice(
            rawMode = 0x01,
            settings = settings(
                isoValue(200), durationValue(60), SettingValue.Aperture(2.0), zeroEV, kelvinValue(4000), fpsValue(30),
                SettingValue.Zoom(1.0), SettingValue.FocusMode(FocusMode.CONTINUOUS),
            ),
            batteryPercent = 55,
            timecodeReading = CameraTimecodeReading(9, 30, 0),
        ),
    )
}

/**
 * A picture with no camera behind it: a capture device, a relay picture or a replay. It only
 * ever changes picture state.
 */
public class FakePictureSource(label: String) {
    public val descriptor: PictureSourceDescriptor = PictureSourceDescriptor(label = label)
    public var health: PictureHealth = PictureHealth.STARTING
        private set

    public fun start() {
        health = PictureHealth.LIVE
    }

    public fun fail() {
        health = PictureHealth.FAILED
    }
}

public object FakeEntries {
    /** Picture only: no camera control and no telemetry. */
    public fun captureOnly(picture: PictureSourceDescriptor): MonitorEntryDescriptor = MonitorEntryDescriptor(
        name = picture.label, picture = picture,
        controlAuthority = ControlAuthority.Unavailable(UnavailableReason.Route),
    )

    /** Camera control and telemetry with no picture. */
    public fun controlOnly(session: CameraSessionID, name: String): MonitorEntryDescriptor = MonitorEntryDescriptor(
        name = name, cameraSession = session, telemetry = TelemetrySource.CAMERA_SESSION,
        controlAuthority = ControlAuthority.Owner,
    )
}
