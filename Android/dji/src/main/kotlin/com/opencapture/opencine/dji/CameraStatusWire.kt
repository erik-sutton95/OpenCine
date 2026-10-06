package com.opencapture.opencine.dji

import com.opencapture.opencine.vocabulary.CameraCommands
import com.opencapture.opencine.vocabulary.CameraStatus

fun CameraStatus.applyingAudioByte2(raw: Int): CameraStatus {
    val wind = CameraCommands.windFrom(raw)
    val dir = CameraCommands.directionalFrom(raw)
    return copy(
        audioDspAt2 = raw,
        windNr = if (wind >= 0) wind else windNr,
        directionalAudio = if (dir >= 0) dir else directionalAudio,
    )
}

fun CameraStatus.applyingAudioBlob(blob: ByteArray): CameraStatus {
    if (blob.size < 3) return this
    return copy(audioDspBlob = CameraCommands.audioDspHex(blob))
        .applyingAudioByte2(blob[2].toInt() and 0xFF)
}

fun CameraStatus.withAudioDspAt2(): CameraStatus {
    val at2 =
        when {
            audioDspAt2 >= 0 -> audioDspAt2
            audioDspBlob.length >= 6 -> audioDspBlob.substring(4, 6).toIntOrNull(16) ?: -1
            else -> -1
        }
    return if (at2 >= 0) applyingAudioByte2(at2) else copy(audioDspAt2 = at2)
}
