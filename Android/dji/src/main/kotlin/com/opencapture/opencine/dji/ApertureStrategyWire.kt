package com.opencapture.opencine.dji

import com.opencapture.opencine.vocabulary.ApertureStrategy

val ApertureStrategy.STATE_KEY: String get() = "cam_aperture_ctrl_strategy"

val ApertureStrategy.CAPABILITY_KEY: String get() = "camcap_aperture_ctrl_strategy"

/** `cam_aperture_ctrl_strategy` `01 00 00 <strategy>`. */
fun ApertureStrategy.parseState(value: ByteArray): Int? {
    if (value.size < 4 || value[0] != 0x01.toByte()) return null
    return (value[3].toInt() and 0xFF).takeIf { label(it) != null }
}

/** `camcap_aperture_ctrl_strategy` `01 <len:u16-LE> <count> <ids…>`. Bytes past `count` are not choices. */
fun ApertureStrategy.parseCapability(value: ByteArray): List<Int> {
    if (value.size < 5 || value[0] != 0x01.toByte()) return emptyList()
    val inner = (value[1].toInt() and 0xFF) or ((value[2].toInt() and 0xFF) shl 8)
    if (inner < 2 || 3 + inner > value.size) return emptyList()
    val count = value[3].toInt() and 0xFF
    if (count < 1 || 1 + count > inner) return emptyList()
    return value.copyOfRange(4, 4 + count).map { it.toInt() and 0xFF }.filter { label(it) != null }
}

/** Mechanical iris, `cam_expo_param` u16-LE `@13` in hundredths (`290` = f/2.9). */
fun ApertureStrategy.irisHundredths(expoParam: ByteArray): Int? {
    if (expoParam.size < 15) return null
    val raw = (expoParam[13].toInt() and 0xFF) or ((expoParam[14].toInt() and 0xFF) shl 8)
    return raw.takeIf { it in 100..2_200 }
}
