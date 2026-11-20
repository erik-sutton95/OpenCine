package com.opencapture.opencine.streaming

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.BatteryManager
import android.os.PowerManager
import java.util.concurrent.Executor

/** What the operator is warned about while live. Streaming never stops for these on its own. */
enum class StreamDeviceWarning {
    /** Thermal status severe: the device may slow down. */
    HOT,

    /** Thermal status critical or worse: the OS may soon force apps to stop. */
    CRITICAL_HEAT,

    /** At or below 15 % and not charging. */
    LOW_BATTERY,
}

/** The warnings for these readings. Unknown battery or charging state warns about nothing. */
fun streamDeviceWarnings(thermalStatus: Int, batteryPercent: Int?, charging: Boolean?): Set<StreamDeviceWarning> {
    val warnings = mutableSetOf<StreamDeviceWarning>()
    when {
        thermalStatus >= PowerManager.THERMAL_STATUS_CRITICAL -> warnings += StreamDeviceWarning.CRITICAL_HEAT
        thermalStatus >= PowerManager.THERMAL_STATUS_SEVERE -> warnings += StreamDeviceWarning.HOT
    }
    if (batteryPercent != null && charging == false && batteryPercent <= LOW_BATTERY_PERCENT) {
        warnings += StreamDeviceWarning.LOW_BATTERY
    }
    return warnings
}

private const val LOW_BATTERY_PERCENT = 15

/** Watches thermal status and battery while a stream runs; [onChange] gets each new set. */
class StreamDeviceMonitor(context: Context, private val executor: Executor) {
    private val app = context.applicationContext
    private val power = app.getSystemService(PowerManager::class.java)
    private var thermal = power?.currentThermalStatus ?: PowerManager.THERMAL_STATUS_NONE
    private var batteryPercent: Int? = null
    private var charging: Boolean? = null
    private var last: Set<StreamDeviceWarning> = emptySet()
    private var onChange: ((Set<StreamDeviceWarning>) -> Unit)? = null
    private val thermalListener = PowerManager.OnThermalStatusChangedListener { status ->
        thermal = status
        publish()
    }
    private val batteryReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            executor.execute {
                read(intent)
                publish()
            }
        }
    }

    fun start(onChange: (Set<StreamDeviceWarning>) -> Unit) {
        this.onChange = onChange
        power?.addThermalStatusListener(executor, thermalListener)
        app.registerReceiver(batteryReceiver, IntentFilter(Intent.ACTION_BATTERY_CHANGED))?.let { read(it) }
        executor.execute { publish(force = true) }
    }

    fun stop() {
        onChange = null
        runCatching { power?.removeThermalStatusListener(thermalListener) }
        runCatching { app.unregisterReceiver(batteryReceiver) }
    }

    private fun read(intent: Intent) {
        val level = intent.getIntExtra(BatteryManager.EXTRA_LEVEL, -1)
        val scale = intent.getIntExtra(BatteryManager.EXTRA_SCALE, -1)
        batteryPercent = if (level >= 0 && scale > 0) level * 100 / scale else null
        charging = when (intent.getIntExtra(BatteryManager.EXTRA_PLUGGED, -1)) {
            -1 -> null
            0 -> false
            else -> true
        }
    }

    private fun publish(force: Boolean = false) {
        val next = streamDeviceWarnings(thermal, batteryPercent, charging)
        if (!force && next == last) return
        last = next
        onChange?.invoke(next)
    }
}
