package com.opencapture.opencine.nikonwire

import com.opencapture.opencine.core.BatteryReading
import com.opencapture.opencine.core.BatteryReadingFields
import org.json.JSONObject

/** Platform JSON framing over the common validated fields; no camera or runtime owner. */
internal object BatteryRelayJSON {
    fun encode(reading: BatteryReading?): Any {
        val fields = reading?.wireFields ?: return JSONObject.NULL
        return JSONObject().put("kind", fields.kind).apply {
            fields.value?.let { put("value", it) }
            fields.filled?.let { put("filled", it) }
            fields.of?.let { put("of", it) }
        }
    }

    fun decode(value: Any?): BatteryReading? {
        if (value == null || value == JSONObject.NULL) return null
        require(value is JSONObject) { "Battery reading is not an object" }
        val kind = value.get("kind")
        require(kind is String) { "Battery reading kind is not a string" }
        val fields = when (kind) {
            "fraction" -> {
                val fraction = value.get("value")
                require(fraction is Number) { "Battery fraction is not a number" }
                BatteryReadingFields(kind = kind, value = fraction.toDouble())
            }
            "steps" -> BatteryReadingFields(kind = kind, filled = integer(value, "filled"), of = integer(value, "of"))
            else -> BatteryReadingFields(kind = kind)
        }
        return BatteryReading.fromWireFields(fields)
    }

    private fun integer(value: JSONObject, key: String): Int {
        val number = value.get(key)
        require(number is Number) { "Battery $key is not a number" }
        val double = number.toDouble()
        require(double.isFinite() && double in Int.MIN_VALUE.toDouble()..Int.MAX_VALUE.toDouble() &&
            double == number.toInt().toDouble()) { "Battery $key is not an integer" }
        return number.toInt()
    }
}
