package com.opencapture.opencine.dji

import com.opencapture.opencine.media.QuickTimeKeys
import com.opencapture.opencine.vocabulary.ClipColorProfile

/** [ClipColorProfile] from an MP4 tail window (the `moov` bytes a camera Range read returns). */
fun ClipColorProfile.gammaFromMp4(bytes: ByteArray): String? = QuickTimeKeys.keys(bytes, GAMMA_KEY)[GAMMA_KEY]

fun ClipColorProfile.colorModeFromMp4(bytes: ByteArray): Int = gammaFromMp4(bytes)?.let(::colorModeFromGamma) ?: -1
