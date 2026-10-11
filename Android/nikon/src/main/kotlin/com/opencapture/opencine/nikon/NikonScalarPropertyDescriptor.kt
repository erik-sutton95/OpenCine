package com.opencapture.opencine.nikon

/** Exact reported scalar facts. Parsing alone grants no owner or write authority. */
data class NikonScalarPropertyDescriptor private constructor(
    val property: Long,
    val valueByteCount: Int,
    val writable: Boolean,
    val defaultValue: List<Byte>,
    val currentValue: List<Byte>,
    val form: Form,
) {
    /** Exact camera-order form, preserving unknown raw values. */
    sealed interface Form {
        data object None : Form
        data class Range(val minimum: List<Byte>, val maximum: List<Byte>, val step: List<Byte>) : Form
        data class Enumeration(val values: List<List<Byte>>) : Form
    }

    companion object {
        /** Strict standard/extended identity, scalar type, GetSet, form and length parser. */
        fun parse(data: ByteArray, property: Long, valueByteCount: Int): NikonScalarPropertyDescriptor? {
            val type = when (valueByteCount) {
                1 -> 0x0002
                2 -> 0x0004
                4 -> 0x0006
                8 -> 0x0008
                else -> return null
            }
            if (property !in 0L..0xFFFF_FFFFL || data.size < 7) return null
            fun scalar(at: Int, width: Int): Long = (0 until width).fold(0L) { value, offset ->
                value or ((data[at + offset].toLong() and 0xFF) shl (offset * 8))
            }
            val header = when {
                scalar(0, 4) == property && scalar(4, 2) == type.toLong() &&
                    data[6].toInt() in 0..1 && data.size > 7 + valueByteCount * 2 -> 7
                property <= 0xFFFF && scalar(0, 2) == property && scalar(2, 2) == type.toLong() &&
                    data[4].toInt() in 0..1 && data.size > 5 + valueByteCount * 2 -> 5
                else -> return null
            }
            val index = header + valueByteCount * 2
            val start = index + 1
            val form = when (data[index].toInt()) {
                0 -> {
                    if (start != data.size) return null
                    Form.None
                }
                1 -> {
                    if (start + valueByteCount * 3 != data.size) return null
                    Form.Range(
                        data.slice(start until start + valueByteCount),
                        data.slice(start + valueByteCount until start + valueByteCount * 2),
                        data.slice(start + valueByteCount * 2 until data.size),
                    )
                }
                2 -> {
                    if (start + 2 > data.size) return null
                    val count = scalar(start, 2).toInt()
                    val valuesStart = start + 2
                    if (valuesStart + count * valueByteCount != data.size) return null
                    Form.Enumeration((0 until count).map { item ->
                        val valueStart = valuesStart + item * valueByteCount
                        data.slice(valueStart until valueStart + valueByteCount)
                    })
                }
                else -> return null
            }
            return NikonScalarPropertyDescriptor(
                property, valueByteCount, data[header - 1].toInt() == 1,
                data.slice(header until header + valueByteCount),
                data.slice(header + valueByteCount until index), form,
            )
        }
    }
}
