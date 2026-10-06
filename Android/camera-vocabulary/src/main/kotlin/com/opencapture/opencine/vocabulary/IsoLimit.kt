package com.opencapture.opencine.vocabulary

/** Auto ISO ceiling (Swift `IsoLimit`); [rawValue] is the stored value. */
enum class IsoLimit(val rawValue: Int) {
    Max200(0x02),
    Max400(0x03),
    Max800(0x04),
    Max1600(0x05),
    Max3200(0x06),
    Max6400(0x07),
    Max12800(0x08),
    Max25600(0x09),
    ;

    val ceiling: Int get() = 100 shl (rawValue - 1)

    fun label(base: Int): String = "$base–$ceiling"
}
