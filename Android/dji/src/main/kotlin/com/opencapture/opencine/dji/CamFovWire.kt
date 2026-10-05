package com.opencapture.opencine.dji

import com.opencapture.opencine.vocabulary.CamFov

fun CamFov.rawAt0(value: ByteArray): Int? {
    if (value.size < 4) return null
    return (value[0].toInt() and 0xFF) or
        ((value[1].toInt() and 0xFF) shl 8) or
        ((value[2].toInt() and 0xFF) shl 16) or
        ((value[3].toInt() and 0xFF) shl 24)
}

fun CamFov.lensAt14(value: ByteArray): Int? {
    if (value.size < 16) return null
    val lens = (value[14].toInt() and 0xFF) or ((value[15].toInt() and 0xFF) shl 8)
    return lens.takeIf { it in 100..3_000 }
}

fun CamFov.factorFromValue(value: ByteArray): Double? = rawAt0(value)?.let { factor(it) }
