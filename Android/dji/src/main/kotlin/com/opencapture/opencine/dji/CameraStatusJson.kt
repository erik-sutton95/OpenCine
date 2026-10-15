package com.opencapture.opencine.dji

import com.opencapture.opencine.core.CameraTimecodeReading
import com.opencapture.opencine.vocabulary.CameraCommands
import com.opencapture.opencine.vocabulary.CameraModel
import com.opencapture.opencine.vocabulary.CameraStatus
import com.opencapture.opencine.vocabulary.VideoFormat
import org.json.JSONArray
import org.json.JSONObject

// The DjiNative facade JSON for camera models and status (JNI wire; the facade always sends it).

fun CameraModel.Companion.fromJson(raw: String?): CameraModel {
    if (raw.isNullOrBlank()) return CameraModel.default
    return runCatching {
        val obj = JSONObject(raw)
        val name = obj.optString("name", CameraModel.default.name)
        CameraModel(
            name = name,
            datalinkPort = obj.optInt("datalinkPort", 9004),
            tcpPoke = obj.optBoolean("tcpPoke", true),
            wpa3 = obj.optBoolean("wpa3", false),
            verified = obj.optBoolean("verified", false),
            isDrone = obj.optBoolean("isDrone", false),
            pairingToken = obj.optString("pairingToken", "osmo"),
            family = obj.optString("family", "pocket").ifBlank { "pocket" },
            liveViewEnableReceiver = obj.optInt("liveViewEnableReceiver", 0x08),
            usesNanoLiveViewGate = obj.optBoolean("usesNanoLiveViewGate", false),
            supportsTapFocus = obj.optBoolean("supportsTapFocus", true),
            supportsFocusMode = obj.optBoolean("supportsFocusMode", true),
            usesCapturedLiveEnable = obj.optBoolean("usesCapturedLiveEnable", true),
            needsFirstPictureFormatPoke =
                obj.optBoolean("needsFirstPictureFormatPoke", CameraModel.looksLikePocket3(name)),
            zoomStops = zoomStopsFromJson(obj, name, obj.optString("family", "pocket")),
            // The facade always sends these; a missing key fails closed.
            hasGimbal = obj.optBoolean("hasGimbal", false),
            supportsZoom = obj.optBoolean("supportsZoom", false),
            sendsLiveViewPrepare = obj.optBoolean(
                "sendsLiveViewPrepare",
                !obj.optBoolean("usesNanoLiveViewGate", false) && !CameraModel.looksLikeAction6(name),
            ),
            supportsAperture = obj.optBoolean("supportsAperture", CameraModel.looksLikeAction6(name)),
        ).let { model -> model.copy(captureProfile = DjiCaptureCapabilityProfile.make(model)) }
    }.getOrElse { CameraModel.default }
}

private fun zoomStopsFromJson(obj: JSONObject, name: String, family: String): List<Double> {
    val arr = obj.optJSONArray("zoomStops") ?: return CameraModel.zoomStopsFor(name, family)
    if (arr.length() == 0) return CameraModel.zoomStopsFor(name, family)
    return (0 until arr.length()).map { arr.optDouble(it) }.filter { it >= 1.0 }
}

fun CameraStatus.toJson(): String =
    JSONObject()
        .put("batteryPercent", batteryPercent)
        .put("batteryMilliVolts", batteryMilliVolts)
        .put("batteryMilliAmps", batteryMilliAmps)
        .put("docked", docked)
        .put("charging", charging)
        .put("chargingObservation", chargingObservation ?: JSONObject.NULL)
        .put("chargingObservationDeclared", chargingObservationDeclared)
        .put("storageTotalMb", storageTotalMb)
        .put("storageFreeMb", storageFreeMb)
        .put("sdTotalMb", sdTotalMb)
        .put("sdFreeMb", sdFreeMb)
        .put("internalTotalMb", internalTotalMb)
        .put("internalFreeMb", internalFreeMb)
        .put("inPlayback", inPlayback)
        .put("firmware", firmware ?: JSONObject.NULL)
        .put("isRecording", isRecording)
        .put("shootingMode", shootingMode)
        .put("recordElapsedSec", recordElapsedSec)
        .put("recordRemainingSec", recordRemainingSec)
        .put("timecode", timecodeReading?.let { JSONArray(listOfNotNull(it.hours, it.minutes, it.seconds, it.frames)) } ?: JSONObject.NULL)
        .put("iso", iso)
        .put("shutterDenom", shutterDenom)
        .put("fps", fps)
        .put("expoMode", expoMode)
        .put("isoIndex", isoIndex)
        .put("colorMode", colorMode)
        .put("videoResolution", resolutionCode)
        .put("fpsIndex", fpsIndex)
        .put("whiteBalanceMode", wbMode)
        .put("whiteBalanceKelvin", wbKelvin)
        .put("whiteBalanceTint", wbTint)
        .put("autoWhiteBalanceKelvin", autoWbKelvin)
        .put("focusMode", focusMode)
        .put("audioChannel", audioChannel)
        .put("vocalBoost", vocalBoost)
        .put("audioDspAt2", audioDspAt2)
        .put("audioDspBlob", audioDspBlob.ifEmpty { JSONObject.NULL })
        .put("zoomFactorRaw", zoomFactorRaw)
        .put("availableShutterDenoms", JSONArray(availableShutterDenoms))
        .put("availableIsoIndices", JSONArray(availableIsoIndices))
        .put("evComp", evComp)
        .put("meteredEv", meteredEv)
        .put("isoLimit", isoLimit)
        .put("availableColorModes", JSONArray(availableColorModes))
        .put("availableVideoFormats", videoFormatsJson())
        .put("focusX", focusX)
        .put("focusY", focusY)
        .put("hasCameraFocusPoint", hasCameraFocusPoint)
        .put("focusTrack", focusTrack)
        .put("zoomLens", zoomLens)
        .put("zoomFactor", zoomFactor ?: JSONObject.NULL)
        .put("glamourEnabled", glamourEnabled ?: JSONObject.NULL)
        .put("selfieFlip", selfieFlip ?: JSONObject.NULL)
        .put("gimbalFace", gimbalFace)
        .put("gimbalModeFamily", gimbalModeFamily)
        .put("windNR", windNRJson())
        .put("directionalAudio", directionalAudioJson())
        .put("audioMetersLeft", audioMetersLeft)
        .put("audioMetersRight", audioMetersRight)
        .put("audioPeakLeft", audioPeakLeft)
        .put("audioPeakRight", audioPeakRight)
        .put("audioMetersReported", audioMetersReported)
        .toString()

/** Interleaved `[res, fps, …]` matching JNI `statusJSON`. */
private fun CameraStatus.videoFormatsJson(): JSONArray {
    val arr = JSONArray()
    for (format in availableVideoFormats) {
        arr.put(format.resolution.rawValue)
        arr.put(format.frameRate.rawValue)
    }
    return arr
}

/** Core `WindNoiseReduction` raw (`1A`/`18`); Kotlin HUD keeps `windNr` as 0/1. */
private fun CameraStatus.windNRJson(): Int =
    when (windNr) {
        0 -> CameraCommands.WIND_OFF
        1 -> CameraCommands.WIND_ON
        else -> windNr
    }

/** Core `DirectionalAudio` raw (`DA`/`3A`/`BA`); HUD keeps 0/1/2. */
private fun CameraStatus.directionalAudioJson(): Int =
    when (directionalAudio) {
        0 -> CameraCommands.DIR_ALL
        1 -> CameraCommands.DIR_FRONT
        2 -> CameraCommands.DIR_FRONT_BACK
        else -> directionalAudio
    }

fun CameraStatus.Companion.fromJson(raw: String?): CameraStatus {
    if (raw.isNullOrBlank()) return CameraStatus()
    return runCatching {
        val obj = JSONObject(raw)
        val decodedTimecode = intList(obj.optJSONArray("timecode")).takeIf { it.size >= 3 }
            ?.let { CameraTimecodeReading(it[0], it[1], it[2], it.getOrNull(3)) }
        CameraStatus(
            batteryPercent = obj.optInt("batteryPercent", -1),
            batteryMilliVolts = obj.optInt("batteryMilliVolts", 0),
            batteryMilliAmps = obj.optInt("batteryMilliAmps", 0),
            docked = obj.optBoolean("docked", false),
            charging = obj.optBoolean("charging", false),
            chargingObservation = optionalBoolean(obj, "chargingObservation"),
            chargingObservationDeclared = optionalBoolean(obj, "chargingObservationDeclared")
                ?: obj.has("chargingObservation"),
            storageTotalMb = obj.optInt("storageTotalMb", 0),
            storageFreeMb = obj.optInt("storageFreeMb", 0),
            sdTotalMb = obj.optInt("sdTotalMb", 0),
            sdFreeMb = obj.optInt("sdFreeMb", 0),
            internalTotalMb = obj.optInt("internalTotalMb", -1),
            internalFreeMb = obj.optInt("internalFreeMb", -1),
            inPlayback = obj.optBoolean("inPlayback", false),
            firmware = obj.optString("firmware").takeIf { it.isNotEmpty() && obj.has("firmware") && !obj.isNull("firmware") },
            isRecording = obj.optBoolean("isRecording", false),
            shootingMode = obj.optInt("shootingMode", -1),
            recordElapsedSec = obj.optInt("recordElapsedSec", 0),
            recordRemainingSec = obj.optInt("recordRemainingSec", 0),
            iso = obj.optInt("iso", -1),
            shutterDenom = obj.optInt("shutterDenom", -1),
            fps = obj.optInt("fps", 0),
            expoMode = obj.optInt("expoMode", -1),
            isoIndex = obj.optInt("isoIndex", -1),
            colorMode = obj.optInt("colorMode", -1),
            resolutionCode = obj.optInt("videoResolution", obj.optInt("resolutionCode", -1)),
            fpsIndex = obj.optInt("fpsIndex", -1),
            wbMode = obj.optInt("whiteBalanceMode", obj.optInt("wbMode", -1)),
            wbKelvin = obj.optInt("whiteBalanceKelvin", obj.optInt("wbKelvin", -1)),
            wbTint = obj.optInt("whiteBalanceTint", obj.optInt("wbTint", 0)),
            autoWbKelvin = obj.optInt("autoWhiteBalanceKelvin", -1),
            focusMode = obj.optInt("focusMode", -1),
            audioChannel = obj.optInt("audioChannel", -1),
            vocalBoost = obj.optInt("vocalBoost", -1),
            audioDspBlob =
                obj.optString("audioDspBlob").takeIf {
                    it.isNotEmpty() && obj.has("audioDspBlob") && !obj.isNull("audioDspBlob")
                } ?: "",
            audioDspAt2 = obj.optInt("audioDspAt2", -1),
            zoomFactorRaw = obj.optInt("zoomFactorRaw", 0),
            availableShutterDenoms = intList(obj.optJSONArray("availableShutterDenoms")),
            availableIsoIndices = intList(obj.optJSONArray("availableIsoIndices")),
            evComp = obj.optInt("evComp", -1),
            meteredEv = obj.optInt("meteredEv", -1).takeIf { it in 0x07..0x19 } ?: -1,
            isoLimit = obj.optInt("isoLimit", -1),
            availableColorModes = intList(obj.optJSONArray("availableColorModes")),
            availableVideoFormats = videoFormatList(obj.optJSONArray("availableVideoFormats")),
            focusX = obj.optDouble("focusX", 0.5),
            focusY = obj.optDouble("focusY", 0.5),
            hasCameraFocusPoint = obj.optBoolean("hasCameraFocusPoint", false),
            focusTrack = obj.optInt("focusTrack", -1),
            zoomLens = obj.optInt("zoomLens", -1),
            zoomFactor = optionalDouble(obj, "zoomFactor"),
            glamourEnabled = optionalBoolean(obj, "glamourEnabled"),
            selfieFlip = optionalBoolean(obj, "selfieFlip"),
            gimbalFace = obj.optInt("gimbalFace", CameraCommands.GIMBAL_FACE_UNKNOWN),
            gimbalModeFamily = obj.optInt("gimbalModeFamily", -1),
            windNr = mapWindNr(obj),
            directionalAudio = mapDirectionalAudio(obj),
            audioMetersLeft = obj.optDouble("audioMetersLeft", -60.0),
            audioMetersRight = obj.optDouble("audioMetersRight", -60.0),
            audioPeakLeft = obj.optDouble("audioPeakLeft", -60.0),
            audioPeakRight = obj.optDouble("audioPeakRight", -60.0),
            audioMetersReported = obj.optBoolean("audioMetersReported", false),
        ).withTimecodeReading(decodedTimecode).withAudioDspAt2()
    }.getOrElse { CameraStatus() }
}

private fun intList(arr: JSONArray?): List<Int> {
    if (arr == null) return emptyList()
    return buildList(arr.length()) {
        for (i in 0 until arr.length()) add(arr.optInt(i))
    }
}

/** Interleaved `[res, fps, res, fps, …]` from the JNI status JSON. */
private fun videoFormatList(arr: JSONArray?): List<VideoFormat> {
    if (arr == null) return emptyList()
    val flat = intList(arr)
    if (flat.size < 2) return emptyList()
    return buildList(flat.size / 2) {
        var i = 0
        while (i + 1 < flat.size) {
            VideoFormat.parseDji(flat[i], flat[i + 1])?.let { add(it) }
            i += 2
        }
    }
}

private fun optionalDouble(obj: JSONObject, key: String): Double? {
    if (!obj.has(key) || obj.isNull(key)) return null
    val value = obj.optDouble(key)
    return if (value.isNaN()) null else value
}

private fun optionalBoolean(obj: JSONObject, key: String): Boolean? {
    if (!obj.has(key) || obj.isNull(key)) return null
    return obj.optBoolean(key)
}

private fun mapWindNr(obj: JSONObject): Int {
    val raw =
        when {
            obj.has("windNR") && !obj.isNull("windNR") -> obj.optInt("windNR", -1)
            obj.has("windNr") && !obj.isNull("windNr") -> obj.optInt("windNr", -1)
            else -> -1
        }
    return when (raw) {
        CameraCommands.WIND_ON, 1 -> 1
        CameraCommands.WIND_OFF, 0 -> 0
        else -> if (raw < 0) -1 else raw
    }
}

private fun mapDirectionalAudio(obj: JSONObject): Int {
    val raw = obj.optInt("directionalAudio", -1)
    return when (raw) {
        CameraCommands.DIR_ALL, 0 -> 0
        CameraCommands.DIR_FRONT, 1 -> 1
        CameraCommands.DIR_FRONT_BACK, 2 -> 2
        else -> if (raw < 0) -1 else raw
    }
}
